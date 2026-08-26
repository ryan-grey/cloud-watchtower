import Foundation

/// Parser for the shared AWS config/credentials INI files.
struct INIFile {
    private(set) var sections: [String: [String: String]] = [:]

    init(contentsOf url: URL) throws {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var current: String?
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if sections[current!] == nil { sections[current!] = [:] }
                continue
            }
            guard let current, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            sections[current]?[key] = value
        }
    }

    /// The credentials file uses `[name]`; the config file uses `[profile name]`
    /// for everything except `[default]`. Accept either spelling.
    func profile(_ name: String) -> [String: String]? {
        sections[name] ?? sections["profile \(name)"]
    }

    var profileNames: [String] {
        sections.keys.map { $0.hasPrefix("profile ") ? String($0.dropFirst(8)) : $0 }
    }
}
