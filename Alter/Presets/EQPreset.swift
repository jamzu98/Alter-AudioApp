import Foundation

struct EQBand: Codable, Hashable, Identifiable {
    var id = UUID()
    var type: FilterType = .peaking
    var frequency: Double = 1000
    var gainDB: Double = 0
    var q: Double = 0.7071
    var enabled = true

    func coefficients(sampleRate: Double) -> BiquadCoefficients {
        .design(type, frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
    }
}

struct EQPreset: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        /// Headphone/speaker correction, e.g. an AutoEQ profile.
        case correction
        /// The user's own taste EQ.
        case custom
    }

    enum Source: String, Codable {
        case user, autoEQ, imported
    }

    var id = UUID()
    var name: String
    var kind: Kind = .custom
    var source: Source = .user
    var preampDB: Double = 0
    var bands: [EQBand] = []
    /// Free text, e.g. "oratory1990 (Harman over-ear 2018)".
    var notes: String = ""
    var created = Date()

    var activeBands: [EQBand] { bands.filter { $0.enabled } }

    /// Combined magnitude response of all enabled bands (preamp excluded).
    func responseDB(at frequency: Double, sampleRate: Double = 48_000) -> Double {
        activeBands.reduce(0) { $0 + $1.coefficients(sampleRate: sampleRate).magnitudeDB(at: frequency, sampleRate: sampleRate) }
    }

    /// Highest boost of the curve between 20 Hz and 20 kHz.
    func maxBoostDB(sampleRate: Double = 48_000) -> Double {
        FrequencyGrid.log(count: 256).map { responseDB(at: $0, sampleRate: sampleRate) }.max() ?? 0
    }

    static func flat(name: String = "Flat", kind: Kind = .custom) -> EQPreset {
        EQPreset(name: name, kind: kind)
    }

    /// A ten-band graphic-style starting point for a custom EQ.
    static func tenBand(name: String = "My EQ") -> EQPreset {
        let freqs: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        var bands = freqs.map { EQBand(type: .peaking, frequency: $0, gainDB: 0, q: 1.41) }
        bands[0].type = .lowShelf; bands[0].q = 0.7071
        bands[9].type = .highShelf; bands[9].q = 0.7071
        return EQPreset(name: name, kind: .custom, bands: bands)
    }
}

enum FrequencyGrid {
    /// Log-spaced frequencies from `low` to `high`.
    static func log(count: Int, low: Double = 20, high: Double = 20_000) -> [Double] {
        let a = Foundation.log10(low), b = Foundation.log10(high)
        return (0..<count).map { pow(10, a + (b - a) * Double($0) / Double(count - 1)) }
    }
}
