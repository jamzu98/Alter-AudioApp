import XCTest
@testable import Alter

final class ParserTests: XCTestCase {
    func testParsesAutoEQParametric() throws {
        let preset = try PresetParser.parse(try fixture("HD600 ParametricEQ.txt"), name: "HD 600")
        XCTAssertEqual(preset.preampDB, -6.3, accuracy: 0.001)
        XCTAssertEqual(preset.bands.count, 10)
        let first = preset.bands[0]
        XCTAssertEqual(first.type, .lowShelf)
        XCTAssertEqual(first.frequency, 105)
        XCTAssertEqual(first.gainDB, 6.5)
        XCTAssertEqual(first.q, 0.7)
        XCTAssertEqual(preset.bands[5].type, .highShelf)
        XCTAssertEqual(preset.bands[9].frequency, 5433)
        XCTAssertEqual(preset.bands[9].q, 5.7)
    }

    func testParsesEqualizerAPOVariants() throws {
        let text = """
        # comment line
        Preamp: -3 dB
        Filter 1: ON PK Fc 100 Hz Gain 3 dB BW Oct 1
        Filter 2: OFF PK Fc 2000 Hz Gain -4.5 dB Q 2
        Filter: ON LS 6dB Fc 80 Hz Gain 4 dB
        Filter 4: ON HP Fc 20 Hz
        Filter 5: ON NO Fc 3000 Hz
        Filter 6: ON HSC Fc 8000 Hz Gain -2 dB Q 0.71
        Filter 7: ON XYZ Fc 1 Hz
        """
        let p = try PresetParser.parseParametric(text, name: "APO")
        XCTAssertEqual(p.preampDB, -3)
        XCTAssertEqual(p.bands.count, 6)
        XCTAssertEqual(p.bands[0].q, 1.4142, accuracy: 0.001)
        XCTAssertFalse(p.bands[1].enabled)
        XCTAssertEqual(p.bands[2].type, .lowShelf)
        XCTAssertLessThan(p.bands[2].q, 0.7) // 6 dB/oct slope is gentler than Q 0.707
        XCTAssertEqual(p.bands[3].type, .highPass)
        XCTAssertEqual(p.bands[4].type, .notch)
        XCTAssertEqual(p.bands[5].type, .highShelf)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try PresetParser.parse("hello world", name: "x"))
        XCTAssertThrowsError(try PresetParser.parse("   ", name: "x"))
    }

    func testDetectsFormats() throws {
        XCTAssertEqual(PresetParser.detect(try fixture("HD600 ParametricEQ.txt")), .parametric)
        XCTAssertEqual(PresetParser.detect(try fixture("HD600 GraphicEQ.txt")), .graphic)
    }

    func testExportRoundTrip() throws {
        let original = try PresetParser.parseParametric(try fixture("HD600 ParametricEQ.txt"), name: "HD 600")
        var edited = original
        edited.bands.append(EQBand(type: .lowPass, frequency: 18_000, gainDB: 0, q: 0.71))
        edited.bands.append(EQBand(type: .notch, frequency: 3000, gainDB: 0, q: 4, enabled: false))
        let text = PresetExporter.parametricText(edited)
        let back = try PresetParser.parseParametric(text, name: "HD 600")
        XCTAssertEqual(back.preampDB, edited.preampDB, accuracy: 0.05)
        XCTAssertEqual(back.bands.count, edited.bands.count)
        for (a, b) in zip(edited.bands, back.bands) {
            XCTAssertEqual(a.type, b.type)
            XCTAssertEqual(a.frequency, b.frequency, accuracy: 0.5)
            XCTAssertEqual(a.gainDB, b.gainDB, accuracy: 0.05)
            XCTAssertEqual(a.q, b.q, accuracy: 0.005)
            XCTAssertEqual(a.enabled, b.enabled)
        }
    }
}

final class GraphicEQFitterTests: XCTestCase {
    func testFitsAutoEQGraphicCurve() throws {
        let text = try fixture("HD600 GraphicEQ.txt")
        let points = try PresetParser.parseGraphic(text)
        XCTAssertGreaterThan(points.count, 100)

        let result = GraphicEQFitter.fit(points: points, bandCount: 10)
        XCTAssertEqual(result.preset.bands.count, 10)
        XCTAssertLessThan(result.rmsError, 0.6, "RMS fit error \(result.rmsError) dB")

        // The fitted curve (with preamp) should track the target between 30 Hz and 10 kHz.
        for f in [50.0, 200, 1000, 3000, 8000] {
            let target = GraphicEQFitter.interpolate(points, at: f)
            let fitted = result.preset.responseDB(at: f) + result.preset.preampDB
            XCTAssertEqual(fitted, target, accuracy: 1.5, "at \(f) Hz")
        }
    }

    func testParseUsesGraphicFitter() throws {
        let preset = try PresetParser.parse(try fixture("HD600 GraphicEQ.txt"), name: "HD 600 G", bandCount: 6)
        XCTAssertEqual(preset.name, "HD 600 G")
        XCTAssertEqual(preset.bands.count, 6)
        XCTAssertTrue(preset.notes.contains("RMS"))
    }
}

final class AutoEQIndexTests: XCTestCase {
    func testParsesIndexLines() {
        let text = """
        # Index
        - [Sennheiser HD 600](./oratory1990/over-ear/Sennheiser%20HD%20600) by oratory1990
        - [1MORE Aero (ANC Off)](./HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)) by HypetheSonics on GRAS RA0045
        not a line
        """
        let entries = AutoEQClient.parseIndex(text)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Sennheiser HD 600")
        XCTAssertEqual(entries[0].path, "oratory1990/over-ear/Sennheiser%20HD%20600")
        XCTAssertEqual(entries[0].source, "oratory1990")
        XCTAssertNil(entries[0].rig)
        XCTAssertEqual(entries[1].name, "1MORE Aero (ANC Off)")
        XCTAssertEqual(entries[1].path, "HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)")
        XCTAssertEqual(entries[1].rig, "GRAS RA0045")
    }
}

/// Hits the network; runs only with ALTER_NETWORK_TESTS=1.
final class AutoEQLiveTests: XCTestCase {
    func testSearchAndDownload() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ALTER_NETWORK_TESTS"] != nil, "network tests disabled")
        let client = AutoEQClient()
        let found = try await client.search("hd 600")
        let entry = try XCTUnwrap(found.first { $0.name == "Sennheiser HD 600" && $0.source == "oratory1990" })
        let preset = try await client.download(entry)
        XCTAssertEqual(preset.bands.count, 10)
        XCTAssertEqual(preset.source, .autoEQ)
        // Names with parentheses need careful URL encoding.
        let ancResults = try await client.search("1MORE Aero (ANC On)")
        let anc = try XCTUnwrap(ancResults.first)
        let ancPreset = try await client.download(anc)
        XCTAssertFalse(ancPreset.bands.isEmpty)
    }
}
