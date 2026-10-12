import Foundation

/// Searches and downloads headphone correction presets from the AutoEQ project
/// (github.com/jaakkopasanen/AutoEq). Only touches the network when the user searches.
actor AutoEQClient {
    struct Entry: Identifiable, Hashable, Sendable {
        var id: String { path }
        let name: String
        /// Path relative to `results/`, percent-encoded as in the index.
        let path: String
        let source: String
        let rig: String?

        var sourceDescription: String { rig.map { "\(source) · \($0)" } ?? source }
    }

    enum ClientError: LocalizedError {
        case badResponse(Int)
        var errorDescription: String? {
            switch self {
            case let .badResponse(code): "AutoEQ server returned HTTP \(code)."
            }
        }
    }

    static let shared = AutoEQClient()

    init() {}

    private let base = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/")!
    private var entries: [Entry]?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    private var cacheURL: URL { Storage.directory.appendingPathComponent("AutoEQ-INDEX.md") }

    /// Loads the index from the local cache, or downloads it when missing or `refresh` is true.
    func index(refresh: Bool = false) async throws -> [Entry] {
        if !refresh, let entries { return entries }
        if !refresh, let data = try? Data(contentsOf: cacheURL), let text = String(data: data, encoding: .utf8) {
            let parsed = Self.parseIndex(text)
            if !parsed.isEmpty { entries = parsed; return parsed }
        }
        let text = try await fetchText(base.appendingPathComponent("INDEX.md"))
        try? text.data(using: .utf8)?.write(to: cacheURL, options: .atomic)
        let parsed = Self.parseIndex(text)
        entries = parsed
        return parsed
    }

    func search(_ query: String) async throws -> [Entry] {
        let all = try await index()
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        return all.filter { e in
            let hay = e.name.lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    func download(_ entry: Entry) async throws -> EQPreset {
        let decoded = entry.path.removingPercentEncoding ?? entry.path
        let folderName = decoded.split(separator: "/").last.map(String.init) ?? entry.name
        let fileURL = base.appendingPathComponent(decoded).appendingPathComponent("\(folderName) ParametricEQ.txt")
        let text = try await fetchText(fileURL)
        var preset = try PresetParser.parseParametric(text, name: entry.name)
        preset.kind = .correction
        preset.source = .autoEQ
        preset.notes = "AutoEQ · \(entry.sourceDescription)"
        return preset
    }

    private func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.badResponse(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses lines like `- [Sennheiser HD 600](./oratory1990/over-ear/Sennheiser%20HD%20600) by oratory1990 on GRAS`.
    static func parseIndex(_ text: String) -> [Entry] {
        var result: [Entry] = []
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("- ["),
                  let nameEnd = line.range(of: "]("),
                  let pathEnd = line.range(of: ")", range: nameEnd.upperBound..<line.endIndex)
            else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<nameEnd.lowerBound])
            var path = String(line[nameEnd.upperBound..<pathEnd.lowerBound])
            var tail = line[pathEnd.upperBound...]
            // Paths can contain ")" too, e.g. "(ANC On)": the path really ends at the last ") by ".
            if let by = line.range(of: ") by ", options: .backwards) {
                path = String(line[nameEnd.upperBound..<by.lowerBound])
                tail = line[line.index(by.lowerBound, offsetBy: 1)...]
            }
            if path.hasPrefix("./") { path.removeFirst(2) }
            var source = "", rig: String?
            let rest = tail.trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("by ") {
                let s = rest.dropFirst(3)
                if let on = s.range(of: " on ") {
                    source = String(s[..<on.lowerBound]); rig = String(s[on.upperBound...])
                } else { source = String(s) }
            }
            result.append(Entry(name: name, path: path, source: source, rig: rig))
        }
        return result
    }
}
