import XCTest

@testable import ReadRead

/// Blocks → ReadingDocument: the title first (R3-14), units with their languages (R3-09).
final class DocumentBuilderTests: XCTestCase {
    private let page = DocumentSource.url(URL(string: "https://example.com/post#top")!)

    func testTheTitleIsTheFirstUnitAlone() {
        let document = DocumentBuilder.fromMarkdown("First sentence. Second sentence.", title: "My Title",
                                                    source: page, sourceLabel: "example.com")
        XCTAssertEqual(document.title, "My Title")
        XCTAssertEqual(document.blocks.map(\.kind), [.title, .paragraph])
        XCTAssertEqual(document.units.map(\.speakText), ["My Title.", "First sentence.", "Second sentence."])
        XCTAssertEqual(document.units.map(\.kind), [.title, .sentence, .sentence])
        XCTAssertEqual(document.units[0].pauseAfter, 0.5)
        XCTAssertEqual(document.displayText(of: document.units[0]), "My Title", "the stop is only spoken")
        XCTAssertEqual(document.units.map(\.endsBlock), [true, false, true])
    }

    func testABodyThatStartsWithTheTitleIsNotReadTwice() {
        let document = DocumentBuilder.fromMarkdown("# Speech **synthesis**\n\nIt is artificial speech.",
                                                    title: "Speech synthesis", source: page, sourceLabel: "")
        XCTAssertEqual(document.blocks.map(\.kind), [.title, .paragraph])
        XCTAssertEqual(document.units.map(\.speakText), ["Speech synthesis.", "It is artificial speech."])
    }

    func testWithoutATitleTheFirstHeadingNamesTheDocument() {
        let document = DocumentBuilder.fromMarkdown("## 一、简介\n\nrsync 是一个常用的 Linux 应用程序。", title: nil,
                                                    source: page, sourceLabel: "")
        XCTAssertEqual(document.title, "一、简介")
        XCTAssertEqual(document.units.map(\.speakText), ["一、简介。", "rsync 是一个常用的 Linux 应用程序。"])
        XCTAssertEqual(document.units.map(\.kind), [.heading, .sentence])
    }

    func testFallbackTitles() {
        let file = URL(fileURLWithPath: "/tmp/My Novel.txt")
        XCTAssertEqual(DocumentBuilder.fromPlainText("正文。", title: nil, source: .file(file), sourceLabel: "My Novel.txt").title,
                       "My Novel")
        XCTAssertEqual(DocumentBuilder.fromPlainText("Body.", title: nil, source: page, sourceLabel: "").title, "example.com")
        XCTAssertEqual(DocumentBuilder.fromPlainText("A pasted line.\nAnd more.", title: nil, source: .text, sourceLabel: "").title,
                       "A pasted line.")
        let long = String(repeating: "很长", count: 60)
        XCTAssertEqual(DocumentBuilder.fromPlainText(long, title: nil, source: .text, sourceLabel: "").title,
                       String(long.prefix(80)) + "…")
        XCTAssertEqual(DocumentBuilder.fallbackTitle(source: .text, sourceLabel: "", firstText: nil), "Untitled")
    }

    func testTitlesAreCleanedLikeText() {
        XCTAssertEqual(DocumentBuilder.cleanTitle("Fish &amp; Chips 🎉\nPart 2"), "Fish & Chips Part 2")
        XCTAssertEqual(DocumentBuilder.fromPlainText("Body.", title: "  ", source: .text, sourceLabel: "").title, "Body.",
                       "a blank title is no title")
    }

    func testEveryUnitHasItsOwnLanguageAndTheDocumentTheMajority() {
        let document = DocumentBuilder.fromPlainText(
            "这是第一句中文。这是第二句中文，比较长一些。\n\nThis one is English.\n\nこれは日本語です。\n\n2024", title: nil,
            source: .text, sourceLabel: "")
        XCTAssertEqual(document.detectedLanguage, .zh)
        XCTAssertEqual(document.units.map(\.language), [.zh, .zh, .en, nil, .zh])
        XCTAssertEqual(document.language(under: .auto), .zh)
        XCTAssertEqual(document.language(under: .en), .en)
        XCTAssertFalse(document.isEmpty)
    }

    func testUnitsAndBlocksLineUp() throws {
        let markdown = Frontmatter.split(try Fixtures.text("pages/zh_wikipedia.md")).body
        let document = DocumentBuilder.fromMarkdown(markdown, title: "语音合成", source: page, sourceLabel: "")
        XCTAssertEqual(document.units.map(\.id), Array(document.units.indices))
        for (index, block) in document.blocks.enumerated() {
            for unitIndex in block.units {
                let unit = document.units[unitIndex]
                XCTAssertEqual(unit.block, index)
                XCTAssertTrue(block.text.count >= unit.range.upperBound)
                XCTAssertEqual(unit.endsBlock, unitIndex == block.units.upperBound - 1)
                if unit.kind == .sentence { XCTAssertEqual(document.displayText(of: unit), unit.speakText) }
                XCTAssertLessThanOrEqual(unit.speakText.unicodeScalars.count, SpeechChunker.maxSpeakCharacters)
            }
        }
        XCTAssertEqual(document.blocks.flatMap { Array($0.units) }, Array(document.units.indices), "every unit in one block")
    }

    func testContentHashAndPositionKeys() {
        let a = DocumentBuilder.fromPlainText("Same text.", title: nil, source: page, sourceLabel: "")
        let b = DocumentBuilder.fromPlainText("Same text.", title: nil, source: .text, sourceLabel: "")
        let c = DocumentBuilder.fromPlainText("Other text.", title: nil, source: .text, sourceLabel: "")
        XCTAssertEqual(a.contentHash, b.contentHash)
        XCTAssertNotEqual(a.contentHash, c.contentHash)
        XCTAssertEqual(a.contentHash.count, 64)
        XCTAssertEqual(a.positionKey, "url:https://example.com/post", "no fragment")
        XCTAssertEqual(b.positionKey, "text:" + b.contentHash)
        let file = DocumentBuilder.fromPlainText("x", title: nil, source: .file(URL(fileURLWithPath: "/tmp/../tmp/a.txt")),
                                                 sourceLabel: "")
        XCTAssertEqual(file.positionKey, "file:/tmp/a.txt")
    }

    /// R3-09: the en pipeline says "Chinese letter" for every Han character. Han runs in an
    /// English unit become units of their own, read in Chinese; kana runs are skipped.
    func testHanInsideEnglishIsReadInChinese() {
        let document = DocumentBuilder.fromMarkdown(
            "**Lu Xun** (Chinese: 鲁迅; 25 September 1881 – 19 October 1936) was a Chinese writer. He said 你好 to me. "
                + "The word ポケモン means pocket monster. It was 1881年 in 绍兴（浙江） then, a long time ago.",
            title: "Lu Xun 鲁迅", source: .text, sourceLabel: "")
        XCTAssertEqual(document.detectedLanguage, .en)
        XCTAssertEqual(document.units.map { "\($0.language?.rawValue ?? "--") \($0.speakText)" }, [
            "en Lu Xun", "zh 鲁迅。",
            "en Lu Xun (Chinese:", "zh 鲁迅", "en ; 25 September 1881 – 19 October 1936) was a Chinese writer.",
            "en He said", "zh 你好", "en to me.",
            "en The word", "-- ポケモン", "en means pocket monster.",
            "en It was", "zh 1881年", "en in", "zh 绍兴（浙江）", "en then, a long time ago.",
        ])
        XCTAssertEqual(document.units.map(\.kind).prefix(3), [.title, .title, .sentence])
        XCTAssertEqual(document.units.filter(\.endsBlock).map(\.speakText), ["鲁迅。", "then, a long time ago."])
        for unit in document.units {
            if unit.language == .en { XCTAssertFalse(LanguageDetector.hasCJKLetters(unit.speakText), unit.speakText) }
            XCTAssertEqual(document.displayText(of: unit), unit.kind == .title ? unit.speakText.replacingOccurrences(of: "。", with: "")
                                                                                : unit.speakText)
        }
        let chinese = DocumentBuilder.fromPlainText("我们用 Swift 写了一个朗读应用。Born in 1881年 in 绍兴（浙江）.", title: nil,
                                                    source: .text, sourceLabel: "")
        XCTAssertEqual(chinese.units.map(\.speakText), ["我们用 Swift 写了一个朗读应用。", "Born in 1881年 in 绍兴（浙江）."],
                       "a Chinese unit (Han ≥ 0.3 of the letters) stays whole: the zh pipeline reads English")
        XCTAssertEqual(chinese.units.map(\.language), [.zh, .zh])
    }

    /// The server drops ○ and has no reading for 〇: both are read 零 in a number.
    func testCirclesUsedAsZeroAreRead() {
        let document = DocumentBuilder.fromPlainText("二○二四年十月，一九◯◯年。〇号线和○○公司。", title: nil, source: .text, sourceLabel: "")
        XCTAssertEqual(document.units.map(\.speakText), ["二零二四年十月，一九零零年。", "零号线和○○公司。"])
        XCTAssertEqual(document.displayText(of: document.units[0]), "二○二四年十月，一九◯◯年。", "the display keeps the circles")
    }

    func testNothingReadable() {
        XCTAssertTrue(DocumentBuilder.fromMarkdown("![x](y.png)\n\n---", title: nil, source: .text, sourceLabel: "").units.isEmpty)
        XCTAssertTrue(DocumentBuilder.fromPlainText("これは日本語です。", title: nil, source: .text, sourceLabel: "").isEmpty)
    }
}
