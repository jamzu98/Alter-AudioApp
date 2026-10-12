import AppKit
import Observation
import ServiceManagement

/// Root state: ties devices, apps, presets and profiles to the audio engine.
@MainActor
@Observable
final class AppModel {
    let devices = DeviceManager()
    let processes = ProcessMonitor()
    let engine = OutputEngine()
    let permission = AudioCapturePermission()

    private(set) var profiles: [String: DeviceProfile]
    private(set) var presets: [EQPreset]
    private(set) var settings: AppSettings
    /// Live output levels, refreshed only while the menu is visible.
    let meters = MeterStore()
    /// Apps shown in the menu, in a stable order.
    private(set) var visibleApps: [AudioApp] = []

    @ObservationIgnored private let saveProfiles = Debouncer(delay: 0.8)
    @ObservationIgnored private let savePresets = Debouncer(delay: 0.8)
    @ObservationIgnored private let saveSettings = Debouncer(delay: 0.8)
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private weak var meterWindow: NSWindow?
    @ObservationIgnored private var requestedPermission = false
    /// When each app was last heard playing. Background processes stay listed and tapped for a
    /// while after they go quiet, so they don't flicker in and out between sounds.
    @ObservationIgnored private var lastPlayed: [String: Date] = [:]
    /// Regular apps that closed their audio connection but are still running.
    @ObservationIgnored private var retainedApps: [String: AudioApp] = [:]
    @ObservationIgnored private var lingerCheck: DispatchWorkItem?
    static let lingerDuration: TimeInterval = 60

    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        // Unit tests use the app as host; never touch the user's audio or saved state there.
        guard !Self.isRunningTests else {
            profiles = [:]; presets = []; settings = AppSettings()
            return
        }
        profiles = Storage.load([String: DeviceProfile].self, from: "devices.json") ?? [:]
        presets = Storage.load([EQPreset].self, from: "presets.json") ?? []
        settings = Storage.load(AppSettings.self, from: "settings.json") ?? AppSettings()

        devices.onDefaultOutputChanged = { [weak self] device in
            guard let self else { return }
            if let device {
                self.ensureProfile(for: device)
                self.applySavedSampleRate(device)
            }
            self.engine.setOutputDevice(device)
            self.rebuildChain()
            self.reconcile()
        }
        devices.onDeviceStateChanged = { [weak self] in self?.rebuildChain() }
        // Aggregate devices keep the rate they were created with, so rebuild them.
        devices.onSampleRateChanged = { [weak self] in self?.engine.rebuildRoutes() }
        devices.onDevicesConnected = { [weak self] connected in connected.forEach { self?.applySavedSampleRate($0) } }
        devices.outputs.forEach { applySavedSampleRate($0) }
        processes.onChange = { [weak self] _ in self?.reconcile() }

        if let device = devices.defaultOutput { ensureProfile(for: device) }
        engine.setOutputDevice(devices.defaultOutput)
        rebuildChain()
        reconcile()

        #if DEBUG
        DebugSnapshots.runIfRequested(model: self)
        #endif

        if ProcessInfo.processInfo.environment["ALTER_DEBUG_METERS"] != nil {
            // Debug aid: log output levels of intercepted apps once a second.
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for key in self.engine.activeKeys {
                        NSLog("Alter: level %@ %.1f dBFS", key, 20 * log10(max(Double(self.engine.takePeak(for: key)), 1e-6)))
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    func shutdown() {
        saveProfiles.flush(); savePresets.flush(); saveSettings.flush()
        engine.tearDownAll()
    }

    // MARK: - Engine wiring

    var currentDevice: OutputDevice? { devices.defaultOutput }

    var currentProfile: DeviceProfile? {
        currentDevice.map { profiles[$0.uid] ?? DeviceProfile(deviceName: $0.name) }
    }

    /// Apps Alter processes: every app with audio, except excluded ones and (optionally) apps
    /// that play to a different device. Processing all of them, rather than only those with a
    /// changed volume, avoids rebuilding the audio path mid-playback when a slider moves.
    private func shouldTap(_ app: AudioApp, now: Date) -> Bool {
        guard permission.status != .denied else { return false }
        if settings.excludedApps.contains(app.id) { return false }
        if settings.onlyTapDefaultDeviceApps, let device = currentDevice,
           !app.outputDeviceIDs.isEmpty, !app.outputDeviceIDs.contains(device.id) {
            return false
        }
        return isListed(app, now: now)
    }

    /// Regular apps are listed while they have audio; agents and tools only while they play
    /// (plus a grace period).
    private func isListed(_ app: AudioApp, now: Date) -> Bool {
        if app.isRegularApp || app.isPlaying { return true }
        if let last = lastPlayed[app.id], now.timeIntervalSince(last) < Self.lingerDuration { return true }
        return false
    }

    func reconcile() {
        let now = Date()
        let apps = processes.apps
        for app in apps where app.isPlaying { lastPlayed[app.id] = now }
        rememberApps()
        updateVisibleApps(apps, now: now)
        scheduleLingerCheck(now: now)

        let wanted = apps.filter { shouldTap($0, now: now) }
        if !wanted.isEmpty, permission.status == .unknown, !requestedPermission {
            requestedPermission = true
            NSLog("Alter: requesting audio capture permission")
            permission.request { [weak self] granted in
                NSLog("Alter: audio capture permission \(granted ? "granted" : "denied")")
                self?.reconcile()
            }
            return
        }
        for app in wanted {
            engine.setGain(volume(for: app.id).effectiveGain, for: app.id)
        }
        engine.reconcile(apps: wanted)
    }

    private func updateVisibleApps(_ apps: [AudioApp], now: Date) {
        let current = apps.filter { isListed($0, now: now) && !settings.excludedApps.contains($0.id) }
        let currentKeys = Set(current.map(\.id))
        for app in current where app.isRegularApp { retainedApps[app.id] = app }
        // Keep regular apps listed while they are still running, even if their audio connection
        // closed; drop them once they quit.
        retainedApps = retainedApps.filter { key, app in
            currentKeys.contains(key) || (NSRunningApplication(processIdentifier: app.pid).map { !$0.isTerminated } ?? false)
        }
        var list = current
        for (key, var app) in retainedApps where !currentKeys.contains(key) && !settings.excludedApps.contains(key) {
            app.isPlaying = false
            list.append(app)
        }
        list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if list != visibleApps { visibleApps = list }
    }

    /// Re-evaluates lingering background processes once their grace period runs out.
    private func scheduleLingerCheck(now: Date) {
        let pending = lastPlayed.values.map { $0.addingTimeInterval(Self.lingerDuration) }.filter { $0 > now }
        lastPlayed = lastPlayed.filter { now.timeIntervalSince($0.value) < Self.lingerDuration }
        lingerCheck?.cancel()
        guard let next = pending.min() else { return }
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        lingerCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + next.timeIntervalSince(now) + 0.5, execute: work)
    }

    private func rememberApps() {
        var changed = false
        for app in processes.apps where settings.knownApps[app.id] != app.name {
            settings.knownApps[app.id] = app.name
            changed = true
        }
        if changed { persistSettings() }
    }

    func rebuildChain() {
        guard let device = currentDevice else {
            engine.publish(.passthrough())
            return
        }
        let profile = profiles[device.uid] ?? DeviceProfile(deviceName: device.name)
        let software: Float = devices.hardwareVolume == nil ? (settings.softwareVolumes[device.uid] ?? 1) : 1
        let state = ChainBuilder.build(.init(profile: profile,
                                             correction: preset(profile.correctionPresetID),
                                             custom: preset(profile.customEQPresetID),
                                             volumeDB: Double(devices.volumeDecibels),
                                             softwareGain: software,
                                             globalBypass: settings.globalBypass,
                                             sampleRate: devices.sampleRate))
        engine.publish(state)
    }

    // MARK: - Profiles

    private func ensureProfile(for device: OutputDevice) {
        if profiles[device.uid] == nil {
            profiles[device.uid] = DeviceProfile(deviceName: device.name)
            persistProfiles()
        } else if profiles[device.uid]?.deviceName != device.name {
            profiles[device.uid]?.deviceName = device.name
            persistProfiles()
        }
    }

    func profile(for uid: String) -> DeviceProfile {
        profiles[uid] ?? DeviceProfile(deviceName: devices.outputs.first { $0.uid == uid }?.name ?? uid)
    }

    func updateProfile(_ uid: String, _ change: (inout DeviceProfile) -> Void) {
        var p = profile(for: uid)
        change(&p)
        profiles[uid] = p
        persistProfiles()
        if uid == currentDevice?.uid { rebuildChain() }
    }

    func forgetProfile(_ uid: String) {
        profiles[uid] = nil
        persistProfiles()
        if uid == currentDevice?.uid, let d = currentDevice { ensureProfile(for: d); rebuildChain() }
    }

    /// Known devices: connected outputs plus any device that has a saved profile.
    var profileDevices: [(uid: String, name: String, connected: Bool)] {
        var list = devices.outputs.map { (uid: $0.uid, name: $0.name, connected: true) }
        let connected = Set(list.map(\.uid))
        for (uid, p) in profiles where !connected.contains(uid) {
            list.append((uid: uid, name: p.deviceName.isEmpty ? uid : p.deviceName, connected: false))
        }
        return list
    }

    private func persistProfiles() {
        saveProfiles.schedule { [weak self] in
            guard let self else { return }
            Storage.save(self.profiles, to: "devices.json")
        }
    }

    // MARK: - Sample rate

    /// Saves `rate` as the device's preferred sample rate (nil: don't change it) and applies it
    /// right away if the device is connected.
    func setSampleRate(_ rate: Double?, for uid: String) {
        updateProfile(uid) { $0.sampleRate = rate }
        if let rate, let device = devices.outputs.first(where: { $0.uid == uid }) {
            devices.setSampleRate(rate, for: device)
        }
    }

    private func applySavedSampleRate(_ device: OutputDevice) {
        guard let rate = profiles[device.uid]?.sampleRate else { return }
        devices.setSampleRate(rate, for: device)
    }

    // MARK: - Presets

    func preset(_ id: UUID?) -> EQPreset? {
        guard let id else { return nil }
        return presets.first { $0.id == id }
    }

    func presets(of kind: EQPreset.Kind) -> [EQPreset] {
        presets.filter { $0.kind == kind }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func addPreset(_ preset: EQPreset) -> EQPreset {
        var p = preset
        if presets.contains(where: { $0.id == p.id }) { p.id = UUID() }
        presets.append(p)
        persistPresets()
        return p
    }

    func updatePreset(_ preset: EQPreset) {
        guard let i = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[i] = preset
        persistPresets()
        if let p = currentProfile, p.correctionPresetID == preset.id || p.customEQPresetID == preset.id {
            rebuildChain()
        }
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        for (uid, var p) in profiles {
            var changed = false
            if p.correctionPresetID == id { p.correctionPresetID = nil; changed = true }
            if p.customEQPresetID == id { p.customEQPresetID = nil; changed = true }
            if changed { profiles[uid] = p }
        }
        persistPresets(); persistProfiles()
        rebuildChain()
    }

    private func persistPresets() {
        savePresets.schedule { [weak self] in
            guard let self else { return }
            Storage.save(self.presets, to: "presets.json")
        }
    }

    // MARK: - App volumes

    func volume(for key: String) -> AppVolume { settings.appVolumes[key] ?? AppVolume() }

    func setVolume(_ volume: AppVolume, for key: String) {
        settings.appVolumes[key] = volume.isDefault ? nil : volume
        engine.setGain(volume.effectiveGain, for: key)
        persistSettings()
    }

    // MARK: - Settings

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        persistSettings()
        rebuildChain()
        reconcile()
    }

    var softwareVolume: Float {
        guard let d = currentDevice else { return 1 }
        return settings.softwareVolumes[d.uid] ?? 1
    }

    func setSoftwareVolume(_ v: Float) {
        guard let d = currentDevice else { return }
        settings.softwareVolumes[d.uid] = v
        persistSettings()
        rebuildChain()
    }

    private func persistSettings() {
        saveSettings.schedule { [weak self] in
            guard let self else { return }
            Storage.save(self.settings, to: "settings.json")
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Alter: launch at login: \(error)")
            }
        }
    }

    // MARK: - Meters

    /// Starts polling levels for the menu shown in `window`. Polling stops on its own as soon as
    /// that window is no longer visible, so nothing runs while the menu is closed.
    func startMeters(in window: NSWindow?) {
        if let window { meterWindow = window }
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMeters() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
        meters.reset()
    }

    private func updateMeters() {
        guard let window = meterWindow, window.isVisible, window.occlusionState.contains(.visible) else {
            stopMeters()
            return
        }
        var next: [String: Float] = [:]
        for key in engine.activeKeys {
            // Simple decay so meters fall smoothly.
            next[key] = max(engine.takePeak(for: key), meters.level(key) * 0.82)
        }
        meters.update(next)
    }
}

/// Meter levels live apart from the rest of the model so that only the meters redraw 20 times
/// per second, not the rows and sliders around them.
@MainActor
@Observable
final class MeterStore {
    private(set) var levels: [String: Float] = [:]

    func level(_ key: String) -> Float { levels[key] ?? 0 }

    func update(_ next: [String: Float]) {
        if next != levels { levels = next }
    }

    func reset() { levels = [:] }
}
