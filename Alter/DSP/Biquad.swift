import Foundation

enum FilterType: String, Codable, CaseIterable, Identifiable {
    case peaking, lowShelf, highShelf, lowPass, highPass, notch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .peaking: "Peak"
        case .lowShelf: "Low Shelf"
        case .highShelf: "High Shelf"
        case .lowPass: "Low Pass"
        case .highPass: "High Pass"
        case .notch: "Notch"
        }
    }

    var hasGain: Bool {
        switch self {
        case .peaking, .lowShelf, .highShelf: true
        default: false
        }
    }
}

/// Normalized biquad coefficients (a0 == 1).
struct BiquadCoefficients: Equatable {
    var b0: Double = 1, b1: Double = 0, b2: Double = 0, a1: Double = 0, a2: Double = 0

    static let identity = BiquadCoefficients()

    /// RBJ Audio EQ Cookbook designs.
    static func design(_ type: FilterType, frequency: Double, gainDB: Double, q: Double, sampleRate fs: Double) -> BiquadCoefficients {
        let f = min(max(frequency, 1), fs * 0.499)
        let q = max(q, 0.01)
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f / fs
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0

        switch type {
        case .peaking:
            b0 = 1 + alpha * A; b1 = -2 * cosw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cosw; a2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cosw + s)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosw)
            b2 = A * ((A + 1) - (A - 1) * cosw - s)
            a0 = (A + 1) + (A - 1) * cosw + s
            a1 = -2 * ((A - 1) + (A + 1) * cosw)
            a2 = (A + 1) + (A - 1) * cosw - s
        case .highShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cosw + s)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosw)
            b2 = A * ((A + 1) + (A - 1) * cosw - s)
            a0 = (A + 1) - (A - 1) * cosw + s
            a1 = 2 * ((A - 1) - (A + 1) * cosw)
            a2 = (A + 1) - (A - 1) * cosw - s
        case .lowPass:
            b0 = (1 - cosw) / 2; b1 = 1 - cosw; b2 = (1 - cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosw) / 2; b1 = -(1 + cosw); b2 = (1 + cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cosw; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Magnitude response in dB at `frequency`.
    func magnitudeDB(at frequency: Double, sampleRate fs: Double) -> Double {
        let w = 2 * Double.pi * frequency / fs
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        let num = nr * nr + ni * ni, den = dr * dr + di * di
        return 10 * log10(max(num, 1e-30) / max(den, 1e-30))
    }
}

extension FilterType {
    /// Converts an octave bandwidth to Q (used by EqualizerAPO "BW Oct" filters).
    static func q(fromBandwidthOctaves bw: Double) -> Double {
        let p = pow(2, bw)
        return sqrt(p) / (p - 1)
    }

    /// Converts a shelf slope in dB/octave (EqualizerAPO "LS 6dB") to the cookbook Q for a given gain.
    static func shelfQ(slopeDB: Double, gainDB: Double) -> Double {
        let A = pow(10, gainDB / 40)
        let S = max(min(slopeDB / 12, 1), 0.01)
        let inv = (A + 1 / A) * (1 / S - 1) + 2
        return inv > 0 ? 1 / sqrt(inv) : 0.7071
    }
}
