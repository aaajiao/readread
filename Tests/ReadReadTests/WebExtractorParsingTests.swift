import XCTest

@testable import ReadRead

/// What WebExtractor makes of a defuddle.md response and of local files (the Markdown itself
/// is MarkdownCleaner's, see MarkdownCleanerTests).
final class WebExtractorParsingTests: XCTestCase {
    private func page(_ response: String, url: String = "https://www.example.com/post") async throws -> WebPage {
        let data = Data(response.utf8)
        return try await WebExtractor.extractFromURL(try XCTUnwrap(URL(string: url)), fetch: { _ in data })
    }

    // MARK: - extractFromURL

    func testTheFrontmatterIsSplitOffAndGivesTitleAndDomain() async throws {
        let response = try Fixtures.text("pages/zh_wikipedia.md")
        let page = try await page(response, url: "https://zh.wikipedia.org/wiki/语音合成")
        XCTAssertEqual(page.title, "语音合成", "the Wikipedia suffix goes")
        XCTAssertEqual(page.domain, "zh.wikipedia.org")
        XCTAssertTrue(page.markdown.hasPrefix("\n**語音合成**"), String(page.markdown.prefix(40)))
        XCTAssertFalse(page.markdown.contains("word_count"))
    }

    func testTheRequestGoesToDefuddleWithoutTheScheme() async throws {
        let seen = URLBox()
        _ = try await WebExtractor.extractFromURL(try XCTUnwrap(URL(string: "https://zh.wikipedia.org/wiki/语音合成?x=1"))) { url in
            seen.set(url)
            return Data("---\ntitle: \"x\"\n---\nbody".utf8)
        }
        XCTAssertEqual(seen.value?.absoluteString, "https://defuddle.md/zh.wikipedia.org/wiki/%E8%AF%AD%E9%9F%B3%E5%90%88%E6%88%90?x=1")
        XCTAssertEqual(WebExtractor.defuddleURL(for: try XCTUnwrap(URL(string: "http://example.com/a")))?.absoluteString,
                       "https://defuddle.md/example.com/a")
    }

    func testTheDomainFallsBackToTheURLsHost() async throws {
        let page = try await page("# Just a body\n\nText.", url: "https://www.example.org/x")
        XCTAssertNil(page.title)
        XCTAssertEqual(page.domain, "example.org")
        XCTAssertEqual(page.markdown, "# Just a body\n\nText.")
    }

    func testDefuddleErrorJSONIsTheServicesMessage() async {
        do {
            _ = try await page(#"{"error":"Timed out fetching page after 10s"}"#)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? WebExtractorError, .service("Timed out fetching page after 10s"))
            XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                           "defuddle.md could not extract the page: Timed out fetching page after 10s")
        }
    }

    func testAPageWithOnlyFrontmatterHasAnEmptyBody() async throws {
        // neverssl.com as defuddle.md returned it.
        let response = "---\ntitle: \"NeverSSL - Connecting ...\"\nsite: \"neverssl.com\"\nsource: \"https://neverssl.com/\"\ndomain: \"neverssl.com\"\n---\n\n"
        let page = try await page(response, url: "https://neverssl.com/")
        XCTAssertEqual(page.title, "NeverSSL - Connecting ...")
        XCTAssertEqual(page.markdown.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testTheResponseIsUTF8EvenWithAControlCharacterInIt() async throws {
        // A stray U+000B once made the legacy heuristics read the whole page as GB18030 mojibake.
        let body = "---\ntitle: \"Café culture in Zürich\"\ndomain: \"example.com\"\n---\n\n"
            + "The café served crème brûlée to naïve résumé writers.\u{0B}Señor Müller agreed.\u{07}"
        let page = try await page(body)
        XCTAssertEqual(page.title, "Café culture in Zürich")
        XCTAssertEqual(page.markdown, "\nThe café served crème brûlée to naïve résumé writers.\nSeñor Müller agreed.")
        let document = DocumentBuilder.fromMarkdown(page.markdown, title: page.title, source: .text, sourceLabel: page.domain)
        XCTAssertEqual(document.detectedLanguage, .en)
        // Bytes that are not UTF-8 become U+FFFD; nothing is guessed.
        let broken = try await WebExtractor.extractFromURL(try XCTUnwrap(URL(string: "https://example.cn/")),
                                                           fetch: { _ in Data([0x41, 0xB5, 0xDA, 0x42]) })
        XCTAssertEqual(broken.markdown, "A\u{FFFD}\u{FFFD}B")
    }

    func testCRLFResponsesKeepTheirFrontmatter() async throws {
        let page = try await page("---\r\ntitle: \"A\"\r\ndomain: \"a.com\"\r\n---\r\nBody\r\n")
        XCTAssertEqual(page.title, "A")
        XCTAssertEqual(page.domain, "a.com")
        XCTAssertEqual(page.markdown, "Body\n")
    }

    // MARK: - Titles

    func testSiteSuffixesAreStrippedOnlyWhenTheyNameTheSite() {
        XCTAssertEqual(WebExtractor.stripSiteSuffix("Speech synthesis - Wikipedia", site: "Wikipedia"), "Speech synthesis")
        XCTAssertEqual(WebExtractor.stripSiteSuffix("语音合成 - 维基百科，自由的百科全书", site: "Wikipedia"), "语音合成")
        XCTAssertEqual(WebExtractor.stripSiteSuffix("rsync 用法教程 - 阮一峰的网络日志", site: "ruanyifeng.com"),
                       "rsync 用法教程 - 阮一峰的网络日志", "the suffix does not name the site")
        XCTAssertEqual(WebExtractor.stripSiteSuffix("Release notes | The Swift Blog", site: "The Swift Blog"), "Release notes")
        XCTAssertEqual(WebExtractor.stripSiteSuffix("Pros - and cons", site: ""), "Pros - and cons")
        XCTAssertEqual(WebExtractor.stripSiteSuffix("  Title  ", site: "x"), "Title")
    }

    func testDisplayDomainDropsWWW() {
        XCTAssertEqual(WebExtractor.displayDomain("www.example.com"), "example.com")
        XCTAssertEqual(WebExtractor.displayDomain("WWW.Example.com"), "Example.com")
        XCTAssertEqual(WebExtractor.displayDomain("zh.wikipedia.org"), "zh.wikipedia.org")
    }

    func testServiceErrorOnlyMatchesAnErrorObject() {
        XCTAssertEqual(WebExtractor.serviceError(#"  {"error": {"message": "quota"}}  "#), "quota")
        XCTAssertNil(WebExtractor.serviceError(#"{"title": "not an error"}"#))
        XCTAssertNil(WebExtractor.serviceError("# {error} in a heading"))
    }

    // MARK: - readFile

    func testMarkdownFileTakesItsTitleFromTheFrontmatter() async throws {
        let url = try makeTemporaryDirectory().appending(path: "myarticle.md")
        try "---\ntitle: \"The Real Title\"\n---\n# Hello\n\nThis is the body.".write(to: url, atomically: true, encoding: .utf8)
        let file = try await WebExtractor.readFile(url)
        XCTAssertEqual(file.title, "The Real Title")
        XCTAssertTrue(file.titleFromMetadata)
        XCTAssertEqual(file.fileName, "myarticle.md")
        XCTAssertEqual(file.body, "# Hello\n\nThis is the body.")
        XCTAssertTrue(file.isMarkdown)
    }

    func testWithoutFrontmatterTheTitleIsTheFileName() async throws {
        let url = try makeTemporaryDirectory().appending(path: "doc.markdown")
        try "## Section\n\nContent here.".write(to: url, atomically: true, encoding: .utf8)
        let file = try await WebExtractor.readFile(url)
        XCTAssertEqual(file.title, "doc")
        XCTAssertFalse(file.titleFromMetadata)
        XCTAssertTrue(file.isMarkdown, ".markdown is Markdown too")
        XCTAssertEqual(file.body, "## Section\n\nContent here.")
    }

    func testTextFilesAreNotMarkdown() async throws {
        let url = try makeTemporaryDirectory().appending(path: "notes.txt")
        try "---\ntitle: x\n---\n**not** markup".write(to: url, atomically: true, encoding: .utf8)
        let file = try await WebExtractor.readFile(url)
        XCTAssertFalse(file.isMarkdown)
        XCTAssertEqual(file.title, "notes")
        XCTAssertEqual(file.body, "---\ntitle: x\n---\n**not** markup", "no frontmatter in a .txt file")
    }

    func testFilesInLegacyEncodingsAreDecoded() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appending(path: "novel.txt")
        try Fixtures.data("encodings/gbk.txt").write(to: url)
        let file = try await WebExtractor.readFile(url)
        XCTAssertTrue(file.body.hasPrefix("第一章　风起\n　　天色渐暗"))
        let crlf = directory.appending(path: "crlf.md")
        try Data("---\r\ntitle: CRLF\r\n---\r\nLine one.\r\n".utf8).write(to: crlf)
        let markdown = try await WebExtractor.readFile(crlf)
        XCTAssertEqual(markdown.title, "CRLF")
        XCTAssertEqual(markdown.body, "Line one.\n")
    }

    func testBinaryFilesAreRefused() async throws {
        let url = try makeTemporaryDirectory().appending(path: "image.txt")
        try Data((0..<2_048).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }).write(to: url)
        do {
            _ = try await WebExtractor.readFile(url)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TextDecoding.Failure, .notText)
        }
    }

    func testAMissingFileIsAReadFailure() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "does_not_exist_\(UUID().uuidString).md")
        do {
            _ = try await WebExtractor.readFile(url)
            XCTFail("expected an error")
        } catch {
            guard case .fileReadFailed? = error as? WebExtractorError else { return XCTFail("\(error)") }
        }
    }

    func testErrorDescriptions() {
        XCTAssertEqual(WebExtractorError.invalidURL.errorDescription, "Invalid URL")
        XCTAssertEqual(WebExtractorError.fetchFailed(503).errorDescription, "Failed to fetch content (HTTP 503)")
        XCTAssertEqual(WebExtractorError.fileTooLarge(40_000_000).errorDescription,
                       "The file is too large to read (40 MB; the limit is 32 MB).")
    }
}

/// A URL set from a @Sendable closure.
private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    var value: URL? { lock.withLock { url } }
    func set(_ url: URL) { lock.withLock { self.url = url } }
}
