import CryptoKit
import Foundation

/// Pages read before: `<cache>/articles/<sha256 of the URL without its fragment>.json`, so opening
/// one again costs neither a web view nor a defuddle.md page (1,000 a month). An entry lasts
/// `timeToLive` (30 days); the directory stays under `maximumBytes`, oldest entries going first;
/// an entry that cannot be read (corrupt, another version, another URL) is removed.
/// Settings' "Clear Cached Articles" calls `removeAll()`.
struct ArticleCache: Sendable {
    static let formatVersion = 1
    static let defaultTimeToLive: TimeInterval = 30 * 24 * 60 * 60
    static let defaultMaximumBytes = 50_000_000

    /// Who read the page (`Entry.extractor`).
    enum Extractor {
        static let local = "local"
        static let remote = "defuddle.md"
    }

    /// One file's content.
    struct Entry: Codable, Equatable, Sendable {
        let version: Int
        let url: String
        let fetchedAt: Date
        let extractor: String
        let page: WebPage
    }

    let directory: URL
    var timeToLive: TimeInterval = ArticleCache.defaultTimeToLive
    var maximumBytes: Int = ArticleCache.defaultMaximumBytes
    var now: @Sendable () -> Date = { Date() }

    /// `$READREAD_CACHE_DIR/articles` (default ~/Library/Caches/ReadRead/articles).
    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: String = NSHomeDirectory()
    ) -> ArticleCache {
        let cache = RuntimeDirectories(environment: environment, homeDirectory: homeDirectory).cacheDirectory
        return ArticleCache(directory: URL(fileURLWithPath: cache, isDirectory: true).appending(path: "articles"))
    }

    /// The URL an entry is kept under: without its fragment (#section is the same page).
    static func key(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    static func fileName(for url: URL) -> String {
        SHA256.hash(data: Data(key(for: url).utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    func fileURL(for url: URL) -> URL { directory.appending(path: Self.fileName(for: url)) }

    /// The entry for `url` when there is a fresh, readable one; an expired or unreadable one is removed.
    func entry(for url: URL) -> Entry? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let entry = try? Self.decoder.decode(Entry.self, from: data),
              entry.version == Self.formatVersion, entry.url == Self.key(for: url),
              now().timeIntervalSince(entry.fetchedAt) < timeToLive
        else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return entry
    }

    /// Keep `page` (atomically: a reader never sees half a file), then trim the directory.
    /// A failure to write only costs the next open its fetch.
    func store(_ page: WebPage, for url: URL, extractor: String) {
        let entry = Entry(version: Self.formatVersion, url: Self.key(for: url), fetchedAt: now(), extractor: extractor,
                          page: page)
        guard let data = try? Self.encoder.encode(entry), data.count <= maximumBytes / 4 else { return }
        let file = fileURL(for: url)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            return
        }
        // trim() goes by the files' dates: the file is as old as its entry.
        try? FileManager.default.setAttributes([.modificationDate: entry.fetchedAt], ofItemAtPath: file.path(percentEncoded: false))
        trim()
    }

    /// Remove expired entries, then the oldest ones until the directory holds at most `maximumBytes`.
    func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        var entries: [(url: URL, date: Date, size: Int)] = []
        let current = now()
        for file in files where file.pathExtension == "json" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let date = values.contentModificationDate ?? .distantPast
            if current.timeIntervalSince(date) >= timeToLive {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            entries.append((file, date, values.fileSize ?? 0))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > maximumBytes {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Every entry (Settings: Clear Cached Articles). The directory is renamed away first, one
    /// atomic step (a page stored meanwhile goes into a new directory, it does not make the removal
    /// fail), then deleted; what an earlier removal could not delete goes too. A missing directory
    /// is already clear.
    func removeAll() throws {
        let manager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        let prefix = directory.lastPathComponent + ".removing-"
        if manager.fileExists(atPath: directory.path(percentEncoded: false)) {
            try manager.moveItem(at: directory, to: parent.appending(path: prefix + UUID().uuidString))
        }
        let leftovers = (try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        for item in leftovers where item.lastPathComponent.hasPrefix(prefix) {
            if (try? manager.removeItem(at: item)) == nil { try? manager.removeItem(at: item) }
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
