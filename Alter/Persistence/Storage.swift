import Foundation

struct AppVolume: Codable, Hashable {
    var volume: Float = 1
    var muted = false

    var effectiveGain: Float { muted ? 0 : volume }
    var isDefault: Bool { !muted && abs(volume - 1) < 0.001 }
}

struct AppSettings: Codable {
    var appVolumes: [String: AppVolume] = [:]
    /// Names of apps seen before, so they can be listed and excluded while not running.
    var knownApps: [String: String] = [:]
    var excludedApps: Set<String> = []
    var globalBypass = false
    /// Leave apps alone that play to a device other than the default output (e.g. a DAW on an interface).
    var onlyTapDefaultDeviceApps = true
    /// Software volume for devices without a hardware volume control, by device UID.
    var softwareVolumes: [String: Float] = [:]
    var graphicEQBandCount = 10

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        appVolumes = try c.decodeIfPresent([String: AppVolume].self, forKey: .appVolumes) ?? d.appVolumes
        knownApps = try c.decodeIfPresent([String: String].self, forKey: .knownApps) ?? d.knownApps
        excludedApps = try c.decodeIfPresent(Set<String>.self, forKey: .excludedApps) ?? d.excludedApps
        globalBypass = try c.decodeIfPresent(Bool.self, forKey: .globalBypass) ?? d.globalBypass
        onlyTapDefaultDeviceApps = try c.decodeIfPresent(Bool.self, forKey: .onlyTapDefaultDeviceApps) ?? d.onlyTapDefaultDeviceApps
        softwareVolumes = try c.decodeIfPresent([String: Float].self, forKey: .softwareVolumes) ?? d.softwareVolumes
        graphicEQBandCount = try c.decodeIfPresent(Int.self, forKey: .graphicEQBandCount) ?? d.graphicEQBandCount
    }
}

/// JSON files in ~/Library/Application Support/Alter.
enum Storage {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Alter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Keep the unreadable file for the user instead of silently overwriting it.
            let backup = directory.appendingPathComponent(name + ".corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            NSLog("Alter: could not read \(name): \(error)")
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            NSLog("Alter: could not save \(name): \(error)")
        }
    }
}

/// Coalesces frequent saves (e.g. while dragging a slider).
@MainActor
final class Debouncer {
    private var work: DispatchWorkItem?
    private let delay: TimeInterval

    init(delay: TimeInterval) { self.delay = delay }

    func schedule(_ action: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: action)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func flush() {
        guard let work else { return }
        work.perform()
        work.cancel()
        self.work = nil
    }
}
