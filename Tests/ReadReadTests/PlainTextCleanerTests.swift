import XCTest

@testable import ReadRead

/// .txt files and pasted text → blocks (R3-03 app side, R5-13).
final class PlainTextCleanerTests: XCTestCase {
    private typealias Block = MarkdownCleaner.Block
    private func texts(_ text: String) -> [String] { PlainTextCleaner.blocks(text).map(\.text) }

    /// The same article twice: one paragraph per line with CRLF, and wrapped at 72 columns
    /// with every paragraph (lists included) reflowed. Same words in the same order; the
    /// wrapped file has one block per paragraph, mid-paragraph lines ending in "." or ":" too.
    func testHardWrappedEnglishReadsLikeTheUnwrappedCRLFFile() throws {
        let wrappedText = try TextDecoding.decode(try Fixtures.data("text/en_hardwrap.txt")).text
        let wrapped = PlainTextCleaner.blocks(wrappedText)
        let crlf = PlainTextCleaner.blocks(try TextDecoding.decode(try Fixtures.data("text/en_crlf.txt")).text)
        XCTAssertEqual(PlainTextCleaner.wrapColumn(wrappedText.split(separator: "\n", omittingEmptySubsequences: false)), 72)
        XCTAssertEqual(wrapped.count, 147, "one block per blank-line paragraph")
        XCTAssertEqual(crlf.count, 158, "the CRLF file's four unbulleted lists keep a block per line")
        func words(_ blocks: [MarkdownCleaner.Block]) -> [Substring] {
            blocks.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace)
        }
        XCTAssertEqual(words(wrapped), words(crlf))
        XCTAssertTrue(wrapped[0].text.contains("A text-to-speech (TTS) system"), "a hyphen at a wrap joins the word")
        XCTAssertFalse(wrapped[0].text.contains("[^1]"))
        XCTAssertTrue(wrapped.contains { $0.text.contains("his novel 2001: A Space Odyssey") }, "a wrap after a colon")
    }

    func testAChineseNovelWithOneParagraphPerLineKeepsEveryLine() throws {
        let blocks = PlainTextCleaner.blocks(try Fixtures.text("text/zh_novel_singlenl.txt"))
        XCTAssertEqual(blocks.count, 30)
        XCTAssertEqual(blocks[0], Block(kind: .paragraph, text: "第一章　语音之书"))
        XCTAssertTrue(blocks[1].text.hasPrefix("語音合成 是將人類語音"), "the ideographic indent goes")
        XCTAssertFalse(blocks.contains { $0.text.contains("[^") })
    }

    func testBlankLinesSeparateParagraphs() {
        XCTAssertEqual(texts("One.\n\n\nTwo.\n   \nThree."), ["One.", "Two.", "Three."])
        XCTAssertEqual(texts("Para one.\u{2029}Para two.\u{2028}Line two."), ["Para one.", "Para two.", "Line two."])
        XCTAssertEqual(texts("  \n\t\n"), [])
    }

    func testShortLinesStayLines() {
        XCTAssertEqual(texts("Dear Ann,\nThanks for the book\nBest, Bo"), ["Dear Ann,", "Thanks for the book", "Best, Bo"])
    }

    func testALongLineWithoutAClosingMarkWrapsIntoTheNextUnlessItIsIndented() {
        let long = "This line is long enough to have been wrapped by an editor and"
        XCTAssertEqual(texts("\(long)\nit goes on here."), ["\(long) it goes on here."])
        XCTAssertEqual(texts("\(long)\n    an indented line starts a paragraph."),
                       [long, "an indented line starts a paragraph."])
        XCTAssertEqual(texts("This line is long enough to have been wrapped, and it ends.\nNext line."),
                       ["This line is long enough to have been wrapped, and it ends.", "Next line."])
        XCTAssertEqual(texts("天色渐暗，城门外的老槐树下站着一个少年，他叫林风，今年\n十六岁。"),
                       ["天色渐暗，城门外的老槐树下站着一个少年，他叫林风，今年十六岁。"], "CJK joins without a space")
    }

    func testBulletsAreListItems() {
        XCTAssertEqual(PlainTextCleaner.blocks("Shopping:\n• milk\n- eggs\n* bread"), [
            Block(kind: .paragraph, text: "Shopping:"), Block(kind: .listItem, text: "milk"),
            Block(kind: .listItem, text: "eggs"), Block(kind: .listItem, text: "bread"),
        ])
        XCTAssertNil(PlainTextCleaner.bulletItem("-5 degrees"))
        XCTAssertNil(PlainTextCleaner.bulletItem("* "))
    }

    func testEmojiAndSeparatorsAsInMarkdown() {
        XCTAssertEqual(texts("好消息🎉！苹果 • 香蕉"), ["好消息！苹果，香蕉"])
        XCTAssertEqual(texts("A citation.[3] A note.[^2]"), ["A citation. A note."])
    }

    /// The inline rules are Markdown's (Inline.clean): the same URL, citation and tag fixes.
    func testURLsCitationsAndComparisonsInPlainText() {
        XCTAssertEqual(texts("下载地址：https://example.com/file.zip，提取码：abcd。请尽快下载。"), ["下载地址：，提取码：abcd。请尽快下载。"])
        XCTAssertEqual(texts("这是事实。[1][2]另一个事实。[3]"), ["这是事实。另一个事实。"])
        XCTAssertEqual(texts("if (a<b && c>d) { return x<y; } and 2*3*4"), ["if (a<b && c>d) { return x<y; } and 2*3*4"])
        XCTAssertEqual(texts("二○二四年十月 1️⃣ 第一"), ["二○二四年十月 1 第一"])
    }

    func testDisplayWidthCountsCJKTwice() {
        XCTAssertEqual(PlainTextCleaner.width("abc"), 3)
        XCTAssertEqual(PlainTextCleaner.width("中文ab"), 6)
    }
}
