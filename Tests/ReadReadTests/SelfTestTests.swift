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

    /// The cases read through each pipeline (Chinese, US and UK English) with catalog voices, and
    /// the duration band is the smoke test's.
    func testTheCasesCoverEveryPipelineWithinTheSmokeTestsBand() throws {
        let accents = SelfTest.cases.compactMap { Voice.voice(id: $0.voice)?.accent }
        XCTAssertEqual(accents.count, SelfTest.cases.count, "every case's voice is in the catalog")
        XCTAssertEqual(Set(accents), [.zh, .us, .uk])
        XCTAssertTrue(SelfTest.cases.allSatisfy { $0.expectedDuration > 1 })
        // the band catches audio that lost a fifth of its words, and allows a little drift
        XCTAssertFalse(SelfTest.durationBand.contains(0.75))
        XCTAssertTrue(SelfTest.durationBand.contains(0.9) && SelfTest.durationBand.contains(1.2))

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let smoke = try String(contentsOf: root.appending(path: "scripts/smoke-test.sh"), encoding: .utf8)
        func value(_ name: String) throws -> Double? {
            let line = try XCTUnwrap(smoke.split(separator: "\n").first { $0.hasPrefix(name + "=") }, name)
            return Double(line.dropFirst(name.count + 1))
        }
        XCTAssertEqual(try value("DURATION_MIN"), SelfTest.durationBand.lowerBound)
        XCTAssertEqual(try value("DURATION_MAX"), SelfTest.durationBand.upperBound)
    }

    /// A dev environment (no bundle) whose `$READREAD_HOME` is `home`, the cache inside it.
    private func context(home: URL) -> TTSServerPaths.Context {
        TTSServerPaths.Context(
            bundleResources: nil,
            environment: ["READREAD_HOME": home.path, "READREAD_CACHE_DIR": home.appending(path: "cache").path],
            homeDirectory: home.path, currentDirectory: home.path)
    }

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "ReadReadTests-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    /// Without a Defuddle build the page reader check fails with the setup hint, before any web view.
    func testThePageReaderCheckNeedsTheDefuddleBuild() async throws {
        let check = await SelfTest.checkExtraction(context: context(home: try temporaryHome()))
        XCTAssertFalse(check.ok)
        XCTAssertNil(check.script)
        XCTAssertEqual(check.error, LocalExtractorError.bundleMissing.errorDescription)
    }

    /// The pinned Defuddle build turns the check's page into exactly `extractionUnits`, so the self
    /// test (and the smoke test's (b) with it) fails only when the page reader does (WebKit).
    func testThePageReaderCheckReadsItsPage() async throws {
        let script = try WebKitTestGate.defuddleScript()
        let home = try temporaryHome()
        let file = home.appending(path: "defuddle/defuddle.full.js")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: file)
        let check = await SelfTest.checkExtraction(context: context(home: home))
        XCTAssertTrue(check.ok, check.error ?? "")
        XCTAssertEqual(check.title, SelfTest.extractionTitle)
        XCTAssertEqual(check.units, SelfTest.extractionUnits)
        XCTAssertEqual(check.script, file.path(percentEncoded: false))
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
