import XCTest

@testable import ReadRead

/// Sentences and long-sentence cuts (R3-03), plus properties every chunking must have.
final class SpeechChunkerTests: XCTestCase {
    private func sentences(_ text: String) -> [String] { SpeechChunker.pieces(of: text).map(\.text) }
    private func speakable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }))
    }

    // MARK: - Chinese

    func testChineseSentenceEndsWithClosingQuotes() {
        XCTAssertEqual(sentences("他说：“你终于来了。”她笑了！真的吗？是的；好……然后呢"),
                       ["他说：“你终于来了。”", "她笑了！", "真的吗？", "是的；", "好……", "然后呢"])
        XCTAssertEqual(sentences("（这是括号里的话。）下一句。"), ["（这是括号里的话。）", "下一句。"])
    }

    func testChineseNeedsNoSpaceAfterLatinMarks() {
        XCTAssertEqual(sentences("我用Swift.然后用Python!最后呢?"), ["我用Swift.", "然后用Python!", "最后呢?"])
    }

    // MARK: - English

    func testEnglishSentenceEnds() {
        XCTAssertEqual(sentences("It works. Does it? Yes! \"Quoted.\" Next (aside.) Done"),
                       ["It works.", "Does it?", "Yes!", "\"Quoted.\"", "Next (aside.)", "Done"])
    }

    func testAbbreviationsDecimalsVersionsDomainsAndInitials() {
        XCTAssertEqual(sentences("Mr. Smith met Dr. Jones at St. Paul's. They paid $3.50 for v1.2.3 at example.com today."),
                       ["Mr. Smith met Dr. Jones at St. Paul's.", "They paid $3.50 for v1.2.3 at example.com today."])
        XCTAssertEqual(sentences("J. R. R. Tolkien wrote it. The U.S. Army agreed, e.g. in 1944."),
                       ["J. R. R. Tolkien wrote it.", "The U.S. Army agreed, e.g. in 1944."])
        XCTAssertEqual(sentences("Apples, pears, etc. are fruit. We sell fruit etc. Then we close."),
                       ["Apples, pears, etc. are fruit.", "We sell fruit etc.", "Then we close."])
        XCTAssertEqual(sentences("Wait... what? Yahoo!Japan is a site."), ["Wait... what?", "Yahoo!Japan is a site."])
        XCTAssertEqual(sentences("Fig. 3 shows it."), ["Fig. 3 shows it."])
        XCTAssertEqual(sentences("Pope Silvester II (d. 1003 AD) built one. Then c. 1300 another."),
                       ["Pope Silvester II (d. 1003 AD) built one.", "Then c. 1300 another."])
        XCTAssertEqual(sentences("1960年，瑞典語言學家G. Fant提出了新方法。"), ["1960年，瑞典語言學家G. Fant提出了新方法。"],
                       "an initial after Han characters")
    }

    func testNewlinesEndSentences() {
        XCTAssertEqual(sentences("Line one\nLine two"), ["Line one", "Line two"])
    }

    func testFragmentsWithNothingToSayAreNoUnit() {
        XCTAssertEqual(sentences("…… —— !!"), [])
        XCTAssertEqual(sentences("好。 …… 再见。"), ["好。", "再见。"])
    }

    // MARK: - Long sentences

    func testALongChineseSentenceIsCutAtClausePunctuation() {
        let clause = "这是一个相当长的分句用来测试切分规则是否正确"  // 22 characters
        let sentence = Array(repeating: clause, count: 12).joined(separator: "，") + "。"
        let pieces = sentences(sentence)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= SpeechChunker.chineseCap }, "\(pieces.map(\.count))")
        XCTAssertTrue(pieces.dropLast().allSatisfy { $0.hasSuffix("，") }, "cut after a comma")
        XCTAssertEqual(pieces.joined(), sentence)
    }

    func testALongEnglishSentenceIsCutAtCommasThenSpaces() {
        let withCommas = Array(repeating: "and this clause keeps going for a while", count: 10).joined(separator: ", ") + "."
        let pieces = sentences(withCommas)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= SpeechChunker.englishCap })
        XCTAssertTrue(pieces.dropLast().allSatisfy { $0.hasSuffix(",") })

        let noCommas = Array(repeating: "word", count: 120).joined(separator: " ") + "."
        let spaced = sentences(noCommas)
        XCTAssertTrue(spaced.allSatisfy { $0.count <= SpeechChunker.englishCap })
        XCTAssertTrue(spaced.allSatisfy { !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
        XCTAssertEqual(spaced.joined(separator: " "), noCommas, "cut at spaces, words whole")

        let oneWord = String(repeating: "x", count: 500)
        XCTAssertEqual(sentences(oneWord).map(\.count), [166, 167, 167], "no break at all: even hard cuts")

        // Just over the cap: two halves, not the cap and a stub.
        let justOver = Array(repeating: "word", count: 45).joined(separator: " ") + " model."
        XCTAssertEqual(justOver.count, 231)
        let halves = sentences(justOver)
        XCTAssertEqual(halves.count, 2)
        XCTAssertTrue(halves.allSatisfy { $0.count > 100 }, "\(halves.map(\.count))")
    }

    func testDigitGroupsAndTimesAreNotClauseBreaks() {
        // The only commas and colons sit where a cut would go: it goes at a space instead.
        let words = Array(repeating: "word", count: 40).joined(separator: " ")
        let long = words + " 1,234,567 at 12:30 " + words + "."
        let pieces = sentences(long)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertFalse(piece.last.map { $0 == "," || $0 == ":" } ?? false, piece)
        }
        XCTAssertTrue(pieces.contains { $0.contains("1,234,567") } || pieces.contains { $0.contains("12:30") })
    }

    // MARK: - Properties

    func testRangesPointAtThePieceText() throws {
        for path in ["pages/zh_wikipedia.md", "pages/en_wikipedia.md"] {
            let page = Frontmatter.split(try Fixtures.text(path)).body
            for block in MarkdownCleaner.blocks(page) {
                let characters = Array(block.text)
                var previousEnd = 0
                for piece in SpeechChunker.pieces(of: block.text) {
                    XCTAssertEqual(String(characters[piece.range]), piece.text, path)
                    XCTAssertGreaterThanOrEqual(piece.range.lowerBound, previousEnd, "in order, no overlap")
                    previousEnd = piece.range.upperBound
                    XCTAssertLessThanOrEqual(piece.text.count, SpeechChunker.englishCap, piece.text)
                    XCTAssertFalse(piece.text.first!.isWhitespace || piece.text.last!.isWhitespace, piece.text)
                }
                // Nothing speakable is lost between the pieces.
                let covered = SpeechChunker.pieces(of: block.text).map(\.text).joined()
                XCTAssertEqual(speakable(covered), speakable(block.text), path)
            }
        }
    }

    // MARK: - Speak text

    func testTerminalStops() {
        XCTAssertEqual(SpeechChunker.withTerminalStop("一、简介", language: .zh), "一、简介。")
        XCTAssertEqual(SpeechChunker.withTerminalStop("Introduction", language: .en), "Introduction.")
        XCTAssertEqual(SpeechChunker.withTerminalStop("Why?", language: .en), "Why?")
        XCTAssertEqual(SpeechChunker.withTerminalStop("“好。”", language: .zh), "“好。”")
        XCTAssertEqual(SpeechChunker.withTerminalStop("", language: .zh), "")
    }

    func testSpeakTextIsClampedToTheServerLimit() {
        let combining = "a" + String(repeating: "\u{301}", count: 4_000)  // one Character, 4001 code points
        XCTAssertEqual(SpeechChunker.clamp(combining).unicodeScalars.count, SpeechChunker.maxSpeakCharacters)
        XCTAssertEqual(SpeechChunker.clamp("short"), "short")
    }
}
