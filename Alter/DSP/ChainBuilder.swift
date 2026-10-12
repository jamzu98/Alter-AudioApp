import Foundation

/// Turns a device profile plus the presets it references into a ChainState.
enum ChainBuilder {
    struct Inputs {
        var profile: DeviceProfile
        var correction: EQPreset?
        var custom: EQPreset?
        /// Current hardware volume of the device in dB (for loudness compensation).
        var volumeDB: Double = 0
        /// Software volume for devices without a hardware volume control.
        var softwareGain: Float = 1
        var globalBypass = false
        var sampleRate: Double = 48_000
    }

    /// The biquad sections the chain runs, in order.
    static func sections(_ i: Inputs) -> [BiquadCoefficients] {
        let p = i.profile
        let fs = i.sampleRate
        var out: [BiquadCoefficients] = []
        if p.correctionEnabled, let c = i.correction {
            out += c.activeBands.map { $0.coefficients(sampleRate: fs) }
        }
        if p.customEQEnabled, let c = i.custom {
            out += c.activeBands.map { $0.coefficients(sampleRate: fs) }
        }
        if p.tone.enabled {
            out += p.tone.pultec ? pultecSections(p.tone, sampleRate: fs) : toneSections(p.tone, sampleRate: fs)
        }
        if p.loudness.enabled {
            let (bass, treble) = loudnessGains(p.loudness, volumeDB: i.volumeDB)
            if bass > 0.05 { out.append(.design(.lowShelf, frequency: 90, gainDB: bass, q: 0.6, sampleRate: fs)) }
            if treble > 0.05 { out.append(.design(.highShelf, frequency: 9_000, gainDB: treble, q: 0.6, sampleRate: fs)) }
        }
        return out
    }

    static func toneSections(_ t: ToneSettings, sampleRate fs: Double) -> [BiquadCoefficients] {
        var out: [BiquadCoefficients] = []
        if abs(t.bassDB) > 0.01 {
            out.append(.design(.lowShelf, frequency: t.bassFrequency, gainDB: t.bassDB, q: 0.7071, sampleRate: fs))
        }
        if abs(t.trebleDB) > 0.01 {
            out.append(.design(.highShelf, frequency: t.trebleFrequency, gainDB: t.trebleDB, q: 0.7071, sampleRate: fs))
        }
        return out
    }

    /// Pultec EQP-1A style curves.
    /// - Bass boost: a slightly resonant low shelf plus the dip in the low mids above it — the
    ///   curve of the classic "boost and attenuate at the same frequency" Pultec trick.
    /// - Bass cut: a broad, gentle shelf, like the EQP-1A's low attenuator.
    /// - Treble boost: a broad bell centered on the chosen frequency, not a shelf, so the very
    ///   top rolls back down like the original's peaking high boost.
    /// - Treble cut: a gentle high shelf, like the high attenuator.
    static func pultecSections(_ t: ToneSettings, sampleRate fs: Double) -> [BiquadCoefficients] {
        var out: [BiquadCoefficients] = []
        let low = t.pultecLowFrequency
        if t.bassDB > 0.01 {
            out.append(.design(.lowShelf, frequency: low * 1.6, gainDB: t.bassDB, q: 0.9, sampleRate: fs))
            out.append(.design(.peaking, frequency: low * 4.5, gainDB: -t.bassDB * 0.4, q: 0.9, sampleRate: fs))
        } else if t.bassDB < -0.01 {
            out.append(.design(.lowShelf, frequency: low * 2, gainDB: t.bassDB, q: 0.5, sampleRate: fs))
        }
        if t.trebleDB > 0.01 {
            out.append(.design(.peaking, frequency: t.pultecHighFrequency, gainDB: t.trebleDB, q: 0.6, sampleRate: fs))
        } else if t.trebleDB < -0.01 {
            out.append(.design(.highShelf, frequency: t.pultecHighFrequency, gainDB: t.trebleDB, q: 0.5, sampleRate: fs))
        }
        return out
    }

    /// Simplified equal-loudness compensation: the quieter the device is relative to the
    /// reference, the more bass (and a little treble) is restored.
    static func loudnessGains(_ s: LoudnessSettings, volumeDB: Double) -> (bass: Double, treble: Double) {
        let attenuation = max(0, min(40, s.referenceDB - volumeDB))
        let bass = 12 * s.amount * attenuation / 40
        return (bass, bass * 0.35)
    }

    static func maxBoostDB(_ sections: [BiquadCoefficients], sampleRate: Double) -> Double {
        guard !sections.isEmpty else { return 0 }
        return FrequencyGrid.log(count: 192).map { f in
            sections.reduce(0) { $0 + $1.magnitudeDB(at: f, sampleRate: sampleRate) }
        }.max() ?? 0
    }

    static func preampDB(_ i: Inputs, sections: [BiquadCoefficients]) -> Double {
        let p = i.profile
        var db = p.preampDB
        if p.autoPreamp {
            db -= max(0, maxBoostDB(sections, sampleRate: i.sampleRate))
        } else {
            if p.correctionEnabled, let c = i.correction { db += c.preampDB }
            if p.customEQEnabled, let c = i.custom { db += c.preampDB }
        }
        return db
    }

    static func build(_ i: Inputs) -> ChainState {
        let p = i.profile
        guard p.enabled, !i.globalBypass else {
            return ChainState(sampleRate: i.sampleRate, enabled: false, softwareGain: i.softwareGain)
        }
        let secs = sections(i)
        let cf = p.crossfeed.enabled
            ? CrossfeedCoefficients(cutoff: p.crossfeed.effective.cutoff, feedDB: p.crossfeed.effective.feedDB, sampleRate: i.sampleRate)
            : nil
        return ChainState(sampleRate: i.sampleRate,
                          enabled: true,
                          preGainDB: preampDB(i, sections: secs),
                          sections: secs,
                          crossfeed: cf,
                          balance: p.balance,
                          trimDB: p.gainTrimDB,
                          softwareGain: i.softwareGain,
                          limiter: p.limiter)
    }
}
