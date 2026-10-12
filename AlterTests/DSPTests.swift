import CoreAudio
import XCTest
@testable import Alter

final class BiquadTests: XCTestCase {
    let fs = 48_000.0

    func testPeakingGainAtCenter() {
        for gain in [-12.0, -3, 3, 6, 12] {
            let c = BiquadCoefficients.design(.peaking, frequency: 1000, gainDB: gain, q: 1.4, sampleRate: fs)
            XCTAssertEqual(c.magnitudeDB(at: 1000, sampleRate: fs), gain, accuracy: 0.01)
            XCTAssertEqual(c.magnitudeDB(at: 20, sampleRate: fs), 0, accuracy: 0.05)
        }
    }

    func testShelves() {
        let low = BiquadCoefficients.design(.lowShelf, frequency: 105, gainDB: 6.5, q: 0.7, sampleRate: fs)
        XCTAssertEqual(low.magnitudeDB(at: 5, sampleRate: fs), 6.5, accuracy: 0.05)
        XCTAssertEqual(low.magnitudeDB(at: 105, sampleRate: fs), 3.25, accuracy: 0.05)
        XCTAssertEqual(low.magnitudeDB(at: 10_000, sampleRate: fs), 0, accuracy: 0.05)

        let high = BiquadCoefficients.design(.highShelf, frequency: 10_000, gainDB: -3.1, q: 0.7, sampleRate: fs)
        XCTAssertEqual(high.magnitudeDB(at: 10_000, sampleRate: fs), -1.55, accuracy: 0.05)
        XCTAssertEqual(high.magnitudeDB(at: 100, sampleRate: fs), 0, accuracy: 0.05)
    }

    func testPassFilters() {
        let lp = BiquadCoefficients.design(.lowPass, frequency: 2000, gainDB: 0, q: 0.7071, sampleRate: fs)
        XCTAssertEqual(lp.magnitudeDB(at: 2000, sampleRate: fs), -3.01, accuracy: 0.02)
        XCTAssertEqual(lp.magnitudeDB(at: 50, sampleRate: fs), 0, accuracy: 0.01)
        let hp = BiquadCoefficients.design(.highPass, frequency: 80, gainDB: 0, q: 0.7071, sampleRate: fs)
        XCTAssertEqual(hp.magnitudeDB(at: 80, sampleRate: fs), -3.01, accuracy: 0.02)
        let notch = BiquadCoefficients.design(.notch, frequency: 3000, gainDB: 0, q: 2, sampleRate: fs)
        XCTAssertLessThan(notch.magnitudeDB(at: 3000, sampleRate: fs), -60)
    }

    func testBandwidthToQ() {
        XCTAssertEqual(FilterType.q(fromBandwidthOctaves: 1), 1.4142, accuracy: 0.001)
    }
}

final class StreamProcessorTests: XCTestCase {
    let fs = 48_000.0

    /// Runs a sine through the processor and returns the steady-state output amplitude of each channel.
    private func amplitude(of state: ChainState, frequency: Double, input: Float = 0.25,
                           left: Bool = true, right: Bool = true) -> (Float, Float) {
        let p = StreamProcessor()
        let frames = 512
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { l.deallocate(); r.deallocate() }
        var phase = 0.0
        var peakL: Float = 0, peakR: Float = 0
        for block in 0..<200 {
            for n in 0..<frames {
                let s = Float(sin(phase)) * input
                phase += 2 * .pi * frequency / fs
                l[n] = left ? s : 0
                r[n] = right ? s : 0
            }
            p.process(left: l, right: r, frames: frames, state: state, appGain: 1)
            if block > 150 {
                for n in 0..<frames { peakL = max(peakL, abs(l[n])); peakR = max(peakR, abs(r[n])) }
            }
        }
        return (peakL, peakR)
    }

    func testPassthroughIsTransparent() {
        let (l, r) = amplitude(of: .passthrough(sampleRate: fs), frequency: 1000)
        XCTAssertEqual(l, 0.25, accuracy: 0.001)
        XCTAssertEqual(r, 0.25, accuracy: 0.001)
    }

    func testEQMatchesDesignedResponse() {
        let peak = BiquadCoefficients.design(.peaking, frequency: 1000, gainDB: 6, q: 1, sampleRate: fs)
        let state = ChainState(sampleRate: fs, enabled: true, sections: [peak])
        let (atCenter, _) = amplitude(of: state, frequency: 1000)
        XCTAssertEqual(20 * log10(Double(atCenter) / 0.25), 6, accuracy: 0.05)
        let (far, _) = amplitude(of: state, frequency: 60)
        XCTAssertEqual(20 * log10(Double(far) / 0.25), peak.magnitudeDB(at: 60, sampleRate: fs), accuracy: 0.05)
    }

    func testPreampTrimAndBalance() {
        let state = ChainState(sampleRate: fs, enabled: true, preGainDB: -6, balance: 0.5, trimDB: 3)
        let (l, r) = amplitude(of: state, frequency: 500)
        XCTAssertEqual(20 * log10(Double(r) / 0.25), -3, accuracy: 0.05)
        XCTAssertEqual(Double(l), 0.25 * pow(10, -3.0 / 20) * 0.5, accuracy: 0.002)
    }

    func testLimiterKeepsCeiling() {
        let boost = BiquadCoefficients.design(.peaking, frequency: 100, gainDB: 12, q: 0.7, sampleRate: fs)
        var settings = LimiterSettings()
        settings.ceilingDB = -1
        let state = ChainState(sampleRate: fs, enabled: true, sections: [boost], limiter: settings)
        let (l, r) = amplitude(of: state, frequency: 100, input: 0.9)
        let ceiling = Float(pow(10, -1.0 / 20))
        XCTAssertLessThanOrEqual(l, ceiling + 1e-6)
        XCTAssertLessThanOrEqual(r, ceiling + 1e-6)
        XCTAssertGreaterThan(l, ceiling * 0.8, "Limiter should not crush the level far below the ceiling")
    }

    func testCrossfeedBleedsHardPannedLowsToOtherSide() {
        let cf = CrossfeedCoefficients(cutoff: 700, feedDB: 4.5, sampleRate: fs)
        let state = ChainState(sampleRate: fs, enabled: true, crossfeed: cf)
        let (l, r) = amplitude(of: state, frequency: 200, right: false)
        XCTAssertGreaterThan(r, 0.05)
        XCTAssertGreaterThan(l, r)
        // A centered (mono) low tone keeps roughly its level.
        let (ml, _) = amplitude(of: state, frequency: 100)
        XCTAssertEqual(20 * log10(Double(ml) / 0.25), 0, accuracy: 1.0)
    }

    func testMuteRampsToSilence() {
        let p = StreamProcessor()
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 256), r = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer { l.deallocate(); r.deallocate() }
        let state = ChainState.passthrough(sampleRate: fs)
        for _ in 0..<4 {
            l.update(repeating: 0.5, count: 256); r.update(repeating: 0.5, count: 256)
            p.process(left: l, right: r, frames: 256, state: state, appGain: 0)
        }
        XCTAssertEqual(l[255], 0, accuracy: 1e-6)
    }
}

final class ChainBuilderTests: XCTestCase {
    func testAutoPreampOffsetsMaxBoost() throws {
        let text = try fixture("HD600 ParametricEQ.txt")
        let preset = try PresetParser.parseParametric(text, name: "HD600")
        var profile = DeviceProfile()
        profile.autoPreamp = true
        let inputs = ChainBuilder.Inputs(profile: profile, correction: preset)
        let sections = ChainBuilder.sections(inputs)
        XCTAssertEqual(sections.count, 10)
        let pre = ChainBuilder.preampDB(inputs, sections: sections)
        XCTAssertEqual(pre, -ChainBuilder.maxBoostDB(sections, sampleRate: 48_000), accuracy: 0.001)
        XCTAssertLessThan(pre, -5)

        profile.autoPreamp = false
        let manual = ChainBuilder.preampDB(.init(profile: profile, correction: preset), sections: sections)
        XCTAssertEqual(manual, -6.3, accuracy: 0.001)
    }

    func testDisabledProfileIsPassthrough() {
        var profile = DeviceProfile()
        profile.enabled = false
        profile.tone.enabled = true
        profile.tone.bassDB = 6
        XCTAssertFalse(ChainBuilder.build(.init(profile: profile)).enabled)
        profile.enabled = true
        XCTAssertFalse(ChainBuilder.build(.init(profile: profile, globalBypass: true)).enabled)
        XCTAssertEqual(ChainBuilder.build(.init(profile: profile)).sectionCount, 1)
    }

    func testLoudnessGrowsAsVolumeDrops() {
        let s = LoudnessSettings(enabled: true, amount: 1, referenceDB: 0)
        XCTAssertEqual(ChainBuilder.loudnessGains(s, volumeDB: 0).bass, 0)
        XCTAssertGreaterThan(ChainBuilder.loudnessGains(s, volumeDB: -30).bass, ChainBuilder.loudnessGains(s, volumeDB: -10).bass)
        XCTAssertEqual(ChainBuilder.loudnessGains(s, volumeDB: -80).bass, 12, accuracy: 0.001)
    }

    func testProfileDecodesWithMissingKeys() throws {
        let p = try JSONDecoder().decode(DeviceProfile.self, from: Data(#"{"deviceName":"X","gainTrimDB":-2}"#.utf8))
        XCTAssertEqual(p.deviceName, "X")
        XCTAssertEqual(p.gainTrimDB, -2)
        XCTAssertTrue(p.limiter.enabled)
        XCTAssertTrue(p.autoPreamp)
    }
}

func fixture(_ name: String) throws -> String {
    let bundle = Bundle(for: BiquadTests.self)
    let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        ?? bundle.url(forResource: name, withExtension: nil))
    return try String(contentsOf: url, encoding: .utf8)
}

final class PultecToneTests: XCTestCase {
    let fs = 48_000.0

    private func response(_ t: ToneSettings, at f: Double) -> Double {
        let sections = t.pultec ? ChainBuilder.pultecSections(t, sampleRate: fs) : ChainBuilder.toneSections(t, sampleRate: fs)
        return sections.reduce(0) { $0 + $1.magnitudeDB(at: f, sampleRate: fs) }
    }

    func testOffKeepsPlainShelves() {
        var t = ToneSettings()
        t.bassDB = 6; t.trebleDB = 6
        XCTAssertEqual(response(t, at: 10), 6, accuracy: 0.1)
        XCTAssertEqual(response(t, at: 20_000), 6, accuracy: 0.3)
        XCTAssertEqual(response(t, at: 1_000), 0, accuracy: 0.3)
    }

    func testBassBoostHasLowMidDip() {
        var t = ToneSettings()
        t.pultec = true; t.pultecLowFrequency = 60; t.bassDB = 8
        XCTAssertGreaterThan(response(t, at: 30), 6)
        // The signature dip in the low mids, which a plain shelf never has.
        let dip = FrequencyGrid.log(count: 200, low: 120, high: 600).map { response(t, at: $0) }.min() ?? 0
        XCTAssertLessThan(dip, -1.5)
        XCTAssertEqual(response(t, at: 5_000), 0, accuracy: 0.3)
    }

    func testTrebleBoostIsBellNotShelf() {
        var t = ToneSettings()
        t.pultec = true; t.pultecHighFrequency = 8_000; t.trebleDB = 6
        XCTAssertEqual(response(t, at: 8_000), 6, accuracy: 0.05)
        // A bell falls back down above its center, unlike a shelf.
        XCTAssertLessThan(response(t, at: 20_000), response(t, at: 8_000) - 1)
        XCTAssertEqual(response(t, at: 200), 0, accuracy: 0.2)
    }

    func testCutsAreGentleShelves() {
        var t = ToneSettings()
        t.pultec = true; t.bassDB = -6; t.trebleDB = -6
        XCTAssertEqual(response(t, at: 10), -6, accuracy: 0.3)
        XCTAssertEqual(response(t, at: 22_000), -6, accuracy: 1.0)
        XCTAssertGreaterThan(response(t, at: 1_000), -1.5)
    }

    func testOldToneSettingsStillDecode() throws {
        let t = try JSONDecoder().decode(ToneSettings.self, from: Data(#"{"enabled":true,"bassDB":3,"trebleDB":0,"bassFrequency":100,"trebleFrequency":10000}"#.utf8))
        XCTAssertTrue(t.enabled)
        XCTAssertEqual(t.bassDB, 3)
        XCTAssertFalse(t.pultec)
        XCTAssertEqual(t.pultecLowFrequency, 60)
    }
}

final class SampleRateTests: XCTestCase {
    func testLabels() {
        XCTAssertEqual(SampleRateFormat.label(44_100), "44.1 kHz")
        XCTAssertEqual(SampleRateFormat.label(48_000), "48 kHz")
        XCTAssertEqual(SampleRateFormat.label(88_200), "88.2 kHz")
        XCTAssertEqual(SampleRateFormat.label(192_000), "192 kHz")
    }

    func testProfileSampleRateIsOptionalAndRoundTrips() throws {
        let old = try JSONDecoder().decode(DeviceProfile.self, from: Data(#"{"deviceName":"X"}"#.utf8))
        XCTAssertNil(old.sampleRate)
        var p = DeviceProfile(deviceName: "Y")
        p.sampleRate = 96_000
        let back = try JSONDecoder().decode(DeviceProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.sampleRate, 96_000)
    }

    func testIOBufferKeepsAboutTheSameDuration() {
        XCTAssertEqual(TapSession.ioBufferFrames(sampleRate: 44_100, range: nil), 128)
        XCTAssertEqual(TapSession.ioBufferFrames(sampleRate: 48_000, range: nil), 128)
        XCTAssertEqual(TapSession.ioBufferFrames(sampleRate: 96_000, range: nil), 256)
        XCTAssertEqual(TapSession.ioBufferFrames(sampleRate: 192_000, range: nil), 512)
        // Devices that cannot go that low keep their smallest buffer.
        let range = AudioValueRange(mMinimum: 512, mMaximum: 4096)
        XCTAssertEqual(TapSession.ioBufferFrames(sampleRate: 48_000, range: range), 512)
    }
}
