import XCTest

@testable import ReadRead

/// Input → document (R3-12, R1-15/H9): the steps, the errors, cancellation.
final class DocumentLoaderTests: XCTestCase {
    private func loader(page: WebPage? = nil, fetches: FetchCounter = FetchCounter()) -> DocumentLoader {
        DocumentLoader(
            fetchPage: { url in
                fetches.add(url)
                guard let page else { throw WebExtractorError.fetchFailed(500) }
                return page
            },
            readFile: { try await WebExtractor.readFile($0) })
    }

    func testAPageIsBuiltFromItsMarkdownWithItsTitleFirst() async throws {
        let page = WebPage(title: "Speech synthesis", markdown: "Speech synthesis is artificial speech. It is old.",
                           domain: "en.wikipedia.org")
        let fetches = FetchCounter()
        let document = try await loader(page: page, fetches: fetches)
            .load(.url(URL(string: "https://en.wikipedia.org/wiki/Speech_synthesis")!))
        XCTAssertEqual(fetches.urls.map(\.absoluteString), ["https://en.wikipedia.org/wiki/Speech_synthesis"])
        XCTAssertEqual(document.title, "Speech synthesis")
        XCTAssertEqual(document.sourceLabel, "en.wikipedia.org")
        XCTAssertEqual(document.units.first?.kind, .title)
        XCTAssertEqual(document.units.map(\.speakText), ["Speech synthesis.", "Speech synthesis is artificial speech.", "It is old."])
        XCTAssertEqual(document.detectedLanguage, .en)
    }

    func testAMarkdownFileUsesItsFrontmatterTitleAndAGBKTextFileIsDecoded() async throws {
        let directory = try makeTemporaryDirectory()
        let markdown = directory.appending(path: "article.md")
        try "---\ntitle: \"文章标题\"\n---\n# 文章标题\n\n这是**正文**。[^1]\n\n[^1]: 脚注。".write(to: markdown, atomically: true, encoding: .utf8)
        let document = try await loader().load(.file(markdown))
        XCTAssertEqual(document.title, "文章标题")
        XCTAssertEqual(document.sourceLabel, "article.md")
        XCTAssertEqual(document.units.map(\.speakText), ["文章标题。", "这是正文。"])

        let novel = directory.appending(path: "novel.txt")
        try Fixtures.data("encodings/gbk.txt").write(to: novel)
        let text = try await loader().load(.file(novel))
        XCTAssertEqual(text.title, "novel", "the file name is shown, not read")
        XCTAssertEqual(text.units.first?.speakText, "第一章　风起", "plain text: no title unit, no added stop")
        XCTAssertEqual(text.detectedLanguage, .zh)
        XCTAssertEqual(text.source, .file(novel))
    }

    func testPastedTextIsReadAsMarkdownOnlyWhenItLooksLikeIt() async throws {
        let markdown = try await loader().load(.text("## Heading\r\n\r\nSome **bold** text."))
        XCTAssertEqual(markdown.units.map(\.speakText), ["Heading.", "Some bold text."])
        let prose = try await loader().load(.text("Price: 5 * 3 = 15. #1 seller."))
        XCTAssertEqual(prose.units.map(\.speakText), ["Price: 5 * 3 = 15.", "#1 seller."])
        XCTAssertTrue(DocumentLoader.looksLikeMarkdown("> quoted\n"))
        XCTAssertTrue(DocumentLoader.looksLikeMarkdown("see [x](https://x.org)"))
        XCTAssertFalse(DocumentLoader.looksLikeMarkdown("Just a sentence - with a dash."))
    }

    /// One Markdown signal sends a paste through MarkdownCleaner; its indented paragraphs are
    /// still paragraphs there, not code blocks to skip.
    func testPastedMarkdownKeepsItsIndentedParagraphs() async throws {
        let chinese = try await loader().load(.text("价格是**特价**，原价199元。\n\n\t第二段用制表符缩进。\n\n    第三段用四个空格缩进。"))
        XCTAssertEqual(chinese.units.map(\.speakText), ["价格是特价，原价199元。", "第二段用制表符缩进。", "第三段用四个空格缩进。"])
        let english = try await loader().load(.text("    Indented first paragraph.\n\n    Second indented paragraph.\n\n**Note**: bold here"))
        XCTAssertEqual(english.units.map(\.speakText), ["Indented first paragraph.", "Second indented paragraph.", "Note: bold here"])
        let fenced = try await loader().load(.text("**Code** below.\n\n```\nlet x = 1\n```\n\nAfter."))
        XCTAssertEqual(fenced.units.map(\.speakText), ["Code below.", "After."], "fenced code still goes")
    }

    func testNothingToRead() async {
        for input in [ReadingInput.text("![image](a.png)\n\n---"), .text("これは日本語の文章です。吾輩は猫である。"), .text("……")] {
            do {
                _ = try await loader().load(input)
                XCTFail("expected nothingToRead for \(input)")
            } catch {
                XCTAssertEqual(error as? DocumentError, .nothingToRead, "\(input)")
            }
        }
        // A page with a title but no body has nothing to read either.
        let empty = WebPage(title: "NeverSSL", markdown: "\n\n", domain: "neverssl.com")
        do {
            _ = try await loader(page: empty).load(.url(URL(string: "https://neverssl.com/")!))
            XCTFail("expected nothingToRead")
        } catch {
            XCTAssertEqual(error as? DocumentError, .nothingToRead)
        }
        XCTAssertTrue(DocumentError.nothingToRead.errorDescription?.contains("没有可读的内容") ?? false)
    }

    /// Where a page is read is the fetcher's business (WebPageFetcherTests): a local-network page
    /// goes to it like any other, and its errors come through.
    func testLocalNetworkPagesGoToTheFetcher() async throws {
        let fetches = FetchCounter()
        let page = WebPage(title: "Wiki", markdown: "A page on the local network.", domain: "192.168.1.10")
        let document = try await loader(page: page, fetches: fetches).load(.url(URL(string: "http://192.168.1.10/wiki/Page")!))
        XCTAssertEqual(fetches.urls.map(\.absoluteString), ["http://192.168.1.10/wiki/Page"])
        XCTAssertEqual(document.units.map(\.speakText), ["Wiki.", "A page on the local network."])
        let message = DocumentError.localNetwork("192.168.1.10").errorDescription ?? ""
        XCTAssertTrue(message.hasPrefix("192.168.1.10 is on your local network"), message)
        XCTAssertTrue(message.contains("./scripts/setup.sh"), "the setup hint")
        XCTAssertEqual(DocumentError.pageUnreadable(local: "The page did not load within 15 seconds.", remote: "Invalid URL")
            .errorDescription,
            "ReadRead could not read the page on this Mac (The page did not load within 15 seconds.) nor through defuddle.md (Invalid URL).")
    }

    /// A text/plain page read on this Mac goes through the plain-text cleaner: **x** stays text.
    func testAPlainTextPageIsReadAsPlainText() async throws {
        let page = WebPage(title: nil, markdown: "Notes about 2 * 3 * 4.\n\n# not a heading\n", domain: "example.com", isPlainText: true)
        let document = try await loader(page: page).load(.url(URL(string: "https://example.com/notes.txt")!))
        XCTAssertEqual(document.units.map(\.speakText), ["Notes about 2 * 3 * 4.", "# not a heading"])
    }

    /// A document's blocks (RTF, PDF, EPUB …) are built as they are; its metadata title comes first.
    func testADocumentFileIsBuiltFromItsBlocks() async throws {
        let blocks = [MarkdownCleaner.Block(kind: .heading(1), text: "Chapter One"),
                      MarkdownCleaner.Block(kind: .paragraph, text: "It begins. It goes on.")]
        let file = LocalFile(title: "The Book", titleFromMetadata: true, fileName: "book.epub", body: "ignored", isMarkdown: false,
                             blocks: blocks)
        let loader = DocumentLoader(fetchPage: { _ in throw WebExtractorError.invalidURL }, readFile: { _ in file })
        let document = try await loader.load(.file(URL(fileURLWithPath: "/tmp/book.epub")))
        XCTAssertEqual(document.title, "The Book")
        XCTAssertEqual(document.sourceLabel, "book.epub")
        XCTAssertEqual(document.units.map(\.speakText), ["The Book.", "Chapter One.", "It begins.", "It goes on."])
    }

    func testFetchErrorsPassThrough() async {
        do {
            _ = try await loader(page: nil).load(.url(URL(string: "https://example.com/")!))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? WebExtractorError, .fetchFailed(500))
        }
    }

    func testACancelledLoadThrowsCancellation() async {
        let started = expectation(description: "fetch started")
        let slow = DocumentLoader(
            fetchPage: { _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(30))
                return WebPage(title: nil, markdown: "Never.", domain: "")
            },
            readFile: { _ in throw WebExtractorError.fileReadFailed("unused") })
        let task = Task { try await slow.load(.url(URL(string: "https://example.com/")!)) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testCancellationAfterTheFetchStillStops() async {
        // The fetch ignores cancellation; the loader checks between the steps.
        let gate = Gate()
        let loader = DocumentLoader(
            fetchPage: { _ in
                await gate.wait()
                return WebPage(title: nil, markdown: "A sentence.", domain: "")
            },
            readFile: { _ in throw WebExtractorError.fileReadFailed("unused") })
        let task = Task { try await loader.load(.url(URL(string: "https://example.com/")!)) }
        await gate.waitUntilWaiting()
        task.cancel()
        await gate.open()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}

/// URLs a fake fetch saw.
final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URL] = []

    var urls: [URL] { lock.withLock { seen } }
    func add(_ url: URL) { lock.withLock { seen.append(url) } }
}

/// One waiter, released by `open()`, ignoring cancellation.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilWaiting() async {
        while continuation == nil { await Task.yield() }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
