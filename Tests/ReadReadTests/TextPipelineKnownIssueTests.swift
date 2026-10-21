import XCTest

@testable import ReadRead

/// Gaps in the text pipeline that the property tests and the golden fixtures found (v0.4.0, P7),
/// kept visible as expected failures: each test states the right behaviour, and XCTExpectFailure
/// keeps the suite green until the code is fixed. A fix makes its test fail ("expected failure,
/// but none recorded"); then delete the XCTExpectFailure line and the test guards the fix. The
/// generator in TextPipelinePropertyTests leaves these inputs out.
final class TextPipelineKnownIssueTests: XCTestCase {
    private func texts(_ markdown: String) -> [String] {
        MarkdownCleaner.blocks(markdown).map(\.text)
    }

    /// Escapes.protect runs before the code spans are cut out, and the spans go back in after
    /// Escapes.restore: `a\*b` is shown, and sent to the engine, as "a", U+E02A, "b".
    func testAnEscapeInsideACodeSpanLeavesNoPlaceholder() {
        XCTExpectFailure("MarkdownCleaner: a backslash escape inside a code span keeps its private-use placeholder")
        let text = texts("Run `a\\*b` or `\\[x\\]` here.").joined(separator: "\n")
        XCTAssertFalse(text.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) }, text.debugDescription)
    }

    /// The table-rule pattern wants two columns: a one-column table (valid GFM) is read out as
    /// "| Name | | :---: | | 甲 |".
    func testAOneColumnTableIsDroppedLikeAnyOther() {
        XCTExpectFailure("MarkdownCleaner: a one-column GFM table is not recognised")
        XCTAssertEqual(texts("Text.\n\n| Name |\n| :---: |\n| 甲 |"), ["Text."])
    }

    /// A MediaWiki citation link as Turndown writes it, [\[1\]](#cite_note-1): the escaped
    /// brackets come back after the citation pass, so "[1]" is read as "one".
    func testAnEscapedCitationLinkIsDropped() {
        XCTExpectFailure("MarkdownCleaner: [\\[1\\]](#cite_note-1) leaves the marker [1]")
        let text = texts("A claim.[\\[1\\]](#cite_note-1) Next.").joined(separator: "\n")
        XCTAssertFalse(text.contains("[1]"), text.debugDescription)
    }

    /// In an English piece the Chinese runs are cut out by SpeechChunker.scriptRuns, which
    /// counts ○ neither as a CJK letter nor as a mark attached to one: 二○二四年 becomes the
    /// units "二" and "二四年", and the zero between them is never read. A Chinese piece reads
    /// the same year 二零二四年, and so does an English one written with 〇 (text/en_notes.txt).
    func testACircleZeroInChineseInsideEnglishTextIsRead() {
        XCTExpectFailure("SpeechChunker.scriptRuns: the ○ of 二○二四年 in an English sentence is dropped")
        let document = DocumentBuilder.fromPlainText(
            "Ask whether 二○二四年 should be read as a year.", title: nil, source: .text, sourceLabel: "")
        XCTAssertEqual(document.units.filter { $0.language == .zh }.map(\.speakText), ["二零二四年"])
    }
}
