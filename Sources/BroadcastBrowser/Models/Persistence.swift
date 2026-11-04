import Foundation

/// File locations used by the app.
enum AppPaths {
    static let appName = "Broadcast Browser"

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent(appName, isDirectory: true))
    }

    static var preferencesURL: URL { supportDirectory.appendingPathComponent("preferences.json") }
    static var bookmarksURL: URL { supportDirectory.appendingPathComponent("bookmarks.json") }
    static var recentsURL: URL { supportDirectory.appendingPathComponent("recent-sessions.json") }
    static var autosaveURL: URL { supportDirectory.appendingPathComponent("autosave-session.json") }
    static var fontsDirectory: URL { ensure(supportDirectory.appendingPathComponent("Fonts", isDirectory: true)) }

    static var defaultSessionsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ensure(docs.appendingPathComponent("\(appName) Sessions", isDirectory: true))
    }

    static var defaultRecordingsDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return movies.appendingPathComponent(appName, isDirectory: true)
    }
}

/// JSON helpers shared by every saved file (sessions, preferences, bookmarks).
enum JSONFile {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value, falling back to a default when the key is missing or
    /// malformed. Keeps older/newer save files loadable.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

extension NSLock {
    @discardableResult
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
