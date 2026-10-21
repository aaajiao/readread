import XCTest

@testable import ReadRead

/// Where a page is read (ExtractionMode, R3-06 local network, R3-13 local first) and the cache.
final class WebPageFetcherTests: XCTestCase {
    private let article = URL(string: "https://example.com/post")!
    private let intranet = URL(string: "http://192.168.1.10/wiki/Page")!

    /// A fetcher with scripted readers; `mode` may change between fetches.
    private func fetcher(
        mode: ExtractionMode = .localFirst, local: @escaping @Sendable (URL) async throws -> WebPage,
        remote: @escaping @Sendable (URL) async throws -> WebPage, cache: ArticleCache? = nil,
        localCalls: FetchCounter, remoteCalls: FetchCounter, modeBox: Shared<ExtractionMode>? = nil
    ) -> WebPageFetcher {
        let box = modeBox
        return WebPageFetcher(
            mode: { box?.value ?? mode },
            local: { url in
                localCalls.add(url)
                return try await local(url)
            },
            remote: { url in
                remoteCalls.add(url)
                return try await remote(url)
            },
            cache: cache)
    }

    private func cache() throws -> ArticleCache { ArticleCache(directory: try makeTemporaryDirectory().appending(path: "articles")) }

    func testLocalFirstReadsHereAndKeepsThePage() async throws {
        let local = FetchCounter(), remote = FetchCounter()
        let cache = try cache()
        let fetcher = fetcher(local: { _ in samplePage("Here") }, remote: { _ in samplePage("There") }, cache: cache,
                              localCalls: local, remoteCalls: remote)
        let first = try await fetcher.fetch(article)
        XCTAssertEqual(first.title, "Here")
        XCTAssertEqual(cache.entry(for: article)?.extractor, ArticleCache.Extractor.local)
        let again = try await fetcher.fetch(URL(string: "https://example.com/post#comments")!)
        XCTAssertEqual(again, first, "the same page, from the cache")
        XCTAssertEqual(local.urls.count, 1)
        XCTAssertEqual(remote.urls.count, 0)
    }

    func testDefuddleMdReadsWhatThisMacCannot() async throws {
        let local = FetchCounter(), remote = FetchCounter()
        let cache = try cache()
        let fetcher = fetcher(local: { _ in throw LocalExtractorError.timedOut }, remote: { _ in samplePage("There") },
                              cache: cache, localCalls: local, remoteCalls: remote)
        let page = try await fetcher.fetch(article)
        XCTAssertEqual(page.title, "There")
        XCTAssertEqual(local.urls, [article])
        XCTAssertEqual(remote.urls, [article])
        XCTAssertEqual(cache.entry(for: article)?.extractor, ArticleCache.Extractor.remote)
    }

    func testWhenBothFailTheErrorNamesBoth() async {
        let local = FetchCounter(), remote = FetchCounter()
        let fetcher = fetcher(local: { _ in throw LocalExtractorError.httpStatus(403) },
                              remote: { _ in throw WebExtractorError.quotaExceeded(nil) }, localCalls: local, remoteCalls: remote)
        do {
            _ = try await fetcher.fetch(article)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DocumentError, .pageUnreadable(
                local: LocalExtractorError.httpStatus(403).localizedDescription,
                remote: WebExtractorError.quotaExceeded(nil).localizedDescription))
        }
    }

    /// Without Defuddle installed, local-first is defuddle.md, and its error is its own.
    func testWithoutDefuddleThePageGoesStraightToDefuddleMd() async {
        let local = FetchCounter(), remote = FetchCounter()
        let fetcher = fetcher(local: { _ in throw LocalExtractorError.bundleMissing },
                              remote: { _ in throw WebExtractorError.service("Timed out fetching page after 10s") },
                              localCalls: local, remoteCalls: remote)
        do {
            _ = try await fetcher.fetch(article)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? WebExtractorError, .service("Timed out fetching page after 10s"))
        }
        XCTAssertEqual(remote.urls, [article])
    }

    /// defuddle.md only: the local reader is never asked, and a page it read before is read again.
    func testRemoteOnlyNeverReadsHere() async throws {
        let local = FetchCounter(), remote = FetchCounter()
        let cache = try cache()
        cache.store(samplePage("Cached here"), for: article, extractor: ArticleCache.Extractor.local)
        let fetcher = fetcher(mode: .remoteOnly, local: { _ in samplePage("Here") }, remote: { _ in samplePage("There") },
                              cache: cache, localCalls: local, remoteCalls: remote)
        let page = try await fetcher.fetch(article)
        XCTAssertEqual(page.title, "There")
        XCTAssertEqual(local.urls, [])
        let again = try await fetcher.fetch(article)
        XCTAssertEqual(again.title, "There")
        XCTAssertEqual(remote.urls, [article], "the second time from the cache")
    }

    /// R3-06: a page on the local network never goes to defuddle.md, whatever the mode.
    func testLocalNetworkPagesAreOnlyReadHere() async throws {
        for mode in ExtractionMode.allCases {
            let local = FetchCounter(), remote = FetchCounter()
            let reads = fetcher(mode: mode, local: { _ in samplePage("Wiki") }, remote: { _ in samplePage("Leaked") },
                                localCalls: local, remoteCalls: remote)
            let page = try await reads.fetch(intranet)
            XCTAssertEqual(page.title, "Wiki", "\(mode)")
            XCTAssertEqual(remote.urls, [], "\(mode)")

            let fails = fetcher(mode: mode, local: { _ in throw LocalExtractorError.timedOut }, remote: { _ in samplePage("Leaked") },
                                localCalls: local, remoteCalls: remote)
            await XCTAssertThrowsErrorAsync(try await fails.fetch(intranet)) {
                XCTAssertEqual($0 as? LocalExtractorError, .timedOut, "its own error, no fallback")
            }
            let missing = fetcher(mode: mode, local: { _ in throw LocalExtractorError.bundleMissing },
                                  remote: { _ in samplePage("Leaked") }, localCalls: local, remoteCalls: remote)
            await XCTAssertThrowsErrorAsync(try await missing.fetch(intranet)) {
                XCTAssertEqual($0 as? DocumentError, .localNetwork("192.168.1.10"))
            }
            XCTAssertEqual(remote.urls, [], "\(mode)")
        }
    }

    func testCancellationIsNoReasonToAskDefuddleMd() async {
        let local = FetchCounter(), remote = FetchCounter()
        let fetcher = fetcher(local: { _ in throw CancellationError() }, remote: { _ in samplePage("There") },
                              localCalls: local, remoteCalls: remote)
        await XCTAssertThrowsErrorAsync(try await fetcher.fetch(article)) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(remote.urls, [])
    }

    func testTheModeIsReadAtEachFetch() async throws {
        let local = FetchCounter(), remote = FetchCounter()
        let mode = Shared(ExtractionMode.remoteOnly)
        let fetcher = fetcher(local: { _ in samplePage("Here") }, remote: { _ in samplePage("There") },
                              localCalls: local, remoteCalls: remote, modeBox: mode)
        let first = try await fetcher.fetch(article)
        XCTAssertEqual(first.title, "There")
        mode.value = .localFirst
        let second = try await fetcher.fetch(article)
        XCTAssertEqual(second.title, "Here")
    }

    /// A page whose HTML was still arriving at the hard limit: defuddle.md reads it whole; when it
    /// cannot, the part read here is read, and nothing is kept (F13).
    func testAPageReadOnlyInPartIsReadAgainNextTime() async throws {
        let local = FetchCounter(), remote = FetchCounter()
        let cache = try cache()
        let partial = shortPage("First half", sentences: 3)
        let whole = fetcher(local: { _ in throw LocalExtractorError.incomplete(partial) }, remote: { _ in samplePage("Whole") },
                            cache: cache, localCalls: local, remoteCalls: remote)
        let page = try await whole.fetch(article)
        XCTAssertEqual(page.title, "Whole")
        XCTAssertEqual(cache.entry(for: article)?.extractor, ArticleCache.Extractor.remote)

        let other = URL(string: "https://example.com/other")!
        let failing = fetcher(local: { _ in throw LocalExtractorError.incomplete(partial) },
                              remote: { _ in throw WebExtractorError.quotaExceeded(nil) }, cache: cache,
                              localCalls: local, remoteCalls: remote)
        let read = try await failing.fetch(other)
        XCTAssertEqual(read, partial, "better a part than nothing")
        XCTAssertNil(cache.entry(for: other), "a part is not kept")
        _ = try await failing.fetch(other)
        XCTAssertEqual(local.urls, [article, other, other], "read again")

        let localOnly = fetcher(local: { _ in throw LocalExtractorError.incomplete(partial) }, remote: { _ in samplePage("Leaked") },
                                cache: cache, localCalls: local, remoteCalls: remote)
        let wiki = try await localOnly.fetch(intranet)
        XCTAssertEqual(wiki, partial)
        XCTAssertNil(cache.entry(for: intranet))
        XCTAssertFalse(remote.urls.contains(intranet))
    }

    /// Very little to read ("Loading…", a page that renders later): defuddle.md is asked as
    /// well, the longer page is read, and a short one is not kept (F12).
    func testAShortPageIsCheckedWithDefuddleMd() async throws {
        let local = FetchCounter(), remote = FetchCounter()
        let cache = try cache()
        let placeholder = shortPage("Loading")
        let fetcher = fetcher(local: { _ in placeholder }, remote: { _ in samplePage("Article") }, cache: cache,
                              localCalls: local, remoteCalls: remote)
        let page = try await fetcher.fetch(article)
        XCTAssertEqual(page.title, "Article")
        XCTAssertEqual(cache.entry(for: article)?.extractor, ArticleCache.Extractor.remote)

        let other = URL(string: "https://example.com/brief")!
        let brief = shortPage("Brief", sentences: 4)
        let shorter = self.fetcher(local: { _ in brief }, remote: { _ in shortPage("Brief") }, cache: cache,
                                   localCalls: local, remoteCalls: remote)
        let read = try await shorter.fetch(other)
        XCTAssertEqual(read, brief, "the longer of the two")
        XCTAssertNil(cache.entry(for: other))

        XCTAssertTrue(WebPageFetcher.isShort(placeholder))
        XCTAssertTrue(WebPageFetcher.isShort(WebPage(title: "x", markdown: "[Loading](https://example.com/a-long-address) ![](x.png)",
                                                    domain: "example.com")), "links and images are not text to read")
        XCTAssertFalse(WebPageFetcher.isShort(samplePage("Article")))
        XCTAssertFalse(WebPageFetcher.isShort(WebPage(title: nil, markdown: String(repeating: "语音合成是一种技术。", count: 21),
                                                     domain: "example.com")))
    }

    /// Read from a dictionary: a named UserDefaults suite would leave its plist in ~/Library/Preferences.
    func testTheModeIsAStoredSetting() {
        var stored: [String: String] = [:]
        XCTAssertEqual(ExtractionMode.current { stored[$0] }, .localFirst, "local first by default")
        stored[ExtractionMode.defaultsKey] = "remote"
        XCTAssertEqual(ExtractionMode.current { stored[$0] }, .remoteOnly)
        stored[ExtractionMode.defaultsKey] = "bogus"
        XCTAssertEqual(ExtractionMode.current { stored[$0] }, .localFirst)
    }
}

/// A page with this title and an article long enough to keep (the readers are @Sendable
/// closures: no `self`).
private func samplePage(_ text: String) -> WebPage {
    WebPage(title: text, markdown: "\(text) body. " + String(repeating: "Another sentence of the article, long enough to read. ", count: 5),
            domain: "example.com")
}

/// The same page with only `sentences` sentences.
private func shortPage(_ text: String, sentences: Int = 1) -> WebPage {
    WebPage(title: text, markdown: String(repeating: "\(text) says little. ", count: sentences), domain: "example.com")
}
