import Foundation

/// Parses EqualizerAPO / AutoEQ text: ParametricEQ.txt, and GraphicEQ.txt (fitted to biquads).
enum PresetParser {
    enum ParseError: LocalizedError {
        case empty
        case nothingFound

        var errorDescription: String? {
            switch self {
            case .empty: "The file is empty."
            case .nothingFound: "No Preamp, Filter or GraphicEQ lines were found. Expected EqualizerAPO / AutoEQ format."
            }
        }
    }

    enum Format { case parametric, graphic }

    static func detect(_ text: String) -> Format? {
        let lower = text.lowercased()
        if lower.range(of: #"(^|\n)\s*filter\s*\d*\s*:"#, options: .regularExpression) != nil { return .parametric }
        if lower.contains("graphiceq:") { return .graphic }
        if lower.range(of: #"(^|\n)\s*preamp\s*:"#, options: .regularExpression) != nil { return .parametric }
        return nil
    }

    /// Parses either format. GraphicEQ curves are fitted with `GraphicEQFitter`.
    static func parse(_ text: String, name: String, bandCount: Int = 10) throws -> EQPreset {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ParseError.empty }
        switch detect(text) {
        case .parametric:
            return try parseParametric(text, name: name)
        case .graphic:
            let points = try parseGraphic(text)
            let fit = GraphicEQFitter.fit(points: points, bandCount: bandCount)
            var preset = fit.preset
            preset.name = name
            preset.notes = String(format: "Fitted from GraphicEQ (%d bands, RMS error %.2f dB)", fit.preset.bands.count, fit.rmsError)
            return preset
        case nil:
            throw ParseError.nothingFound
        }
    }

    // MARK: Parametric

    static func parseParametric(_ text: String, name: String) throws -> EQPreset {
        var preset = EQPreset(name: name, kind: .correction, source: .imported)
        var foundSomething = false
        var preamp = 0.0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let head = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let body = String(trimmed[trimmed.index(after: colon)...])

            if head == "preamp" {
                if let v = firstNumber(in: body) { preamp += v; foundSomething = true }
            } else if head.hasPrefix("filter") {
                if let band = parseFilter(body) {
                    preset.bands.append(band)
                    foundSomething = true
                }
            }
        }
        guard foundSomething else { throw ParseError.nothingFound }
        preset.preampDB = preamp
        return preset
    }

    /// Parses e.g. `ON PK Fc 105 Hz Gain -2.3 dB Q 0.70` or `ON LS 6dB Fc 100 Hz Gain 3 dB`.
    static func parseFilter(_ body: String) -> EQBand? {
        let tokens = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2 else { return nil }
        var i = 0
        var enabled = true
        switch tokens[0].uppercased() {
        case "ON": enabled = true; i = 1
        case "OFF": enabled = false; i = 1
        default: break
        }
        guard i < tokens.count else { return nil }

        let typeToken = tokens[i].uppercased()
        i += 1
        var slopeDB: Double?
        // "LS 6dB", "HS 12dB" or "LSC 6dB" carry a slope right after the type.
        if i < tokens.count, tokens[i].lowercased().hasSuffix("db"), let s = Double(tokens[i].dropLast(2)) {
            slopeDB = s; i += 1
        }

        let type: FilterType
        switch typeToken {
        case "PK", "PEQ", "MODAL": type = .peaking
        case "LS", "LSC", "LSQ", "LOWSHELF": type = .lowShelf
        case "HS", "HSC", "HSQ", "HIGHSHELF": type = .highShelf
        case "LP", "LPQ", "LOWPASS": type = .lowPass
        case "HP", "HPQ", "HIGHPASS": type = .highPass
        case "NO", "NOTCH": type = .notch
        case "NONE": return nil
        default: return nil
        }

        var fc: Double?
        var gain = 0.0
        var q: Double?
        var bw: Double?
        while i < tokens.count {
            let key = tokens[i].lowercased()
            let value = i + 1 < tokens.count ? Double(tokens[i + 1].replacingOccurrences(of: ",", with: ".")) : nil
            switch key {
            case "fc": fc = value; i += 2
            case "gain": gain = value ?? 0; i += 2
            case "q": q = value; i += 2
            case "bw":
                // "BW Oct 1.0"
                if i + 2 < tokens.count, tokens[i + 1].lowercased() == "oct" {
                    bw = Double(tokens[i + 2]); i += 3
                } else { bw = value; i += 2 }
            default: i += 1
            }
        }
        guard let fc, fc > 0 else { return nil }

        let resolvedQ: Double
        if let q {
            resolvedQ = q
        } else if let bw {
            resolvedQ = FilterType.q(fromBandwidthOctaves: bw)
        } else if type == .lowShelf || type == .highShelf {
            // EqualizerAPO defaults shelves without Q to 12 dB/oct; "LS 6dB" sets the slope explicitly.
            resolvedQ = FilterType.shelfQ(slopeDB: slopeDB ?? 12, gainDB: gain)
        } else {
            resolvedQ = 0.7071
        }
        return EQBand(type: type, frequency: fc, gainDB: type.hasGain ? gain : 0, q: resolvedQ, enabled: enabled)
    }

    // MARK: Graphic

    /// Parses `GraphicEQ: 20 -0.2; 21 -0.2; ...` into (frequency, gain) points.
    static func parseGraphic(_ text: String) throws -> [(Double, Double)] {
        guard let range = text.range(of: "GraphicEQ:", options: .caseInsensitive) else { throw ParseError.nothingFound }
        let body = text[range.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
        let points: [(Double, Double)] = body.split(separator: ";").compactMap { pair in
            let parts = pair.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let f = Double(parts[0]), let g = Double(parts[1]), f > 0 else { return nil }
            return (f, g)
        }
        guard points.count >= 2 else { throw ParseError.nothingFound }
        return points.sorted { $0.0 < $1.0 }
    }

    private static func firstNumber(in s: String) -> Double? {
        let scanner = Scanner(string: s.replacingOccurrences(of: ",", with: "."))
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " \t+")
        return scanner.scanDouble()
    }
}

/// Writes presets as EqualizerAPO / AutoEQ ParametricEQ.txt.
enum PresetExporter {
    static func parametricText(_ preset: EQPreset) -> String {
        var lines = [String(format: "Preamp: %.1f dB", preset.preampDB)]
        for (n, band) in preset.bands.enumerated() {
            let state = band.enabled ? "ON" : "OFF"
            let code: String
            switch band.type {
            case .peaking: code = "PK"
            case .lowShelf: code = "LSC"
            case .highShelf: code = "HSC"
            case .lowPass: code = "LPQ"
            case .highPass: code = "HPQ"
            case .notch: code = "NO"
            }
            var line = "Filter \(n + 1): \(state) \(code) Fc \(format(band.frequency)) Hz"
            if band.type.hasGain { line += String(format: " Gain %.1f dB", band.gainDB) }
            line += String(format: " Q %.2f", band.q)
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func format(_ f: Double) -> String {
        f >= 100 ? String(format: "%.0f", f) : String(format: "%.1f", f)
    }
}
