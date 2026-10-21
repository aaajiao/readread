import XCTest

@testable import ReadRead

/// The offscreen web view with the real Defuddle (R3-06, R3-13). Gated: READREAD_TEST_WEBKIT=1
/// and a Defuddle build (see `WebKitTestGate`); every page comes from a file or a server on
/// 127.0.0.1, never the network.
@MainActor
final class LocalExtractorTests: XCTestCase {
    private var options = LocalExtractor.Options()

    override func setUp() async throws {
        try await super.setUp()
        _ = try WebKitTestGate.defuddleScript()
        options = LocalExtractor.Options(rulesDirectory: try makeTemporaryDirectory().appending(path: "rules"))
    }

    func testAnHTMLFileIsReadWithDefuddleAndItsScriptsDoNotRun() async throws {
        let script = try WebKitTestGate.defuddleScript()
        let started = ContinuousClock.now
        let page = try await LocalExtractor.read(fileURL: Fixtures.url("html/article.html"), script: script, options: options)
        let elapsed = ContinuousClock.now - started
        XCTAssertEqual(page.title, "The Talking Machine")
        XCTAssertEqual(page.author, "Ada Example")
        XCTAssertEqual(page.site, "Fixture Weekly")
        XCTAssertTrue(page.published?.hasPrefix("2026-10-01") ?? false, "\(page.published ?? "nil")")
        XCTAssertTrue(page.markdown.contains("## Early machines"), page.markdown)
        XCTAssertTrue(page.markdown.contains("Speech synthesis is the artificial production of human speech."))
        XCTAssertTrue(page.markdown.contains("- The Voder"), page.markdown)
        XCTAssertFalse(page.markdown.contains("SCRIPT RAN"), "a local file's scripts must not run")
        XCTAssertFalse(page.markdown.contains("Archive"), "navigation is not content")
        XCTAssertFalse(page.markdown.contains("All rights reserved"), "the footer is not content")
        XCTAssertFalse(page.isPlainText)
        XCTAssertLessThan(elapsed, .seconds(10))

        let document = DocumentBuilder.fromMarkdown(page.markdown, title: page.title, source: .file(Fixtures.url("html/article.html")),
                                                    sourceLabel: "article.html")
        XCTAssertEqual(document.units.first?.speakText, "The Talking Machine.")
        XCTAssertFalse(document.units.contains { $0.speakText.contains("[1]") || $0.speakText.contains("note at the end") })
    }

    func testAChineseFileKeepsItsTitleWithoutTheSiteName() async throws {
        let script = try WebKitTestGate.defuddleScript()
        let page = try await LocalExtractor.read(fileURL: Fixtures.url("html/zh_article.html"), script: script, options: options)
        XCTAssertEqual(page.title, "语音合成简史")
        XCTAssertTrue(page.markdown.contains("语音合成是通过机械的、电子的方法产生人造语音的技术。"), page.markdown)
        XCTAssertFalse(page.markdown.contains("联系我们"))
    }

    /// A saved page that refers to a server loads nothing from it: no style sheet, script,
    /// image, frame or background.
    func testALocalFileLoadsNothingFromTheNetwork() async throws {
        let script = try WebKitTestGate.defuddleScript()
        let server = try TestHTTPServer(routes: [
            "/style.css": .init(headers: ["Content-Type": "text/css"], body: Data("p{color:red}".utf8)),
            "/script.js": .init(headers: ["Content-Type": "text/javascript"], body: Data("document.title='x'".utf8)),
            "/frame.html": .html("<p>frame</p>"),
        ])
        defer { server.stop() }
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "tracking.html")
        try Fixtures.text("html/tracking.html").replacingOccurrences(of: "PORT", with: "\(server.port)")
            .write(to: file, atomically: true, encoding: .utf8)
        let page = try await LocalExtractor.read(fileURL: file, script: script, options: options)
        XCTAssertTrue(page.markdown.contains("none of them may be fetched"), page.markdown)
        XCTAssertTrue(page.markdown.contains("it still has to be read"), page.markdown)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.paths, [], "nothing may be requested from the network")
    }

    /// A page that builds its content with a script after a fetch is read once the network is quiet.
    func testAPageIsReadAfterItsScriptsHaveFetchedTheContent() async throws {
        let script = try WebKitTestGate.defuddleScript()
        let server = try TestHTTPServer(routes: [
            "/article": .html("""
                <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Late Article</title></head>
                <body><main id="main"><p>Loading…</p></main><script>
                setTimeout(() => fetch('/api/body').then(r => r.text()).then(t => {
                  document.getElementById('main').innerHTML = '<article><h1>Late Article</h1>' + t + '</article>';
                }), 200);
                </script></body></html>
                """),
            "/api/body": .init(headers: ["Content-Type": "text/html"],
                               body: Data(("<p>This paragraph arrives with a fetch, after the load event, and still has to be read in full. "
                                   + "It is long enough for Defuddle to keep it as the article's content.</p>"
                                   + "<p>A second paragraph makes sure the article is more than a single sentence.</p>").utf8),
                               delay: .milliseconds(300)),
        ])
        defer { server.stop() }
        let page = try await LocalExtractor.read(server.url("/article"), script: script, options: options)
        XCTAssertTrue(page.markdown.contains("This paragraph arrives with a fetch"), page.markdown)
        XCTAssertEqual(page.domain, "127.0.0.1")
        XCTAssertEqual(server.paths, ["/article", "/api/body"])
    }

    /// `allowedHosts` (the live test): a load from any other host is blocked. "localhost" is
    /// another host for the rules, though the same server.
    func testOnlyTheAllowedHostsAreLoadedFrom() async throws {
        let script = try WebKitTestGate.defuddleScript()
        let server = try TestHTTPServer()
        defer { server.stop() }
        server.set("/article", .html("""
            <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Allowed Hosts</title>
            <link rel="stylesheet" href="/same.css"><script src="http://localhost:\(server.port)/other.js"></script></head>
            <body><article><h1>Allowed Hosts</h1><p>The style sheet comes from the page's own host and loads; the script
            is on another host and is blocked. This paragraph is read either way, as the article's content.</p>
            <p>A second paragraph keeps the article longer than a single sentence.</p></article></body></html>
            """))
        server.set("/same.css", .init(headers: ["Content-Type": "text/css"], body: Data("p{color:black}".utf8)))
        server.set("/other.js", .init(headers: ["Content-Type": "text/javascript"], body: Data("var other = 1;".utf8)))

        _ = try await LocalExtractor.read(server.url("/article"), script: script, options: options)
        XCTAssertEqual(server.paths.sorted(), ["/article", "/other.js", "/same.css"], "without the list everything loads")
        var restricted = options
        restricted.allowedHosts = ["127.0.0.1"]
        let page = try await LocalExtractor.read(server.url("/article"), script: script, options: restricted)
        XCTAssertEqual(page.title, "Allowed Hosts")
        XCTAssertTrue(page.markdown.contains("This paragraph is read either way"), page.markdown)
        XCTAssertEqual(server.paths.dropFirst(3).sorted(), ["/article", "/same.css"])
    }

    func testErrorsOfThePageItself() async throws {
        let script = try WebKitTestGate.defuddleScript()
        var routes: [String: TestHTTPServer.Response] = [
            "/gone": .init(status: 410, body: Data("<p>gone</p>".utf8)),
            "/paper.pdf": .init(headers: ["Content-Type": "application/pdf"], body: Data("%PDF-1.4\n%%EOF\n".utf8)),
            "/notes.txt": .init(headers: ["Content-Type": "text/plain; charset=utf-8"],
                                body: Data("Plain notes.\n\nSecond paragraph of the notes.\n".utf8)),
        ]
        for hop in 0..<12 { routes["/loop\(hop)"] = .redirect(to: "/loop\(hop + 1)") }
        let server = try TestHTTPServer(routes: routes)
        defer { server.stop() }

        await XCTAssertThrowsErrorAsync(try await LocalExtractor.read(server.url("/gone"), script: script, options: options)) {
            XCTAssertEqual($0 as? LocalExtractorError, .httpStatus(410))
        }
        await XCTAssertThrowsErrorAsync(try await LocalExtractor.read(server.url("/paper.pdf"), script: script, options: options)) {
            XCTAssertEqual($0 as? LocalExtractorError, .notAPage("application/pdf"))
        }
        await XCTAssertThrowsErrorAsync(try await LocalExtractor.read(server.url("/loop0"), script: script, options: options)) {
            XCTAssertEqual($0 as? LocalExtractorError, .tooManyRedirects)
        }
        let notes = try await LocalExtractor.read(server.url("/notes.txt"), script: script, options: options)
        XCTAssertTrue(notes.isPlainText)
        XCTAssertEqual(notes.markdown, "Plain notes.\n\nSecond paragraph of the notes.\n")
        await XCTAssertThrowsErrorAsync(try await LocalExtractor.read(URL(string: "ftp://127.0.0.1/x")!, script: script,
                                                                      options: options)) {
            XCTAssertEqual($0 as? LocalExtractorError, .unsupportedAddress("ftp://127.0.0.1/x"))
        }
    }

    /// A server that never answers: the hard limit ends the wait.
    func testNothingLoadsWithinTheHardLimit() async throws {
        let script = try WebKitTestGate.defuddleScript()
        let server = try TestHTTPServer(routes: ["/hang": .init(hangs: true)])
        defer { server.stop() }
        var short = options
        short.hardLimit = .seconds(2)
        let started = ContinuousClock.now
        await XCTAssertThrowsErrorAsync(try await LocalExtractor.read(server.url("/hang"), script: script, options: short)) {
            XCTAssertEqual($0 as? LocalExtractorError, .timedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(6))
    }

    /// A style sheet that never arrives holds the load event back; the document is read anyway.
    func testAStalledLoadIsReadOnceTheDocumentIsQuiet() async throws {
        let script = try WebKitTestGate.defuddleScript()
        let server = try TestHTTPServer(routes: [
            "/slow": .html("""
                <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Slow Styles</title>
                <link rel="stylesheet" href="/never.css"></head><body><article><h1>Slow Styles</h1>
                <p>The style sheet of this page never arrives, so its load event never fires. The text is all there, though.</p>
                <p>A second paragraph, so that there is an article to find.</p></article></body></html>
                """),
            "/never.css": .init(hangs: true),
        ])
        defer { server.stop() }
        var short = options
        short.stalledLoadLimit = .seconds(1)
        short.hardLimit = .seconds(8)
        let started = ContinuousClock.now
        let page = try await LocalExtractor.read(server.url("/slow"), script: script, options: short)
        XCTAssertTrue(page.markdown.contains("its load event never fires"), page.markdown)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(6))
    }

    func testCancellingStopsTheRead() async throws {
        let script = try WebKitTestGate.defuddleScript()
        let server = try TestHTTPServer(routes: ["/hang": .init(hangs: true)])
        defer { server.stop() }
        let options = self.options
        let task = Task { try await LocalExtractor.read(server.url("/hang"), script: script, options: options) }
        try await Task.sleep(for: .milliseconds(400))
        let started = ContinuousClock.now
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
    }

    /// HTML still arriving at the hard limit (a server that keeps the connection open): what came
    /// is read, but as `.incomplete`, which is not kept and lets defuddle.md read the page (F13).
    func testAPageStillArrivingAtTheHardLimitIsIncomplete() async throws {
        let script = try WebKitTestGate.defuddleScript()
        let first = """
            <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Half a Page</title></head><body><article>
            <h1>Half a Page</h1><p>The first paragraph of a long article arrives at once. The server then keeps the connection
            open and sends nothing more, as a slow or stuck server would.</p><p>A second paragraph arrives with it, and then
            the first half ends here.</p>
            """ + String(repeating: "<!-- more of the page follows, some day -->\n", count: 40)
        let body = Data((first + "<p>SECOND HALF, which never arrives.</p></article></body></html>").utf8)
        let server = try TestHTTPServer(routes: ["/half": .init(body: body, sendsOnly: Data(first.utf8).count)])
        defer { server.stop() }
        var short = options
        short.hardLimit = .seconds(4)
        let started = ContinuousClock.now
        do {
            let page = try await LocalExtractor.read(server.url("/half"), script: script, options: short)
            XCTFail("expected .incomplete, read \(page.markdown)")
        } catch LocalExtractorError.incomplete(let page) {
            XCTAssertTrue(page.markdown.contains("The first paragraph of a long article arrives at once."), page.markdown)
            XCTAssertFalse(page.markdown.contains("SECOND HALF"))
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(4 + 10 + 1))
    }

    /// A page whose script never returns: the read ends within its limits, and so does the page's
    /// content process, which nothing else would stop before ReadRead quits (F9).
    func testAPageThatNeverStopsDoesNotOutliveTheRead() async throws {
        let script = try WebKitTestGate.defuddleScript()
        let server = try TestHTTPServer(routes: ["/busy": .html("""
            <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Busy</title></head><body><article>
            <h1>Busy</h1><p>This page starts a loop that never ends a moment after it has loaded.</p></article>
            <script>setTimeout(() => { for (;;) {} }, 300);</script></body></html>
            """)])
        defer { server.stop() }
        var short = options
        short.scriptLimit = .seconds(3)
        short.hardLimit = .seconds(6)
        let before = WebContentProcesses.list()
        let started = ContinuousClock.now
        let result = await Task { try await LocalExtractor.read(server.url("/busy"), script: script, options: short) }.result
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(6 + 3 + 1), "\(result)")
        try await Task.sleep(for: .seconds(1))
        let busy = try await WebContentProcesses.busy(among: WebContentProcesses.list().subtracting(before), over: .seconds(2))
        XCTAssertEqual(busy, [], "a content process still spins after the read (\(result))")
    }

    /// A page that renders in an animation frame, and one that waits to be visible: a browser tab
    /// shows both, and so does the web view in no window (F12).
    func testPagesThatRenderInAFrameOrOnceVisibleAreRead() async throws {
        let script = try WebKitTestGate.defuddleScript()
        func page(_ title: String, _ render: String) -> TestHTTPServer.Response {
            .html("""
                <!doctype html><html lang="en"><head><meta charset="utf-8"><title>\(title)</title></head><body>
                <main id="main"><p>Loading</p></main><script>
                function show() {
                  document.getElementById('main').innerHTML = '<article><h1>\(title)</h1><p>This article is rendered by a script, '
                    + 'the way single-page sites do it, and has to be read in full.</p><p>A second paragraph keeps it longer '
                    + 'than one sentence. Visibility: ' + document.visibilityState + '.</p></article>';
                }
                \(render)
                </script></body></html>
                """)
        }
        let server = try TestHTTPServer(routes: [
            "/frame": page("Frame", "requestAnimationFrame(() => requestAnimationFrame(show));"),
            "/visible": page("Visible", """
                if (document.visibilityState === 'visible') show();
                else document.addEventListener('visibilitychange', () => { if (!document.hidden) show(); });
                """),
        ])
        defer { server.stop() }
        for path in ["/frame", "/visible"] {
            let read = try await LocalExtractor.read(server.url(path), script: script, options: options)
            XCTAssertTrue(read.markdown.contains("This article is rendered by a script"), "\(path): \(read.markdown)")
            XCTAssertTrue(read.markdown.contains("Visibility: visible."), "\(path): \(read.markdown)")
        }
    }

    /// A page that speaks as it loads stays silent: Web Speech does nothing in the web view (F14).
    func testAPageCannotSpeak() async throws {
        let script = try WebKitTestGate.defuddleScript()
        let server = try TestHTTPServer(routes: ["/speak": .html("""
            <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Speaking Page</title></head><body>
            <article id="a"><h1>Speaking Page</h1><p>This page tries to speak a sentence as soon as it loads, without being
            asked to, and then writes down what happened.</p></article><script>
            let started = false;
            const utterance = new SpeechSynthesisUtterance('This page speaks.');
            utterance.volume = 0;
            utterance.onstart = () => { started = true; };
            speechSynthesis.speak(utterance);
            setTimeout(() => {
              const p = document.createElement('p');
              p.textContent = 'Status: speaking ' + speechSynthesis.speaking + ', pending ' + speechSynthesis.pending
                + ', started ' + started + '.';
              document.getElementById('a').appendChild(p);
            }, 400);
            </script></body></html>
            """)])
        defer { server.stop() }
        let page = try await LocalExtractor.read(server.url("/speak"), script: script, options: options)
        XCTAssertTrue(page.markdown.contains("Status: speaking false, pending false, started false."), page.markdown)
    }

    /// Saved pages without a charset, in UTF-8 and in GBK, are read in their own encoding, not
    /// as Latin-1 (F10).
    func testFilesWithoutACharsetAreReadInTheirOwnEncoding() async throws {
        let script = try WebKitTestGate.defuddleScript()
        for name in ["formats/utf8_nometa.html", "formats/gbk_nometa.html"] {
            let page = try await LocalExtractor.read(fileURL: Fixtures.url(name), script: script, options: options)
            XCTAssertEqual(page.title, "没有声明编码的网页", name)
            XCTAssertTrue(page.markdown.contains("语音合成是通过机械的、电子的方法产生人造语音的技术。"), "\(name): \(page.markdown)")
        }
    }

    /// What SelfTest can check: HTML in memory, no network, no page scripts.
    func testHTMLInMemory() async throws {
        let script = try WebKitTestGate.defuddleScript()
        let html = """
            <html lang="en"><head><title>Self Test</title></head><body><article><h1>Self Test</h1>
            <p>ReadRead reads this sentence on this Mac, with the bundled Defuddle and nothing from the network.</p>
            <p>It is a second sentence in a second paragraph.</p></article></body></html>
            """
        let page = try await LocalExtractor.read(html: html, script: script, options: options)
        XCTAssertEqual(page.title, "Self Test")
        XCTAssertTrue(page.markdown.contains("ReadRead reads this sentence on this Mac"), page.markdown)
    }
}

/// Which local .html files WebKit would misread (no charset declared, bytes beyond ASCII),
/// without WebKit (F10).
final class UndeclaredCharsetTests: XCTestCase {
    private let chinese = "<p>语音合成是通过机械的、电子的方法产生人造语音的技术。</p></body></html>"

    func testFilesWithoutADeclarationAreDecodedFirst() throws {
        for name in ["formats/utf8_nometa.html", "formats/gbk_nometa.html"] {
            let text = try XCTUnwrap(LocalExtractor.undeclaredText(of: Data(contentsOf: Fixtures.url(name))), name)
            XCTAssertTrue(text.contains("<title>没有声明编码的网页</title>"), text)
        }
        let unrelatedMeta = #"<html><head><meta name="author" content="作者"><title>x</title></head><body>"# + chinese
        XCTAssertNotNil(try LocalExtractor.undeclaredText(of: Data(unrelatedMeta.utf8)), "a meta tag without a charset")
        let late = "<html><head><!--" + String(repeating: " ", count: 1_100) + #"--><meta charset="utf-8"></head><body>"# + chinese
        XCTAssertNotNil(try LocalExtractor.undeclaredText(of: Data(late.utf8)), "past the first 1,024 bytes no browser looks")
        let korean = "<html><body><p>한국어 텍스트입니다. 이 파일은 EUC-KR로 저장되었습니다. 읽기 프로그램은 한국어를 지원하지 않습니다.</p></body></html>"
        let eucKR = try XCTUnwrap(korean.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))))
        XCTAssertThrowsError(try LocalExtractor.undeclaredText(of: eucKR), "refused as a text file would be")
    }

    func testDeclaredOrPlainFilesAreLeftToWebKit() throws {
        let declared = [
            #"<html><head><meta charset="utf-8"></head><body>"#,
            #"<html><head><META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=gb2312"></head><body>"#,
            "<html><head><meta\n  charset=utf-8 /></head><body>",
            #"<?xml version="1.0" encoding="utf-8"?><html><body>"#,
        ]
        for head in declared {
            XCTAssertNil(try LocalExtractor.undeclaredText(of: Data((head + chinese).utf8)), head)
        }
        XCTAssertNil(try LocalExtractor.undeclaredText(of: Data([0xEF, 0xBB, 0xBF]) + Data(("<html><body>" + chinese).utf8)), "a BOM")
        XCTAssertNil(try LocalExtractor.undeclaredText(of: Data("<html><body><p>Only ASCII here.</p></body></html>".utf8)))
    }
}

/// `XCTAssertThrowsError` for an async expression.
func XCTAssertThrowsErrorAsync<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line,
    _ handler: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
