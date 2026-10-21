import XCTest

@testable import ReadRead

/// Real pages and files through the whole text pipeline, compared with reviewed snapshots
/// in Fixtures/snapshots (R3-15). After an intended change, regenerate them with
/// `READREAD_UPDATE_SNAPSHOTS=1 swift test --filter GoldenDocumentTests` and review the diff.
final class GoldenDocumentTests: XCTestCase {
    private static let pages: [(fixture: String, url: String)] = [
        ("pages/en_wikipedia.md", "https://en.wikipedia.org/wiki/Text_to_speech"),
        ("pages/zh_wikipedia.md", "https://zh.wikipedia.org/wiki/语音合成"),
        ("pages/hn.md", "https://news.ycombinator.com/item?id=1"),
        ("pages/zh_tech_blog.md", "https://blog.example.com/2024/10/menubar-reader"),
        ("pages/en_article.md", "https://journal.example.org/talking-machines"),
    ]
    private static let files = [
        "text/en_crlf.txt", "text/en_hardwrap.txt", "text/zh_novel_singlenl.txt", "encodings/big5_long.txt",
        "text/zh_dialogue.txt", "text/en_notes.txt",
    ]

    private var updating: Bool { ProcessInfo.processInfo.environment["READREAD_UPDATE_SNAPSHOTS"] == "1" }

    func testPages() async throws {
        for (fixture, address) in Self.pages {
            let data = try Fixtures.data(fixture)
            let loader = DocumentLoader(
                fetchPage: { url in try await WebExtractor.extractFromURL(url, fetch: { _ in data }) },
                readFile: { _ in throw WebExtractorError.fileReadFailed("unused") })
            let document = try await loader.load(.url(try XCTUnwrap(URL(string: address))))
            try check(document, against: fixture)
        }
    }

    func testFiles() async throws {
        for fixture in Self.files {
            let document = try await DocumentLoader().load(.file(Fixtures.url(fixture)))
            try check(document, against: fixture)
        }
    }

    func testHardWrappedAndCRLFEnglishSpeakTheSameWords() async throws {
        let crlf = try await DocumentLoader().load(.file(Fixtures.url("text/en_crlf.txt")))
        let wrapped = try await DocumentLoader().load(.file(Fixtures.url("text/en_hardwrap.txt")))
        func words(_ document: ReadingDocument) -> [Substring] {
            document.units.map(\.speakText).joined(separator: " ").split(whereSeparator: \.isWhitespace)
        }
        XCTAssertEqual(words(crlf), words(wrapped))
    }

    /// A 1 MB single-newline novel: built in reasonable time, every invariant holding.
    func testAOneMegabyteNovel() throws {
        let chapter = try Fixtures.text("text/zh_novel_singlenl.txt")
        let novel = Array(repeating: chapter, count: 120).joined(separator: "\n")
        XCTAssertGreaterThan(novel.utf8.count, 1_000_000)
        let one = DocumentBuilder.fromPlainText(chapter, title: nil, source: .text, sourceLabel: "")
        let start = ContinuousClock.now
        let document = DocumentBuilder.fromPlainText(novel, title: nil, source: .text, sourceLabel: "")
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(20), "building took \(elapsed)")
        XCTAssertEqual(document.blocks.count, 120 * one.blocks.count)
        XCTAssertEqual(document.units.count, 120 * one.units.count)
        XCTAssertEqual(document.detectedLanguage, .zh)
        for unit in document.units {
            XCTAssertLessThanOrEqual(unit.speakText.count, SpeechChunker.englishCap, unit.speakText)
            XCTAssertEqual(document.displayText(of: unit), unit.speakText)
        }
    }

    // MARK: - Snapshots

    private func check(_ document: ReadingDocument, against fixture: String,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let name = fixture.replacingOccurrences(of: "/", with: "_") + ".snapshot"
        let url = Fixtures.url("snapshots/\(name)")
        let rendered = Self.render(document)
        if updating {
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            return XCTFail("no snapshot \(name); run with READREAD_UPDATE_SNAPSHOTS=1 and review it", file: file, line: line)
        }
        guard rendered != expected else { return }
        let renderedLines = rendered.components(separatedBy: "\n")
        let expectedLines = expected.components(separatedBy: "\n")
        let common = min(renderedLines.count, expectedLines.count)
        let first = (0..<common).first { renderedLines[$0] != expectedLines[$0] } ?? common
        let got = renderedLines.indices.contains(first) ? renderedLines[first] : "<end>"
        let want = expectedLines.indices.contains(first) ? expectedLines[first] : "<end>"
        XCTFail("\(name) differs at line \(first + 1):\n  got:  \(got)\n  want: \(want)", file: file, line: line)
    }

    /// One header line per block, one line per unit: id, kind, language, speak text.
    static func render(_ document: ReadingDocument) -> String {
        var lines = [
            "title: \(document.title)",
            "source: \(document.sourceLabel)",
            "language: \(document.detectedLanguage.rawValue)",
            "blocks: \(document.blocks.count), units: \(document.units.count)",
        ]
        for (index, block) in document.blocks.enumerated() {
            lines.append("")
            lines.append("# \(index) \(block.kind.rawValue)")
            if block.units.isEmpty { lines.append("  (nothing to read) \(block.text)") }
            for unit in document.units[block.units] {
                let language = unit.language?.rawValue ?? "--"
                let kind = unit.kind == .sentence ? "" : " \(unit.kind.rawValue)"
                lines.append("  \(unit.id) \(language)\(kind) | \(unit.speakText.replacingOccurrences(of: "\n", with: "⏎"))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
