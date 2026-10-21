import XCTest

@testable import ReadRead

/// Token timings placed on the display text: real server responses (Fixtures/timings), then the
/// rules one by one.
final class WordTimelineTests: XCTestCase {
    /// A fixture decoded the way the app decodes the server's answer, and its input text.
    private func fixture(_ name: String) throws -> (result: SynthesisResult, text: String) {
        let data = try Fixtures.data("timings/\(name).json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = try XCTUnwrap(json["input_text"] as? String)
        json["audio"] = minimalWAV.base64EncodedString()  // the fixture keeps timings only
        let result = try TTSClient.decodeSynthesis(JSONSerialization.data(withJSONObject: json), requestedSpeed: 1.0)
        return (result, text)
    }

    /// The display text of the word spoken at `time`.
    private func spoken(_ timeline: WordTimeline, _ text: String, at time: Double) -> String? {
        guard let word = timeline.word(at: time) else { return nil }
        return String(Array(text)[word.range])
    }

    private func assertWellFormed(_ timeline: WordTimeline, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let count = text.count
        var previous: Range<Int>?
        for word in timeline.words {
            XCTAssertTrue(word.range.lowerBound >= 0 && word.range.upperBound <= count, "\(word.range)", file: file, line: line)
            XCTAssertFalse(word.range.isEmpty, file: file, line: line)
            if let previous { XCTAssertGreaterThanOrEqual(word.range.lowerBound, previous.lowerBound, file: file, line: line) }
            previous = word.range
        }
        XCTAssertEqual(timeline.words.map(\.start), timeline.words.map(\.start).sorted(), file: file, line: line)
    }

    // MARK: - Real server timings

    func testChineseWordsAreFoundOnTheSurface() throws {
        let (result, text) = try fixture("zh_plain")
        let timeline = WordTimeline(tokens: result.tokens, displayText: text)
        XCTAssertEqual(timeline.words.map(\.range), [0..<4, 4..<6, 7..<9, 9..<11, 11..<12, 12..<14, 14..<16, 16..<17])
        XCTAssertTrue(timeline.words.allSatisfy(\.matched))
        XCTAssertEqual(spoken(timeline, text, at: 1.0), "很好")
        XCTAssertEqual(spoken(timeline, text, at: 1.8), "很好", "between words: the last one that started")
        XCTAssertEqual(spoken(timeline, text, at: 3.7), "吧")
        assertWellFormed(timeline, text)
    }

    func testChineseNumbersReadAloudFallBackToTheirDigits() throws {
        let (result, text) = try fixture("zh_numbers_english")
        XCTAssertEqual(result.tokens.first?.text, "二零二", "the server reads 2024 digit by digit")
        let timeline = WordTimeline(tokens: result.tokens, displayText: text)
        XCTAssertEqual(timeline.words.count, result.tokens.count, "every token has a place")
        XCTAssertNil(spoken(timeline, text, at: 0.1), "before the first word")
        XCTAssertEqual(spoken(timeline, text, at: 0.3), "2024")
        XCTAssertEqual(spoken(timeline, text, at: 1.2), "10")
        XCTAssertEqual(spoken(timeline, text, at: 2.5), "我")
        XCTAssertEqual(spoken(timeline, text, at: 2.9), "iPhone")
        XCTAssertEqual(spoken(timeline, text, at: 3.6), "ReadRead")
        XCTAssertEqual(spoken(timeline, text, at: 4.3), "3篇")
        XCTAssertEqual(spoken(timeline, text, at: 6.0), "12.5")
        XCTAssertEqual(spoken(timeline, text, at: 6.6), "元")
        XCTAssertEqual(spoken(timeline, text, at: 7.0), "元", "the last word is held a moment")
        XCTAssertNil(spoken(timeline, text, at: 7.2))
        let matched = timeline.words.filter(\.matched).map { String(Array(text)[$0.range]) }
        XCTAssertEqual(matched, ["我", "在", "iPhone", "上用", "ReadRead", "读", "了", "文章", "一共", "花", "了"])
        assertWellFormed(timeline, text)
    }

    func testNormalizedEnglishIsPlacedOnWhatIsShown() throws {
        let (result, text) = try fixture("en_sentence")
        XCTAssertEqual(result.tokens.prefix(3).map(\.text), ["On", "the", "twenty-first"])
        let timeline = WordTimeline(tokens: result.tokens, displayText: text)
        XCTAssertEqual(spoken(timeline, text, at: 0.1), "On")
        XCTAssertEqual(spoken(timeline, text, at: 0.25), "21", "\"the twenty-first of\" is the 21")
        XCTAssertEqual(spoken(timeline, text, at: 0.5), "21")
        XCTAssertEqual(spoken(timeline, text, at: 0.9), "21")
        XCTAssertEqual(spoken(timeline, text, at: 1.2), "October")
        XCTAssertEqual(spoken(timeline, text, at: 2.0), "2024")
        XCTAssertEqual(spoken(timeline, text, at: 3.1), "Dr", "Doctor → Dr.")
        XCTAssertEqual(spoken(timeline, text, at: 4.5), "3.5")
        XCTAssertEqual(spoken(timeline, text, at: 5.7), "the", "the second the, after chapters of")
        XCTAssertEqual(spoken(timeline, text, at: 6.0), "e-book")
        XCTAssertEqual(spoken(timeline, text, at: 6.59), "in")
        XCTAssertEqual(spoken(timeline, text, at: 6.9), "London")
        let firstThe = try XCTUnwrap(timeline.words.first { $0.start == 0.215 })
        XCTAssertFalse(firstThe.matched, "the later \"the\" belongs to a later token")
        assertWellFormed(timeline, text)
    }

    func testBritishTimeReadAsLetters() throws {
        let (result, text) = try fixture("en_gb_sentence")
        let timeline = WordTimeline(tokens: result.tokens, displayText: text)
        XCTAssertEqual(spoken(timeline, text, at: 0.3), "garden")
        XCTAssertEqual(spoken(timeline, text, at: 1.6), "4")
        XCTAssertEqual(spoken(timeline, text, at: 1.8), "30")
        XCTAssertEqual(spoken(timeline, text, at: 2.1), "pm", "P and M share pm")
        XCTAssertEqual(spoken(timeline, text, at: 2.5), "pm")
        XCTAssertEqual(spoken(timeline, text, at: 3.5), "umbrella")
        assertWellFormed(timeline, text)
    }

    // MARK: - Rules

    func testNoTokensNoWords() {
        let timeline = WordTimeline(tokens: [], displayText: "Read by the system voice.")
        XCTAssertTrue(timeline.words.isEmpty)
        XCTAssertNil(timeline.word(at: 0.5))
        XCTAssertTrue(WordTimeline(tokens: [TimedSpan(text: "x", start: 0, end: 1)], displayText: "").words.isEmpty)
    }

    func testBadTimesAreIgnoredAndTokensAreSortedByStart() {
        let tokens = [
            TimedSpan(text: "world", start: 0.5, end: 0.9),
            TimedSpan(text: "hello", start: 0.0, end: 0.4),
            TimedSpan(text: "bad", start: .nan, end: 1),
            TimedSpan(text: "worse", start: 2, end: 1),
        ]
        let timeline = WordTimeline(tokens: tokens, displayText: "hello world")
        XCTAssertEqual(timeline.words.map(\.range), [0..<5, 6..<11])
        XCTAssertEqual(timeline.words.map(\.start), [0.0, 0.5])
    }

    func testTraditionalWidthAndCaseAreFolded() {
        let traditional = WordTimeline(tokens: [TimedSpan(text: "这是", start: 0, end: 0.4), TimedSpan(text: "测试", start: 0.4, end: 0.8)],
                                       displayText: "這是測試。")
        XCTAssertEqual(traditional.words.map(\.range), [0..<2, 2..<4])
        XCTAssertTrue(traditional.words.allSatisfy(\.matched))

        let wide = WordTimeline(tokens: [TimedSpan(text: "abc", start: 0, end: 0.4), TimedSpan(text: "café", start: 0.4, end: 0.8)],
                                displayText: "ＡＢＣ Cafe")
        XCTAssertEqual(wide.words.map(\.range), [0..<3, 4..<8])
        XCTAssertTrue(wide.words.allSatisfy(\.matched))

        let quotes = WordTimeline(tokens: [TimedSpan(text: "don't", start: 0, end: 0.4)], displayText: "Don’t")
        XCTAssertEqual(quotes.words.first?.matched, true)
    }

    func testALatinTokenOnlyMatchesAWholeWord() {
        let timeline = WordTimeline(tokens: [TimedSpan(text: "in", start: 0, end: 0.2)], displayText: "Spinning in place")
        XCTAssertEqual(timeline.words.map(\.range), [9..<11])
        XCTAssertEqual(timeline.words.first?.matched, true)
    }

    func testTheChainWithTheMostMatchedTextWins() {
        // "the" could match early only by giving up everything after it.
        let tokens = ["a", "the", "cat", "sat", "on", "the", "mat"].enumerated().map {
            TimedSpan(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.5)
        }
        let timeline = WordTimeline(tokens: tokens, displayText: "A cat sat on the mat")
        XCTAssertEqual(timeline.words.filter(\.matched).map(\.range), [0..<1, 2..<5, 6..<9, 10..<12, 13..<16, 17..<20])
        XCTAssertEqual(timeline.words.count, 6, "the early \"the\" has no text of its own: the a stays lit")
    }

    func testUnmatchedTokensShareTheWordsBetweenTheirNeighbours() {
        // "one two three" read as unrelated tokens: spread over the three words in order.
        let tokens = ["start", "uno", "dos", "tres", "end"].enumerated().map {
            TimedSpan(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.5)
        }
        let timeline = WordTimeline(tokens: tokens, displayText: "start one two three end")
        XCTAssertEqual(timeline.words.map(\.range), [0..<5, 6..<9, 10..<13, 14..<19, 20..<23])
        XCTAssertEqual(timeline.words.map(\.matched), [true, false, false, false, true])
    }

    func testMoreTokensThanWordsShareAWord() {
        let tokens = (0..<3).map { TimedSpan(text: "t\($0)", start: Double($0), end: Double($0) + 0.5) }
        let timeline = WordTimeline(tokens: tokens, displayText: "¡Ω!")
        XCTAssertEqual(timeline.words.map(\.range), [1..<2, 1..<2, 1..<2], "Ω is the only word")
    }

    func testWordAtTime() {
        let timeline = WordTimeline(words: [
            WordTimeline.Word(range: 0..<2, start: 0.1, end: 0.5, matched: true),
            WordTimeline.Word(range: 3..<5, start: 0.6, end: 1.0, matched: true),
        ])
        XCTAssertNil(timeline.word(at: 0.05))
        XCTAssertEqual(timeline.word(at: 0.1)?.range, 0..<2)
        XCTAssertEqual(timeline.word(at: 0.55)?.range, 0..<2, "until the next one starts")
        XCTAssertEqual(timeline.word(at: 0.6)?.range, 3..<5)
        XCTAssertEqual(timeline.word(at: 1.0 + WordTimeline.lastWordHold)?.range, 3..<5)
        XCTAssertNil(timeline.word(at: 1.0 + WordTimeline.lastWordHold + 0.01))
    }

    func testSegmentsKeepNumbersAndCompoundsTogether() {
        let text = Array("It's 3.5 e-book, 4:30 价格12元!")
        let words = WordTimeline.segments(text, 0..<text.count).map { String(text[$0]) }
        XCTAssertEqual(words, ["It's", "3.5", "e-book", "4:30", "价", "格", "12", "元"])
    }
}
