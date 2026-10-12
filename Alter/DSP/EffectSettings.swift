import Foundation

struct ToneSettings: Codable, Hashable {
    /// Frequency choices of the Pultec EQP-1A: low boost/atten and high boost.
    static let pultecLowFrequencies: [Double] = [20, 30, 60, 100]
    static let pultecHighFrequencies: [Double] = [3_000, 4_000, 5_000, 8_000, 10_000, 12_000, 16_000]

    var enabled = false
    var bassDB: Double = 0
    var trebleDB: Double = 0
    var bassFrequency: Double = 100
    var trebleFrequency: Double = 10_000
    /// Pultec-style curves: bass boost gets the low-mid dip above it, treble boost is a broad bell.
    var pultec = false
    var pultecLowFrequency: Double = 60
    var pultecHighFrequency: Double = 10_000

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ToneSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        bassDB = try c.decodeIfPresent(Double.self, forKey: .bassDB) ?? d.bassDB
        trebleDB = try c.decodeIfPresent(Double.self, forKey: .trebleDB) ?? d.trebleDB
        bassFrequency = try c.decodeIfPresent(Double.self, forKey: .bassFrequency) ?? d.bassFrequency
        trebleFrequency = try c.decodeIfPresent(Double.self, forKey: .trebleFrequency) ?? d.trebleFrequency
        pultec = try c.decodeIfPresent(Bool.self, forKey: .pultec) ?? d.pultec
        pultecLowFrequency = try c.decodeIfPresent(Double.self, forKey: .pultecLowFrequency) ?? d.pultecLowFrequency
        pultecHighFrequency = try c.decodeIfPresent(Double.self, forKey: .pultecHighFrequency) ?? d.pultecHighFrequency
    }
}

struct LoudnessSettings: Codable, Hashable {
    var enabled = false
    /// 0...1, scales the maximum compensation.
    var amount: Double = 0.6
    /// Device volume (dB) at which no compensation is applied.
    var referenceDB: Double = 0
}

struct CrossfeedSettings: Codable, Hashable {
    enum Preset: String, Codable, CaseIterable, Identifiable {
        case standard, chuMoy, janMeier, custom
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .standard: "Default (700 Hz, 4.5 dB)"
            case .chuMoy: "Chu Moy (700 Hz, 6 dB)"
            case .janMeier: "Jan Meier (650 Hz, 9.5 dB)"
            case .custom: "Custom"
            }
        }
        var values: (cutoff: Double, feedDB: Double)? {
            switch self {
            case .standard: (700, 4.5)
            case .chuMoy: (700, 6.0)
            case .janMeier: (650, 9.5)
            case .custom: nil
            }
        }
    }

    var enabled = false
    var preset: Preset = .standard
    var cutoff: Double = 700
    var feedDB: Double = 4.5

    var effective: (cutoff: Double, feedDB: Double) { preset.values ?? (cutoff, feedDB) }
}

struct LimiterSettings: Codable, Hashable {
    var enabled = true
    var ceilingDB: Double = -0.3
    var releaseMS: Double = 80
}

/// Everything Alter remembers for one output device.
struct DeviceProfile: Codable, Hashable {
    var deviceName: String = ""
    var enabled = true

    var correctionEnabled = true
    var correctionPresetID: UUID?
    var customEQEnabled = true
    var customEQPresetID: UUID?

    /// When on, the preamp is derived from the largest boost so EQ never clips.
    var autoPreamp = true
    /// Manual preamp in dB (added to preset preamps when auto preamp is off).
    var preampDB: Double = 0

    var tone = ToneSettings()
    var loudness = LoudnessSettings()
    var crossfeed = CrossfeedSettings()
    /// -1 (left) ... 1 (right).
    var balance: Double = 0
    /// User level-matching gain after all effects, in dB.
    var gainTrimDB: Double = 0
    var limiter = LimiterSettings()
    /// Preferred nominal sample rate for this device; nil leaves it as it is.
    var sampleRate: Double?

    init(deviceName: String = "") { self.deviceName = deviceName }

    // Decode tolerantly so new fields never break saved profiles.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeviceProfile()
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? d.deviceName
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        correctionEnabled = try c.decodeIfPresent(Bool.self, forKey: .correctionEnabled) ?? d.correctionEnabled
        correctionPresetID = try c.decodeIfPresent(UUID.self, forKey: .correctionPresetID)
        customEQEnabled = try c.decodeIfPresent(Bool.self, forKey: .customEQEnabled) ?? d.customEQEnabled
        customEQPresetID = try c.decodeIfPresent(UUID.self, forKey: .customEQPresetID)
        autoPreamp = try c.decodeIfPresent(Bool.self, forKey: .autoPreamp) ?? d.autoPreamp
        preampDB = try c.decodeIfPresent(Double.self, forKey: .preampDB) ?? d.preampDB
        tone = try c.decodeIfPresent(ToneSettings.self, forKey: .tone) ?? d.tone
        loudness = try c.decodeIfPresent(LoudnessSettings.self, forKey: .loudness) ?? d.loudness
        crossfeed = try c.decodeIfPresent(CrossfeedSettings.self, forKey: .crossfeed) ?? d.crossfeed
        balance = try c.decodeIfPresent(Double.self, forKey: .balance) ?? d.balance
        gainTrimDB = try c.decodeIfPresent(Double.self, forKey: .gainTrimDB) ?? d.gainTrimDB
        limiter = try c.decodeIfPresent(LimiterSettings.self, forKey: .limiter) ?? d.limiter
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate)
    }
}
