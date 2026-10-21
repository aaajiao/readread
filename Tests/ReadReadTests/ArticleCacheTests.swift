import XCTest

@testable import ReadRead

/// `<cache>/articles/<sha256>.json`: what is kept, for how long, how much.
final class ArticleCacheTests: XCTestCase {
    private let url = URL(string: "https://en.wikipedia.org/wiki/Speech_synthesis")!
    private let page = WebPage(title: "Speech synthesis", markdown: "# Speech synthesis\n\nBody.", domain: "en.wikipedia.org",
                               author: "Wikipedia contributors", site: "Wikipedia", published: "2003-02-01", isPlainText: false)

    private func cache(now: Shared<Date>? = nil) throws -> ArticleCache {
        var cache = ArticleCache(directory: try makeTemporaryDirectory().appending(path: "articles"))
        if let now { cache.now = { now.value } }
        return cache
    }

    func testAPageIsKeptAsJSONUnderTheHashOfItsURL() throws {
        let cache = try cache()
        XCTAssertNil(cache.entry(for: url))
        cache.store(page, for: url, extractor: ArticleCache.Extractor.local)
        let entry = try XCTUnwrap(cache.entry(for: url))
        XCTAssertEqual(entry.page, page)
        XCTAssertEqual(entry.extractor, "local")
        XCTAssertEqual(entry.version, ArticleCache.formatVersion)
        XCTAssertEqual(entry.url, url.absoluteString)
        // printf '%s' https://en.wikipedia.org/wiki/Speech_synthesis | shasum -a 256
        XCTAssertEqual(ArticleCache.fileName(for: url), "bc34affc243d73378582213eb8f57e75fa8b70b1400e5c886cd59135f23f33ac.json")
        XCTAssertEqual(cache.fileURL(for: url).deletingLastPathComponent().lastPathComponent, "articles")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache.fileURL(for: url))) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "url", "fetchedAt", "extractor", "page"])
        XCTAssertNotNil(ISO8601DateFormatter().date(from: object["fetchedAt"] as? String ?? ""), "an ISO 8601 date")
    }

    func testTheFragmentIsNotPartOfTheKey() {
        XCTAssertEqual(ArticleCache.key(for: URL(string: "https://a.org/x?y=1#section")!), "https://a.org/x?y=1")
        XCTAssertEqual(ArticleCache.fileName(for: URL(string: "https://a.org/x#one")!),
                       ArticleCache.fileName(for: URL(string: "https://a.org/x#two")!))
        XCTAssertNotEqual(ArticleCache.fileName(for: URL(string: "https://a.org/x?y=1")!),
                          ArticleCache.fileName(for: URL(string: "https://a.org/x?y=2")!))
    }

    func testEntriesExpireAfterThirtyDays() throws {
        let now = Shared(Date(timeIntervalSince1970: 2_000_000_000))
        let cache = try cache(now: now)
        cache.store(page, for: url, extractor: ArticleCache.Extractor.remote)
        now.value += 29 * 24 * 3600
        XCTAssertNotNil(cache.entry(for: url))
        now.value += 2 * 24 * 3600
        XCTAssertNil(cache.entry(for: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL(for: url).path(percentEncoded: false)), "removed")
    }

    func testAnUnreadableEntryIsRemoved() throws {
        let cache = try cache()
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let file = cache.fileURL(for: url)
        for content in ["not json", #"{"version":99,"url":"x"}"#] {
            try Data(content.utf8).write(to: file)
            XCTAssertNil(cache.entry(for: url), content)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)), content)
        }
        // An entry for another URL under this name (a collision) is not this page.
        cache.store(page, for: URL(string: "https://other.example/")!, extractor: "local")
        try FileManager.default.moveItem(at: cache.fileURL(for: URL(string: "https://other.example/")!), to: file)
        XCTAssertNil(cache.entry(for: url))
    }

    /// Over the bound, the oldest entries go first.
    func testTheCacheStaysUnderItsBound() throws {
        var cache = try cache()
        cache.maximumBytes = 4_000
        let body = String(repeating: "Lorem ipsum dolor sit amet. ", count: 20)  // about 560 bytes per entry
        var urls: [URL] = []
        for index in 0..<10 {
            let url = URL(string: "https://example.com/\(index)")!
            urls.append(url)
            cache.store(WebPage(title: "\(index)", markdown: body, domain: "example.com"), for: url, extractor: "local")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 100) * 60)],
                                                  ofItemAtPath: cache.fileURL(for: url).path(percentEncoded: false))
        }
        cache.trim()
        let kept = urls.filter { cache.entry(for: $0) != nil }
        XCTAssertFalse(kept.isEmpty)
        XCTAssertLessThan(kept.count, 10)
        XCTAssertEqual(kept, Array(urls.suffix(kept.count)), "the newest stay")
        let total = try FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        XCTAssertLessThanOrEqual(total, 4_000)
        // A page too large for the bound is not kept at all.
        cache.store(WebPage(title: "Huge", markdown: String(repeating: "x", count: 5_000), domain: "e.com"),
                    for: URL(string: "https://e.com/huge")!, extractor: "local")
        XCTAssertNil(cache.entry(for: URL(string: "https://e.com/huge")!))
    }

    func testRemoveAllClearsTheCache() throws {
        let cache = try cache()
        try cache.removeAll()  // nothing there yet
        cache.store(page, for: url, extractor: "local")
        try cache.removeAll()
        XCTAssertNil(cache.entry(for: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.directory.path(percentEncoded: false)))
    }

    /// Clear Cached Articles while pages are being stored: it never fails (it did with "you don't
    /// have permission" when a store recreated the directory under the removal), and nothing is
    /// left beside the directory.
    func testClearingWhileStoringNeverFails() async throws {
        let root = try makeTemporaryDirectory()
        let cache = ArticleCache(directory: root.appending(path: "articles"))
        let page = WebPage(title: "Busy", markdown: String(repeating: "A sentence of the page. ", count: 100), domain: "example.com")
        let stop = Shared(false)
        let writer = Task.detached {
            var index = 0
            while !stop.value {
                cache.store(page, for: URL(string: "https://example.com/\(index)")!, extractor: ArticleCache.Extractor.local)
                index += 1
            }
            return index
        }
        for _ in 0..<40 {
            XCTAssertNoThrow(try cache.removeAll())
            try await Task.sleep(for: .milliseconds(2))
        }
        stop.value = true
        let stored = await writer.value
        XCTAssertGreaterThan(stored, 0)
        try cache.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.directory.path(percentEncoded: false)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)), [],
                       "no renamed directory left")
    }

    func testTheLiveCacheIsUnderTheCacheDirectory() {
        XCTAssertEqual(ArticleCache.live(environment: ["READREAD_CACHE_DIR": "/scratch/cache"], homeDirectory: "/Users/x").directory.path,
                       "/scratch/cache/articles")
        XCTAssertEqual(ArticleCache.live(environment: [:], homeDirectory: "/Users/x").directory.path,
                       "/Users/x/Library/Caches/ReadRead/articles")
        XCTAssertEqual(ArticleCache.defaultTimeToLive, 30 * 24 * 3600)
    }
}
