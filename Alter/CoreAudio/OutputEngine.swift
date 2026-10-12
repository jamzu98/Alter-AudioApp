import CoreAudio
import Foundation
import Observation

/// Keeps one TapSession per app, routes them all to the current default output and runs each
/// through the active device's effect chain.
///
/// Creating taps and aggregate devices can block for hundreds of milliseconds, so all Core Audio
/// work happens on a private serial queue. The main thread only enqueues work and reads results.
@MainActor
@Observable
final class OutputEngine {
    nonisolated static let aggregateUIDPrefix = "com.alter.aggregate"

    @ObservationIgnored let chain = ChainHandle(.passthrough())
    private(set) var lastError: String?
    /// Keys of apps whose audio currently goes through Alter.
    private(set) var activeKeys: Set<String> = []

    @ObservationIgnored private let worker: EngineWorker

    init() {
        worker = EngineWorker(chain: chain)
        worker.onStateChange = { [weak self] keys, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if keys != self.activeKeys { self.activeKeys = keys }
                if let error { self.lastError = error }
            }
        }
    }

    func setOutputDevice(_ device: OutputDevice?) {
        worker.queue.async { [worker] in worker.setDevice(device) }
    }

    /// Rebuilds every route on the current device, e.g. after its sample rate changed.
    func rebuildRoutes() {
        worker.queue.async { [worker] in worker.rebuildRoutes() }
    }

    /// Brings sessions in line with `apps`, the apps Alter should process.
    func reconcile(apps: [AudioApp]) {
        worker.queue.async { [worker] in worker.reconcile(apps) }
    }

    /// Applied immediately, without waiting for the worker queue.
    func setGain(_ gain: Float, for key: String) {
        worker.registry.setGain(gain, for: key)
    }

    func takePeak(for key: String) -> Float {
        worker.registry.takePeak(for: key)
    }

    /// Blocks until every tap is destroyed. Used when quitting.
    func tearDownAll() {
        worker.queue.sync { [worker] in worker.tearDownAll() }
    }

    func publish(_ state: ChainState) {
        chain.publish(state)
    }
}

/// Gains and renderers shared between the main thread and the worker queue.
final class RendererRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var gains: [String: Float] = [:]
    private var renderers: [String: TapRenderer] = [:]

    func setGain(_ gain: Float, for key: String) {
        lock.lock(); defer { lock.unlock() }
        gains[key] = gain
        renderers[key]?.gain = gain
    }

    func gain(for key: String) -> Float {
        lock.lock(); defer { lock.unlock() }
        return gains[key] ?? 1
    }

    func takePeak(for key: String) -> Float {
        lock.lock(); defer { lock.unlock() }
        return renderers[key]?.takePeak() ?? 0
    }

    func register(_ renderer: TapRenderer?, for key: String) {
        lock.lock(); defer { lock.unlock() }
        renderers[key] = renderer
        renderer?.gain = gains[key] ?? 1
    }
}

/// Owns the tap sessions. Every method runs on `queue`.
final class EngineWorker: @unchecked Sendable {
    /// How long a session keeps its IO running after its app goes quiet.
    static let idleStopDelay: TimeInterval = 4

    let queue = DispatchQueue(label: "com.alter.engine", qos: .userInitiated)
    let registry = RendererRegistry()
    var onStateChange: ((Set<String>, String?) -> Void)?

    private let chain: ChainHandle
    private var sessions: [String: TapSession] = [:]
    private var device: OutputDevice?
    private var stopWork: [String: DispatchWorkItem] = [:]

    init(chain: ChainHandle) { self.chain = chain }

    func setDevice(_ newDevice: OutputDevice?) {
        guard newDevice?.uid != device?.uid || newDevice?.id != device?.id else { return }
        device = newDevice
        var failure: String?
        for session in sessions.values {
            if let newDevice {
                do { try session.attach(to: newDevice) } catch { failure = report(error) }
            } else {
                session.detach()
            }
        }
        publishState(failure)
    }

    func rebuildRoutes() {
        guard let device else { return }
        var failure: String?
        for session in sessions.values where session.deviceUID != nil {
            do { try session.attach(to: device, force: true) } catch { failure = report(error) }
        }
        publishState(failure)
    }

    func reconcile(_ apps: [AudioApp]) {
        let wantedKeys = Set(apps.map(\.id))
        var failure: String?

        for (key, session) in sessions where !wantedKeys.contains(key) {
            NSLog("Alter: releasing \(key)")
            session.invalidate()
            sessions[key] = nil
            registry.register(nil, for: key)
            stopWork[key]?.cancel()
            stopWork[key] = nil
        }

        for app in apps {
            if let session = sessions[app.id] {
                session.updateProcesses(app.processObjects)
                if app.isPlaying { failure = run(session) ?? failure } else { scheduleStop(app.id) }
            } else {
                // Sessions are prepared as soon as an app has audio, so that starting playback
                // only has to start IO instead of building a tap and an aggregate device.
                do {
                    let session = try TapSession(key: app.id, name: app.name, processObjects: app.processObjects, chain: chain)
                    sessions[app.id] = session
                    registry.register(session.renderer, for: app.id)
                    NSLog("Alter: intercepting \(app.name) (\(app.id), \(app.processObjects.count) process(es))")
                    if let device { try session.attach(to: device) }
                    if app.isPlaying { failure = run(session) ?? failure }
                } catch {
                    failure = report(error)
                }
            }
        }
        publishState(failure)
    }

    private func run(_ session: TapSession) -> String? {
        stopWork[session.key]?.cancel()
        stopWork[session.key] = nil
        guard let device else { return nil }
        do {
            try session.attach(to: device)
            session.start()
            return nil
        } catch {
            return report(error)
        }
    }

    private func scheduleStop(_ key: String) {
        guard stopWork[key] == nil, let session = sessions[key], session.isRunning else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.sessions[key]?.stop()
            self?.stopWork[key] = nil
        }
        stopWork[key] = work
        queue.asyncAfter(deadline: .now() + Self.idleStopDelay, execute: work)
    }

    func tearDownAll() {
        stopWork.values.forEach { $0.cancel() }
        stopWork = [:]
        for (key, session) in sessions {
            session.invalidate()
            registry.register(nil, for: key)
        }
        sessions = [:]
        publishState(nil)
    }

    private func publishState(_ error: String?) {
        onStateChange?(Set(sessions.keys), error)
    }

    private func report(_ error: Error) -> String {
        NSLog("Alter: \(error)")
        return String(describing: error)
    }
}
