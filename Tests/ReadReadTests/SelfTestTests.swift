import XCTest

@testable import ReadRead

@MainActor
final class SelfTestTests: XCTestCase {
    private func span(_ text: String, _ start: Double = 0.1, _ end: Double = 0.4) -> TimedSpan {
        TimedSpan(text: text, start: start, end: end)
    }

    func testEveryWordOfTheTextMustBeTimed() {
        let text = "Hello from ReadRead. This blorptastic test costs 12 dollars."
        let all = ["Hello", "from", "Read", "Read", "This", "blorptastic", "test", "costs", "12", "dollars"].map { span($0) }
        XCTAssertEqual(SelfTest.untimedWords(text, tokens: all, duration: 3), [])
        // espeak-ng's data missing: the out-of-vocabulary word comes back without a token
        let dropped = all.filter { $0.text != "blorptastic" }
        XCTAssertEqual(SelfTest.untimedWords(text, tokens: dropped, duration: 3), ["blorptastic"])
        // a token outside the audio does not count, nor does one without a duration
        let late = all.map { $0.text == "dollars" ? span("dollars", 3.5, 3.9) : $0 }
        XCTAssertEqual(SelfTest.untimedWords(text, tokens: late, duration: 3), ["dollars"])
        let instant = all.map { $0.text == "test" ? span("test", 1.2, 1.2) : $0 }
        XCTAssertEqual(SelfTest.untimedWords(text, tokens: instant, duration: 3), ["test"])
    }

    func testChineseIsCheckedCharacterByCharacter() {
        let text = "你好，欢迎使用 ReadRead 朗读。重1.5公斤。"
        let tokens = ["你好", "欢迎", "使用", "ReadRead", "朗读", "重", "一点五", "公斤"].map { span($0) }
        XCTAssertEqual(SelfTest.untimedWords(text, tokens: tokens, duration: 3), [])
        XCTAssertEqual(SelfTest.untimedWords(text, tokens: Array(tokens.prefix(3)), duration: 3),
                       ["ReadRead", "朗", "读", "重", "公", "斤"])
    }

    func testTheCasesHaveExpectedDurations() {
        XCTAssertEqual(SelfTest.cases.map(\.voice), ["zf_001", "af_heart", "bf_emma"])
        XCTAssertTrue(SelfTest.cases.allSatisfy { $0.expectedDuration > 1 })
        // the band catches audio that lost a fifth of its words, and allows a little drift
        XCTAssertFalse(SelfTest.durationBand.contains(0.75))
        XCTAssertTrue(SelfTest.durationBand.contains(0.9) && SelfTest.durationBand.contains(1.2))
    }

    func testLogProblemsAreReadFromWhereThisRunStarted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReadReadTests-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let earlier = "Can't read dictionary file: '/old/espeak-ng-data/en_dict'\n"
        try Data(earlier.utf8).write(to: url)
        let offset = UInt64(earlier.utf8.count)
        XCTAssertEqual(SelfTest.logProblems(path: url.path, since: offset), [])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ok\nWARNING phonemizer: words count mismatch on 100.0% of the lines (1/1)\n".utf8))
        try handle.close()
        XCTAssertEqual(SelfTest.logProblems(path: url.path, since: offset),
                       ["WARNING phonemizer: words count mismatch on 100.0% of the lines (1/1)"])
        // rotated since the run started (the file is now shorter than the offset): read it all
        try Data("Can't read dictionary file: x\n".utf8).write(to: url)
        XCTAssertEqual(SelfTest.logProblems(path: url.path, since: offset), ["Can't read dictionary file: x"])
    }
}
