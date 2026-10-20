import XCTest

@testable import ReadRead

@MainActor
final class AppStateTests: XCTestCase {
    private var synth: FakeSynthesizer!
    private var audio: FakeAudioPlayer!
    private var store: MemoryPreferences!
    private var tempDirectory: URL?

    override func setUp() async throws {
        synth = FakeSynthesizer()
        audio = FakeAudioPlayer()
        store = MemoryPreferences()
    }

    override func tearDown() async throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
    }

    /// Never `AppState()`: that would build the live server and use UserDefaults.standard.
    private func makeState() -> AppState {
        AppState(synthesizer: synth, audioPlayer: audio, defaults: store)
    }

    /// Three ~160-character paragraphs: three chunks at the default 200 limit.
    private let threeParagraphs = (0..<3)
        .map { "Paragraph \($0). " + String(repeating: "word ", count: 30) }
        .joined(separator: "\n\n")

    private func startReading(_ text: String, in state: AppState) {
        state.currentText = text
        state.startReading()
    }

    private func writeTempFile(_ text: String, name: String = "article.txt") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadReadTests-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - splitIntoChunks

    func testSplitSkipsEmptyAndWhitespaceParagraphs() {
        XCTAssertEqual(makeState().splitIntoChunks("Hello\n\n   \n\nWorld", maxLength: 200), ["Hello\n\nWorld"])
    }

    func testSplitMergesShortParagraphsUnderMaxLength() {
        XCTAssertEqual(makeState().splitIntoChunks("abc\n\ndef", maxLength: 20), ["abc\n\ndef"])
    }

    func testSplitStartsNewChunkWhenAddingExceedsMaxLength() {
        XCTAssertEqual(makeState().splitIntoChunks("abcdefghij\n\nklmnopqrst", maxLength: 15), ["abcdefghij", "klmnopqrst"])
    }

    func testSplitThreeParagraphsPartialMerge() {
        // "aaa\n\nbbb" is 8 characters; adding 14 more exceeds 20.
        XCTAssertEqual(makeState().splitIntoChunks("aaa\n\nbbb\n\ncccccccccccccc", maxLength: 20),
                       ["aaa\n\nbbb", "cccccccccccccc"])
    }

    func testSplitFallbackReturnsOriginalTextWhenResultWouldBeEmpty() {
        let text = "   \n\n\t\n\n  "
        XCTAssertEqual(makeState().splitIntoChunks(text, maxLength: 200), [text])
    }

    func testSplitPlainStringWithNoDoubleNewline() {
        let text = "Just a plain sentence with no double newline."
        XCTAssertEqual(makeState().splitIntoChunks(text, maxLength: 200), [text])
    }

    func testSplitBoundaryExactlyAtMaxLength() {
        XCTAssertEqual(makeState().splitIntoChunks("aaaa\n\nbbbb\n\ncccc", maxLength: 10), ["aaaa\n\nbbbb", "cccc"])
    }

    // MARK: - Request size cap

    func testCapLengthLeavesShortTextAlone() {
        XCTAssertEqual(AppState.capLength("short", limit: 10), ["short"])
    }

    func testCapLengthSplitsAtSentenceEndsWithoutLosingText() {
        let text = String(repeating: "This is one sentence of moderate length. ", count: 10)
        let pieces = AppState.capLength(text, limit: 100)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.joined(), text)
        XCTAssertTrue(pieces.allSatisfy { $0.unicodeScalars.count <= 100 })
        XCTAssertTrue(pieces.dropLast().allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasSuffix(".") }, "\(pieces)")
    }

    func testCapLengthCutsAnOverlongSentenceAtWhitespace() {
        let text = String(repeating: "word ", count: 100)
        let pieces = AppState.capLength(text, limit: 64)
        XCTAssertEqual(pieces.joined(), text)
        XCTAssertTrue(pieces.allSatisfy { $0.unicodeScalars.count <= 64 })
        XCTAssertTrue(pieces.dropLast().allSatisfy { $0.hasSuffix(" ") }, "never inside a word: \(pieces)")
    }

    func testCapLengthHardCutsChineseWithoutPunctuation() {
        let text = String(repeating: "汉", count: 250)
        let pieces = AppState.capLength(text, limit: 100)
        XCTAssertEqual(pieces.map(\.count), [100, 100, 50])
        XCTAssertEqual(pieces.joined(), text)
    }

    func testChunksNeverExceedTheRequestCap() {
        let long = String(repeating: "这是一个很长的句子没有任何标点符号", count: 300)  // 5100 characters
        let chunks = makeState().splitIntoChunks(long)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.unicodeScalars.count <= AppState.maxRequestCharacters })
        XCTAssertEqual(chunks.joined(), long)
    }

    // MARK: - Language detection (interim: zh/en only)

    func testDetectionIsConstrainedToChineseAndEnglish() {
        XCTAssertEqual(AppState.languageConstraints, [.simplifiedChinese, .traditionalChinese, .english])
    }

    func testDetectsEnglish() {
        let english = "The quick brown fox jumps over the lazy dog. This is a clearly English paragraph."
        XCTAssertEqual(makeState().detectLanguage(english), .en)
    }

    func testDetectsSimplifiedAndTraditionalChinese() {
        let state = makeState()
        XCTAssertEqual(state.detectLanguage("这是一段中文文本，用于测试语言检测功能。中文是世界上使用人数最多的语言之一。"), .zh)
        XCTAssertEqual(state.detectLanguage("這是一段繁體中文文本，用於測試語言檢測功能。"), .zh)
        XCTAssertEqual(state.detectLanguage("苹果公司今天发布了新的 iPhone 和 MacBook Pro，售价与去年持平。"), .zh)
    }

    func testDroppedLanguagesMapOntoZhOrEn() {
        let state = makeState()
        XCTAssertEqual(state.detectLanguage("これは日本語のテキストです。自然言語処理のテストに使用されています。"), .zh)
        XCTAssertEqual(state.detectLanguage("Este es un texto en español para probar la detección de idioma."), .en)
        XCTAssertEqual(state.detectLanguage("Das ist ein deutscher Text, der die Spracherkennung testen soll."), .en)
    }

    func testUndetectableTextFallsBackToEnglish() {
        XCTAssertEqual(makeState().detectLanguage(""), .en)
        XCTAssertEqual(makeState().detectLanguage("12345"), .en)
    }

    // MARK: - Preferences

    func testInitMigratesOldPreferencesAndRestoresTheLastLanguage() {
        store.set("bm_george", forKey: "voice_en-us")
        store.set(1.4, forKey: "speed_en-us")
        store.set("jf_alpha", forKey: "voice_ja")
        store.set("en", forKey: "last_language")

        let state = makeState()

        XCTAssertEqual(state.selectedLanguage, .en)
        XCTAssertEqual(state.selectedVoice, "bm_george")
        XCTAssertEqual(state.speed, 1.4)
        XCTAssertNil(store.object(forKey: "voice_ja"))
        XCTAssertNil(store.object(forKey: "voice_en-us"))
    }

    func testFreshInstallStartsWithTheChineseDefault() {
        let state = makeState()
        XCTAssertEqual(state.selectedLanguage, .zh)
        XCTAssertEqual(state.selectedVoice, "zf_001")
        XCTAssertEqual(state.speed, 1.0)
        XCTAssertEqual(state.voicesForCurrentLanguage.map(\.language), Array(repeating: .zh, count: 4))
    }

    func testPickerOffersOnlyTheCurrentLanguage() {
        let state = makeState()
        state.applyLanguagePreferences(for: .en)
        XCTAssertEqual(state.voicesForCurrentLanguage.count, 27)
        XCTAssertTrue(state.voicesForCurrentLanguage.allSatisfy { $0.language == .en })
    }

    func testSaveLanguagePreferencesPersistsValues() {
        let state = makeState()
        state.applyLanguagePreferences(for: .en)
        state.selectedVoice = "bf_emma"
        state.speed = 1.5
        state.currentText = "x"  // hasContent

        state.saveLanguagePreferences()

        XCTAssertEqual(store.string(forKey: "voice_en"), "bf_emma")
        XCTAssertEqual(store.object(forKey: "speed_en") as? Double, 1.5)
    }

    func testSaveLanguagePreferencesIsNoOpWithoutContent() {
        let state = makeState()
        state.selectedVoice = "zf_032"
        state.saveLanguagePreferences()
        XCTAssertNil(store.object(forKey: "voice_zh"))
    }

    func testApplyLanguagePreferencesRestoresSavedValuesOrDefaults() {
        store.set("zm_055", forKey: "voice_zh")
        store.set(0.8, forKey: "speed_zh")
        let state = makeState()
        state.applyLanguagePreferences(for: .zh)
        XCTAssertEqual(state.selectedVoice, "zm_055")
        XCTAssertEqual(state.speed, 0.8)
        state.applyLanguagePreferences(for: .en)
        XCTAssertEqual(state.selectedVoice, "af_heart")
        XCTAssertEqual(state.speed, 1.0)
    }

    // MARK: - Opening content

    func testOpenFileDetectsTheLanguageAndUsesItsSavedVoice() async throws {
        store.set("bf_emma", forKey: "voice_en")
        store.set(1.3, forKey: "speed_en")
        let state = makeState()
        let url = try writeTempFile("Hello there. This is an English article about the weather in London.")

        await state.openFile(url: url)
        await waitUntil { state.playbackState == .idle && !synth.requests.isEmpty }

        XCTAssertEqual(synth.prewarmed, [.zh], "prewarm the last language while the content loads")
        XCTAssertEqual(state.selectedLanguage, .en)
        XCTAssertEqual(store.string(forKey: "last_language"), "en")
        let request = try XCTUnwrap(synth.requests.first)
        XCTAssertEqual(request.voiceID, "bf_emma")
        XCTAssertEqual(request.language, .en)
        XCTAssertEqual(request.speed, 1.3)
        XCTAssertEqual(audio.played.count, 1)
        XCTAssertNil(state.errorMessage)
    }

    func testOpenFileWithChineseTextPicksTheChineseVoice() async throws {
        store.set("en", forKey: "last_language")
        let state = makeState()
        let url = try writeTempFile("这是一篇中文文章。今天天气很好，我们去公园散步吧。")

        await state.openFile(url: url)
        await waitUntil { state.playbackState == .idle && !synth.requests.isEmpty }

        XCTAssertEqual(synth.prewarmed, [.en])
        XCTAssertEqual(synth.requests.first?.voiceID, "zf_001")
        XCTAssertEqual(synth.requests.first?.language, .zh)
    }

    func testOpenFileFailureShowsTheErrorAndReturnsToIdle() async {
        let state = makeState()
        await state.openFile(url: URL(fileURLWithPath: "/nonexistent/readread-test.txt"))
        XCTAssertEqual(state.playbackState, .idle)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertFalse(state.errorNeedsSetup)
        XCTAssertEqual(synth.prewarmed, [.zh])
        XCTAssertTrue(synth.requests.isEmpty)
    }

    func testEmptyURLDoesNothing() async {
        let state = makeState()
        state.urlInput = "   "
        await state.fetchURL()
        XCTAssertEqual(state.playbackState, .idle)
        XCTAssertTrue(synth.prewarmed.isEmpty)
    }

    // MARK: - Reading

    func testReadsEveryChunkInOrderAndPrefetches() async {
        let state = makeState()
        startReading(threeParagraphs, in: state)
        XCTAssertEqual(state.textChunks.count, 3)
        await waitUntil { state.playbackState == .idle }
        XCTAssertEqual(synth.requests.map(\.text), state.textChunks)
        XCTAssertEqual(audio.played.count, 3)
        XCTAssertEqual(synth.playbackActiveHistory.first, true)
        XCTAssertEqual(synth.playbackActiveHistory.last, false)
    }

    // MARK: - Errors end in a consistent, recoverable state

    func testSynthesisErrorPausesOnTheFailedChunkWithTheRealMessage() async {
        synth.failures[1] = TTSError.serverFatal("model file missing: voices-v1.0.bin")
        let state = makeState()
        startReading(threeParagraphs, in: state)
        await waitUntil { state.errorMessage != nil }

        XCTAssertEqual(state.errorMessage, "TTS server failed to start: model file missing: voices-v1.0.bin")
        XCTAssertEqual(state.playbackState, .paused)
        XCTAssertEqual(state.currentChunkIndex, 1)
        XCTAssertTrue(state.needsResynthesis)
        XCTAssertTrue(state.errorIsServerFailure)
        XCTAssertFalse(state.errorNeedsSetup)
        XCTAssertEqual(audio.played.count, 1)
        XCTAssertEqual(synth.playbackActiveHistory.last, false, "paused: idle shutdown may count again")
    }

    func testPlayAfterAnErrorSynthesizesTheFailedChunkAgain() async {
        synth.failures[1] = TTSError.connectionFailed("refused")
        let state = makeState()
        startReading(threeParagraphs, in: state)
        await waitUntil { state.errorMessage != nil }

        state.togglePlayPause()
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.playbackState, .playing)
        await waitUntil { state.playbackState == .idle }

        let chunks = state.textChunks
        XCTAssertEqual(synth.requests.map(\.text), [chunks[0], chunks[1], chunks[1], chunks[2]])
        XCTAssertEqual(audio.played.count, 3)
        XCTAssertFalse(state.needsResynthesis)
    }

    func testMissingResourcesShowTheSetupHint() async {
        synth.failures[0] = TTSError.resourcesMissing(["Python runtime (looked for /rr/env/bin/python3)"])
        let state = makeState()
        startReading("Some text.", in: state)
        await waitUntil { state.errorMessage != nil }
        XCTAssertTrue(state.errorNeedsSetup)
        XCTAssertTrue(state.errorMessage?.contains("/rr/env/bin/python3") == true)
    }

    func testAudioFailureIsReportedAndRecoverable() async {
        audio.error = AudioPlaybackError.couldNotStart
        let state = makeState()
        startReading("Some text.", in: state)
        await waitUntil { state.errorMessage != nil }
        XCTAssertEqual(state.errorMessage, "Audio playback could not start.")
        XCTAssertEqual(state.playbackState, .paused)
        XCTAssertFalse(state.errorIsServerFailure)

        audio.error = nil
        state.togglePlayPause()
        await waitUntil { state.playbackState == .idle }
        XCTAssertEqual(audio.played.count, 1)
    }

    func testStopDuringSynthesisCancelsTheRequestWithoutAnError() async {
        synth.hangUntilCancelled()
        let state = makeState()
        startReading(threeParagraphs, in: state)
        await waitUntil { !synth.requests.isEmpty }

        state.stop()

        await waitUntil { synth.cancelledCount == 1 }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.playbackState, .idle)
        XCTAssertEqual(state.currentChunkIndex, 0)
        XCTAssertTrue(audio.played.isEmpty)
    }

    func testSkippingCancelsTheInFlightRequest() async {
        synth.hangUntilCancelled()
        let state = makeState()
        startReading(threeParagraphs, in: state)
        await waitUntil { synth.requests.count == 1 }

        state.nextChunk()

        await waitUntil { synth.cancelledCount == 1 && synth.requests.count == 2 }
        XCTAssertEqual(synth.requests.last?.text, state.textChunks[1])
        XCTAssertNil(state.errorMessage)
        state.stop()
    }

    // MARK: - Retry

    func testRetryRestartsTheServerAfterAServerFailureAndContinues() async {
        synth.failures[0] = TTSError.crashed(status: -9, detail: "")
        let state = makeState()
        startReading(threeParagraphs, in: state)
        await waitUntil { state.errorMessage != nil }

        state.retry()
        XCTAssertNil(state.errorMessage)
        await waitUntil { state.playbackState == .idle && synth.requests.count == 4 }
        XCTAssertEqual(synth.restartCount, 1)
        XCTAssertEqual(audio.played.count, 3)
    }

    func testRetryAfterARequestErrorDoesNotRestartTheServer() async {
        synth.failures[0] = TTSError.server(status: 400, code: "bad_request", message: "text is empty")
        let state = makeState()
        startReading("Some text.", in: state)
        await waitUntil { state.errorMessage != nil }
        XCTAssertEqual(state.errorMessage, "TTS error (bad_request): text is empty")

        state.retry()
        await waitUntil { state.playbackState == .idle && synth.requests.count == 2 }
        XCTAssertEqual(synth.restartCount, 0)
    }

    func testRetryShowsTheRestartFailure() async {
        synth.failures[0] = TTSError.gaveUp(lastError: "boom", logPath: "/logs/tts-server.log")
        synth.restartError = TTSError.serverFatal("still broken")
        let state = makeState()
        startReading("Some text.", in: state)
        await waitUntil { state.errorMessage != nil }

        state.retry()
        await waitUntil { state.errorMessage != nil }
        XCTAssertEqual(state.errorMessage, "TTS server failed to start: still broken")
        XCTAssertEqual(synth.restartCount, 1)
        XCTAssertEqual(synth.requests.count, 1, "no synthesis until the server is back")
    }

    func testStopDuringRetryPlaysNothing() async {
        synth.failures[0] = TTSError.crashed(status: -9, detail: "")
        let state = makeState()
        startReading(threeParagraphs, in: state)
        await waitUntil { state.errorMessage != nil }

        synth.holdRestart = true
        state.retry()
        await waitUntil { synth.restartsWaiting == 1 }
        state.stop()
        synth.releaseRestart()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(state.playbackState, .idle)
        XCTAssertEqual(synth.requests.count, 1, "nothing is synthesized after Stop")
        XCTAssertTrue(audio.played.isEmpty)
        XCTAssertNil(state.retryTask)
    }

    func testPlayDuringRetryReadsTheFailedChunkOnlyOnce() async {
        synth.failures[0] = TTSError.crashed(status: -9, detail: "")
        let state = makeState()
        startReading(threeParagraphs, in: state)
        await waitUntil { state.errorMessage != nil }

        synth.holdRestart = true
        state.retry()
        await waitUntil { synth.restartsWaiting == 1 }
        state.togglePlayPause()  // Play while the server restarts
        synth.releaseRestart()
        await waitUntil { state.playbackState == .idle && audio.played.count == 3 }
        try? await Task.sleep(for: .milliseconds(50))

        let chunks = state.textChunks
        XCTAssertEqual(synth.requests.map(\.text), [chunks[0], chunks[0], chunks[1], chunks[2]])
        XCTAssertEqual(audio.played.count, 3)
    }

    func testRetryDoesNotResumeWhenTheStateMovedOn() async {
        synth.failures[0] = TTSError.crashed(status: -9, detail: "")
        let state = makeState()
        startReading("Some text.", in: state)
        await waitUntil { state.errorMessage != nil }

        synth.holdRestart = true
        state.retry()
        await waitUntil { synth.restartsWaiting == 1 }
        state.retry()  // a second Retry (the error is cleared, so no restart) resumes at once ...
        await waitUntil { state.playbackState == .idle && synth.requests.count == 2 }
        synth.releaseRestart()  // ... and the first, replaced, must not resume again
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(synth.requests.count, 2)
        XCTAssertEqual(audio.played.count, 1)
        XCTAssertEqual(synth.restartCount, 1)
    }

    func testShowLogWithoutALogFileSaysWhereItWouldBe() {
        synth.logFileURL = URL(fileURLWithPath: "/nonexistent/readread/tts-server.log")
        let state = makeState()
        state.showLog()
        XCTAssertEqual(state.errorMessage, "No log yet at /nonexistent/readread/tts-server.log")
    }

    func testShutdownStopsAudioAndTheEngine() {
        let state = makeState()
        state.shutdown()
        XCTAssertEqual(synth.shutdownCount, 1)
        XCTAssertGreaterThanOrEqual(audio.stopCount, 1)
    }

    // MARK: - Computed properties and guards

    func testProgress() {
        let state = makeState()
        XCTAssertEqual(state.progress, 0.0, accuracy: 0.001)
        state.textChunks = ["a", "b", "c", "d"]
        state.currentChunkIndex = 2
        XCTAssertEqual(state.progress, 0.5, accuracy: 0.001)
    }

    func testPlaybackStateFlagsAndEngineActivity() {
        let state = makeState()
        state.playbackState = .playing
        XCTAssertTrue(state.isPlaying)
        XCTAssertFalse(state.isPaused)
        state.playbackState = .paused
        XCTAssertFalse(state.isPlaying)
        XCTAssertTrue(state.isPaused)
        state.playbackState = .idle
        XCTAssertFalse(state.isPlaying || state.isPaused)
        XCTAssertEqual(synth.playbackActiveHistory, [true, false, false])
    }

    func testHasContentReflectsCurrentText() {
        let state = makeState()
        XCTAssertFalse(state.hasContent)
        state.currentText = "something"
        XCTAssertTrue(state.hasContent)
    }

    func testNextChunkIsNoOpAtLastChunk() {
        let state = makeState()
        state.textChunks = ["a", "b", "c"]
        state.currentChunkIndex = 2
        state.nextChunk()
        XCTAssertEqual(state.currentChunkIndex, 2)
        XCTAssertTrue(synth.requests.isEmpty)
    }

    func testPreviousChunkIsNoOpAtFirstChunk() {
        let state = makeState()
        state.textChunks = ["a", "b", "c"]
        state.previousChunk()
        XCTAssertEqual(state.currentChunkIndex, 0)
        XCTAssertTrue(synth.requests.isEmpty)
    }

    func testStopSetsIdleAndResetsIndex() {
        let state = makeState()
        state.textChunks = ["a", "b", "c"]
        state.currentChunkIndex = 2
        state.playbackState = .paused
        state.stop()
        XCTAssertEqual(state.playbackState, .idle)
        XCTAssertEqual(state.currentChunkIndex, 0)
        XCTAssertFalse(state.needsResynthesis)
    }
}
