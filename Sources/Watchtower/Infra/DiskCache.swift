import Foundation

/// Last known good values, so a restart shows real data with an honest age rather than a
/// blank panel — and so the expensive Cost Explorer result survives across launches.
///
/// Keyed by target id: a card that was removed and re-added is a different card, and should
/// not inherit a stale value under a name the user has since reused.
struct CachedState: Codable {
    var cards: [String: Loaded<CardPayload>] = [:]
    var cost: Loaded<CostBreakdown> = Loaded<CostBreakdown>()
}

enum DiskCache {
    static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("Watchtower", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static var fileURL: URL { directory.appendingPathComponent("cache.json") }

    static func load() -> CachedState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? decoder.decode(CachedState.self, from: data) else {
            // A 1.x cache has a different shape. Losing it costs one poll interval of
            // freshness, which is cheaper than migrating a throwaway file.
            return CachedState()
        }
        return state
    }

    static func save(_ state: CachedState) {
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
