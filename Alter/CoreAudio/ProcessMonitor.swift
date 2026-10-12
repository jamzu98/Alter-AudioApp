import AppKit
import CoreAudio
import Darwin
import Observation

/// One user-facing app that produces audio. Helper processes (e.g. WebKit or Chrome renderers)
/// are grouped under the app responsible for them.
struct AudioApp: Identifiable, Equatable {
    /// Stable key: the bundle ID of the responsible app, or "pid:<n>" when there is none.
    let id: String
    let name: String
    let bundleID: String?
    let pid: pid_t
    /// A regular app with a Dock icon, as opposed to an agent or a command-line tool.
    let isRegularApp: Bool
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
    /// Output devices the app's processes are currently playing to.
    var outputDeviceIDs: [AudioObjectID]

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
            ?? bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

@MainActor
@Observable
final class ProcessMonitor {
    private(set) var apps: [AudioApp] = []
    @ObservationIgnored var onChange: (([AudioApp]) -> Void)?

    @ObservationIgnored private var listListener: PropertyListener?
    @ObservationIgnored private var processListeners: [AudioObjectID: [PropertyListener]] = [:]
    @ObservationIgnored private var reloadScheduled = false
    @ObservationIgnored private let ownPID = ProcessInfo.processInfo.processIdentifier

    init() {
        listListener = PropertyListener(object: .system, address: .init(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            self?.scheduleReload()
        }
        reload()
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    func reload() {
        let objects = (try? AudioObjectID.system.readArray(.init(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)) ?? []

        // Keep listeners in sync with the process list.
        let current = Set(objects)
        for gone in Set(processListeners.keys).subtracting(current) { processListeners[gone] = nil }
        for new in current.subtracting(processListeners.keys) {
            processListeners[new] = [
                PropertyListener(object: new, address: .init(kAudioProcessPropertyIsRunningOutput)) { [weak self] in self?.scheduleReload() },
                PropertyListener(object: new, address: .init(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)) { [weak self] in self?.scheduleReload() },
            ].compactMap { $0 }
        }

        var groups: [String: AudioApp] = [:]
        var order: [String] = []
        for object in objects {
            guard let pid = try? object.read(.init(kAudioProcessPropertyPID), default: pid_t(0)), pid > 0, pid != ownPID else { continue }
            let responsible = ResponsibleProcess.pid(for: pid)
            if responsible == ownPID { continue }
            let running = ((try? object.read(.init(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))) ?? 0) != 0
            let devices = (try? object.readArray(.init(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput), of: AudioObjectID.self)) ?? []

            let app = NSRunningApplication(processIdentifier: responsible)
            let processBundleID = try? object.readString(.init(kAudioProcessPropertyBundleID))
            let bundleID = app?.bundleIdentifier ?? (processBundleID?.isEmpty == false ? processBundleID : nil)
            let key = bundleID ?? "pid:\(responsible)"
            let name = app?.localizedName ?? ResponsibleProcess.name(for: responsible) ?? bundleID ?? "PID \(responsible)"

            if var existing = groups[key] {
                existing.processObjects.append(object)
                existing.isPlaying = existing.isPlaying || running
                existing.outputDeviceIDs = Array(Set(existing.outputDeviceIDs + devices)).sorted()
                groups[key] = existing
            } else {
                groups[key] = AudioApp(id: key, name: name, bundleID: bundleID, pid: responsible,
                                       isRegularApp: app?.activationPolicy == .regular,
                                       processObjects: [object], isPlaying: running, outputDeviceIDs: devices.sorted())
                order.append(key)
            }
        }
        let result = order.compactMap { groups[$0] }
        if result != apps {
            apps = result
            onChange?(result)
        }
    }
}

/// Finds the app responsible for a helper process (e.g. Safari for a WebContent process).
enum ResponsibleProcess {
    private typealias Fn = @convention(c) (pid_t) -> pid_t
    private static let fn: Fn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func pid(for pid: pid_t) -> pid_t {
        guard let fn else { return pid }
        let r = fn(pid)
        return r > 0 ? r : pid
    }

    static func name(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : nil
    }
}
