import Foundation

/// What this tool last committed to the device's flash.
///
/// The device offers no way to read its saved configuration back — the
/// protocol has a write-and-commit with no corresponding read. This cache is
/// therefore a record of what *this tool* saved, not a reading of the
/// hardware, and it will be stale if anything else writes the device. Present
/// it with wording that stays true when that happens.
struct LastSaved: Equatable, Codable {
    let source: String
    let savedAt: Date
}

enum SaveCache {
    static var defaultURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base
            .appendingPathComponent("scarlett-audio", isDirectory: true)
            .appendingPathComponent("last-saved.json")
    }

    /// A missing or unreadable cache is normal, not an error.
    static func read(from url: URL = defaultURL) -> LastSaved? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LastSaved.self, from: data)
    }

    static func write(_ entry: LastSaved, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: url, options: .atomic)
    }
}
