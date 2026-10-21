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

    // MARK: - --engine qwen

    func testTheEngineArgument() throws {
        XCTAssertEqual(try SelfTest.engine(arguments: []), .kokoro)
        XCTAssertEqual(try SelfTest.engine(arguments: ["--self-test"]), .kokoro)
        XCTAssertEqual(try SelfTest.engine(arguments: ["--self-test", "--engine", "qwen"]), .qwen)
        XCTAssertEqual(try SelfTest.engine(arguments: ["--engine", "qwen", "--self-test"]), .qwen)
        XCTAssertEqual(try SelfTest.engine(arguments: ["--self-test", "--engine=qwen"]), .qwen)
        XCTAssertEqual(try SelfTest.engine(arguments: ["--self-test", "--engine", "kokoro"]), .kokoro)
        XCTAssertEqual(try SelfTest.engine(arguments: ["--engine", "qwen", "--engine=kokoro"]), .kokoro, "the last one")
        XCTAssertThrowsError(try SelfTest.engine(arguments: ["--self-test", "--engine"])) { error in
            XCTAssertEqual(error as? SelfTest.ArgumentError,
                           SelfTest.ArgumentError(message: "--engine needs a value: kokoro or qwen"))
        }
        for bad in [["--engine", "1.7b"], ["--engine="], ["--engine", "Qwen"], ["--engine", "--self-test"]] {
            XCTAssertThrowsError(try SelfTest.engine(arguments: bad), "\(bad)") { error in
                XCTAssertTrue((error as? SelfTest.ArgumentError)?.message.hasPrefix("unknown engine") == true, "\(error)")
            }
        }
    }

    func testABadEngineArgumentExitsWithStatusTwo() async {
        let status = await SelfTest.run(arguments: ["--self-test", "--engine", "piper"])
        XCTAssertEqual(status, 2)
    }

    func testWithoutAnHQInstallTheQwenSelfTestFailsAtOnce() async throws {
        let root = try temporaryHome()
        let environment = ServerEnvironment(
            launcher: FakeLauncher(), fileSystem: LocalFileSystem(),
            pathContext: TTSServerPaths.Context(
                bundleResources: nil, environment: ["READREAD_HQ_HOME": root.path + "/hq"],
                homeDirectory: root.path, currentDirectory: root.path),
            directories: RuntimeDirectories(logDirectory: root.path + "/logs", cacheDirectory: root.path + "/cache",
                                            userLexicon: root.path + "/lexicon.json"),
            now: { 0 }, sleep: { _ in }, makeToken: { "unused" })
        let status = await SelfTest.runQwen(environment: environment)
        XCTAssertEqual(status, 1)
    }

    func testTheQwenCasesUseTheQwenVoices() {
        XCTAssertEqual(SelfTest.qwenCases.map(\.voice), Voice.qwen.map(\.id))
        XCTAssertEqual(Set(SelfTest.qwenCases.compactMap { id in Voice.qwen.first { $0.id == id.voice }?.language }),
                       [.zh, .en])
        XCTAssertEqual(SelfTest.qwenCases.map(\.text), SelfTest.cases.prefix(2).map(\.text), "the Kokoro texts")
        XCTAssertTrue(SelfTest.qwenCases.allSatisfy { $0.expectedDuration > 1 })
        // Runaway generations (about 2.5× long) and cut-off ones (about 0.3×) fail; sampling drift passes.
        XCTAssertFalse(SelfTest.qwenDurationBand.contains(0.3))
        XCTAssertFalse(SelfTest.qwenDurationBand.contains(2.5))
        XCTAssertTrue(SelfTest.qwenDurationBand.contains(0.8) && SelfTest.qwenDurationBand.contains(1.3))
        XCTAssertEqual(SelfTest.qwenPlaybackSpeed, 1.25)
        XCTAssertGreaterThan(SelfTest.qwenOverallTimeout, ServerPolicy.qwen.startTimeout * 2)
    }

    func testThePlaybackRateMirrorsThePlayer() {
        XCTAssertEqual(SelfTest.playbackRate(userSpeed: 1.25, synthSpeed: 1.0), 1.25, accuracy: 1e-9)
        XCTAssertEqual(SelfTest.playbackRate(userSpeed: 1.25, synthSpeed: 1.25), 1, accuracy: 1e-9)
        XCTAssertEqual(SelfTest.playbackRate(userSpeed: 0.75, synthSpeed: 1.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SelfTest.playbackRate(userSpeed: 100, synthSpeed: 1), 4)
        XCTAssertEqual(SelfTest.playbackRate(userSpeed: 0.01, synthSpeed: 1), 0.25)
        XCTAssertEqual(SelfTest.playbackRate(userSpeed: 1, synthSpeed: 0), 4)
    }

    /// A PCM16 mono 24 kHz WAV of `seconds` of a 440 Hz tone.
    private nonisolated static func tone(_ seconds: Double) -> Data {
        let rate = 24_000.0
        let samples = (0..<Int((seconds * rate).rounded())).map { 0.5 * Float(sin(2 * Double.pi * 440 * Double($0) / rate)) }
        return AppleSpeechSynthesizer.wav(samples, sampleRate: Int(rate))
    }

    func testOfflineRenderingAtRateOneComparesTheSamples() throws {
        let items = [AudioItem(id: 0, wav: Self.tone(0.6), synthSpeed: 1.0, pause: 0.25),
                     AudioItem(id: 1, wav: Self.tone(0.4), synthSpeed: 1.0, pause: 0.5)]
        let rendered = try SelfTest.renderOffline(items)
        XCTAssertEqual(rendered.seconds, 1.75, accuracy: SelfTest.playbackTolerance)
        XCTAssertLessThan(try XCTUnwrap(rendered.maxDifference), 0.01)
        // Kokoro made it at the speed: rate 1, still compared sample by sample.
        let honoured = items.map { AudioItem(id: $0.id, wav: $0.wav, synthSpeed: 1.25, pause: $0.pause) }
        let fast = try SelfTest.renderOffline(honoured, userSpeed: 1.25)
        XCTAssertEqual(fast.seconds, 1.75, accuracy: SelfTest.playbackTolerance)
        XCTAssertNotNil(fast.maxDifference)
    }

    func testOfflineRenderingTimeStretchesAudioMadeAtOne() throws {
        let items = [AudioItem(id: 0, wav: Self.tone(1.0), synthSpeed: 1.0, pause: 0.25),
                     AudioItem(id: 1, wav: Self.tone(0.6), synthSpeed: 1.0, pause: 0.5)]
        let rendered = try SelfTest.renderOffline(items, userSpeed: 1.25)
        XCTAssertEqual(rendered.seconds, 2.35 / 1.25, accuracy: SelfTest.stretchedPlaybackTolerance)
        XCTAssertNil(rendered.maxDifference, "stretched samples differ by design")
        XCTAssertLessThan(rendered.audibleSeconds, 2.0)
    }

    func testThePlaybackCheckWithAnEngineThatMakesAudioAtOne() async throws {
        let engine = FakeSynthesizer()
        engine.engineID = QwenModel.engineID
        engine.honoursSpeed = false
        engine.handler = { request in
            let seconds = min(2.0, 0.3 + Double(request.text.count) * 0.02)
            return SynthesisResult(wav: SelfTestTests.tone(seconds), duration: seconds, sampleRate: 24_000, silent: false,
                                   sentences: [], tokens: [], requestID: nil, synthSpeed: 1.0)
        }
        let check = await SelfTest.checkPlayback(service: engine, speed: SelfTest.qwenPlaybackSpeed) { language in
            Voice.qwen.first { $0.language == language }!
        }
        XCTAssertTrue(check.ok, check.error ?? "")
        XCTAssertEqual(check.speed, 1.25)
        XCTAssertNil(check.maxDifference)
        XCTAssertEqual(engine.requests.count, SelfTest.playedUnits)
        // Requests carry the speed on the slider's 0.1 grid; the player plays at 1.25 itself.
        let speeds: [Double] = engine.requests.map(\.speed)
        let voices: Set<String> = Set(engine.requests.map(\.voiceID))
        XCTAssertEqual(speeds, [Double](repeating: SynthesisRequest.normalizedSpeed(1.25), count: SelfTest.playedUnits))
        XCTAssertTrue(voices.isSubset(of: ["serena", "aiden"]), "\(voices)")

        // An engine that says it never honours the speed but made audio at it is caught.
        let liar = FakeSynthesizer()
        liar.honoursSpeed = false
        liar.engineID = QwenModel.engineID
        liar.handler = { request in FakeSynthesizer.result(text: request.text, synthSpeed: request.speed) }
        let caught = await SelfTest.checkPlayback(service: liar, speed: 1.25)
        XCTAssertFalse(caught.ok)
        XCTAssertEqual(caught.error, "qwen-1.7b made audio at speed 1.3, not 1.0")
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
