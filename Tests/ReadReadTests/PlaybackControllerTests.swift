import XCTest

@testable import ReadRead

/// Every state transition of the player, with a scripted synthesizer, an output the test
/// finishes by hand and a sleeper the test releases (speed debounce, position saves).
@MainActor
final class PlaybackControllerTests: XCTestCase {
    private var synth: FakeSynthesizer!
    private var output: FakeAudioOutput!
    private var positions: MemoryPositions!
    private var nowPlaying: FakeNowPlaying!
    private var sleeper: TestSleeper!

    override func setUp() async throws {
        synth = FakeSynthesizer()
        output = FakeAudioOutput()
        positions = MemoryPositions()
        nowPlaying = FakeNowPlaying()
        sleeper = TestSleeper()
        sleeper.set(.gated, for: PlaybackController.speedDebounce)
        sleeper.set(.gated, for: PlaybackController.positionSaveDelay)
    }

    private func makePlayer() -> PlaybackController {
        let sleeper = self.sleeper!
        return PlaybackController(
            synthesizer: synth, output: output, positions: positions, nowPlaying: nowPlaying,
            sleep: { try await sleeper.sleep($0) }, now: { Date(timeIntervalSince1970: 1_000) })
    }

    /// One block per unit; a nil language is a script ReadRead does not read.
    private func document(_ units: [(String, SpeechLanguage?)], source: DocumentSource = .text,
                          sourceLabel: String = "") -> ReadingDocument {
        var blocks: [ReadingBlock] = []
        var speechUnits: [SpeechUnit] = []
        for (index, (text, language)) in units.enumerated() {
            speechUnits.append(SpeechUnit(id: index, block: index, range: 0..<text.count, speakText: text,
                                          language: language, kind: .sentence, endsBlock: index % 2 == 1))
            blocks.append(ReadingBlock(kind: .paragraph, text: text, units: index..<index + 1))
        }
        return ReadingDocument(title: units.first?.0 ?? "", source: source, sourceLabel: sourceLabel,
                               blocks: blocks, units: speechUnits, detectedLanguage: .zh)
    }

    private func chinese(_ count: Int, source: DocumentSource = .text) -> ReadingDocument {
        document((0..<count).map { ("第\($0)句。", .zh) }, source: source)
    }

    private func texts(_ requests: [SynthesisRequest]) -> [String] { requests.map(\.text) }

    /// Open `document` playing and wait until unit 0 plays and the prefetch window is full.
    private func startPlaying(_ document: ReadingDocument, _ player: PlaybackController,
                              settings: PlaybackSettings = PlaybackSettings(), requests: Int = 4) async {
        player.open(document, settings: settings, autoplay: true)
        await waitUntil { player.state == .playing && self.synth.requests.count == requests && self.synth.held == 0 }
        await settle()
    }

    /// Let pending tasks run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
    }

    // MARK: - Opening and playing

    func testOpenWithoutAutoplayIsIdle() async {
        let player = makePlayer()
        player.open(chinese(3), settings: PlaybackSettings(), autoplay: false)
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.currentUnit, 0)
        XCTAssertEqual(player.readableCount, 3)
        XCTAssertEqual(player.readablePosition, 1)
        await settle()
        XCTAssertTrue(synth.requests.isEmpty, "nothing is synthesized before Play")
        XCTAssertEqual(nowPlaying.last?.state, .stopped)
    }

    func testPlayBuffersThenPlaysAndPrefetchesOneRequestAtATime() async {
        synth.holding = true
        let player = makePlayer()
        player.open(chinese(6), settings: PlaybackSettings(), autoplay: true)
        XCTAssertEqual(player.state, .buffering)
        await waitUntil { self.synth.held == 1 }
        XCTAssertEqual(texts(synth.requests), ["第0句。"])
        XCTAssertEqual(synth.playbackActiveHistory.last, true, "buffering counts as playing for the idle timer")

        synth.release()
        await waitUntil { player.state == .playing }
        XCTAssertEqual(output.playedIDs, [0])
        XCTAssertEqual(output.played.first?.pause, 0.25)
        await waitUntil { self.synth.held == 1 }
        XCTAssertEqual(synth.requests.count, 2, "one request at a time")

        synth.release(3)
        await waitUntil { self.synth.requests.count == 4 && self.synth.held == 0 }
        await settle()
        XCTAssertEqual(texts(synth.requests), ["第0句。", "第1句。", "第2句。", "第3句。"], "three units ahead, no more")
        synth.holding = false
    }

    func testAFinishedUnitIsFollowedByTheNextFromTheCache() async {
        let player = makePlayer()
        await startPlaying(chinese(6), player)
        output.finish()
        XCTAssertEqual(player.currentUnit, 1)
        XCTAssertEqual(player.state, .playing, "cached: no buffering between units")
        XCTAssertEqual(output.playedIDs, [0, 1])
        XCTAssertEqual(output.played[1].pause, 0.5, "a block's last unit pauses longer")
        await waitUntil { self.synth.requests.count == 5 }
        XCTAssertEqual(synth.requests.last?.text, "第4句。", "the window moves on")
    }

    func testNextAndPreviousReuseTheCache() async {
        let player = makePlayer()
        await startPlaying(chinese(6), player)
        player.next()
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(output.playedIDs, [0, 1])
        player.previous()
        XCTAssertEqual(output.playedIDs, [0, 1, 0])
        XCTAssertEqual(player.currentUnit, 0)
        await waitUntil { self.synth.requests.count == 5 }
        await settle()
        XCTAssertEqual(synth.requests.count, 5)
        XCTAssertEqual(Set(texts(synth.requests)).count, 5, "no unit is synthesized twice")
        player.previous()
        XCTAssertEqual(player.currentUnit, 0, "nothing before the first unit")
    }

    func testUnitsInOtherScriptsAreShownButSkipped() async {
        let player = makePlayer()
        let mixed = document([("第一句。", .zh), ("これは日本語です。", nil), ("第三句。", .zh)])
        await startPlaying(mixed, player, requests: 2)
        XCTAssertEqual(texts(synth.requests), ["第一句。", "第三句。"])
        XCTAssertEqual(player.readableCount, 2)
        output.finish()
        XCTAssertEqual(player.currentUnit, 2)
        XCTAssertEqual(output.playedIDs, [0, 2])
        XCTAssertEqual(player.readablePosition, 2)
    }

    func testADocumentWithNothingReadableFinishesAtOnce() {
        let player = makePlayer()
        player.open(document([("これは日本語です。", nil)]), settings: PlaybackSettings(), autoplay: true)
        XCTAssertEqual(player.state, .finished)
        XCTAssertTrue(synth.requests.isEmpty)
    }

    func testOpeningAnotherDocumentReplacesTheFirst() async {
        let player = makePlayer()
        await startPlaying(chinese(4), player)
        let english = document([("One.", .en), ("Two.", .en)])
        player.open(english, settings: PlaybackSettings(), autoplay: true)
        XCTAssertEqual(player.cache.count, 0)
        XCTAssertNil(output.current)
        await waitUntil { player.state == .playing && self.synth.requests.count == 6 }
        XCTAssertEqual(texts(synth.requests.suffix(2)), ["One.", "Two."])
        XCTAssertEqual(synth.requests.last?.voiceID, "af_heart")
        XCTAssertEqual(player.document, english)
    }

    // MARK: - Pause, stop, close

    func testPauseAndResume() async {
        let player = makePlayer()
        await startPlaying(chinese(4), player)
        player.pause()
        XCTAssertEqual(player.state, .paused)
        XCTAssertTrue(output.isPaused)
        XCTAssertEqual(synth.playbackActiveHistory.last, false, "paused: the idle timer runs")
        player.play()
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(output.resumeCount, 1)
        XCTAssertEqual(output.playedIDs, [0], "resumed, not started again")
        player.toggle()
        XCTAssertEqual(player.state, .paused)
        player.toggle()
        XCTAssertEqual(player.state, .playing)
    }

    func testPauseWhileBufferingStaysPausedWhenTheAudioArrives() async {
        synth.holding = true
        let player = makePlayer()
        player.open(chinese(4), settings: PlaybackSettings(), autoplay: true)
        await waitUntil { self.synth.held == 1 }
        player.pause()
        XCTAssertEqual(player.state, .paused)
        synth.release()
        // The audio arrives; the next unit's prefetch is then waiting.
        await waitUntil { self.synth.requests.count == 2 && self.synth.held == 1 }
        XCTAssertEqual(player.state, .paused)
        XCTAssertTrue(output.played.isEmpty, "nothing plays while paused")
        player.play()
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(output.playedIDs, [0])
        synth.holding = false
    }

    /// Pause while buffering stops the output too (an engine left running after the previous
    /// unit keeps the Mac from idle sleep); Play then buffers again on the same request.
    func testPlayAfterPausingWhileBufferingBuffersAgain() async {
        synth.holding = true
        let player = makePlayer()
        player.open(chinese(3), settings: PlaybackSettings(), autoplay: true)
        await waitUntil { self.synth.held == 1 }
        player.pause()
        XCTAssertEqual(player.state, .paused)
        XCTAssertEqual(output.pauseCount, 1, "the output is paused while buffering too")
        player.play()
        XCTAssertEqual(player.state, .buffering)
        XCTAssertEqual(synth.requests.count, 1, "the request in flight is kept")
        synth.holding = false
        synth.release()
        await waitUntil { player.state == .playing }
        XCTAssertEqual(output.playedIDs, [0])
    }

    func testStopWhilePausedIsIdle() async {
        let player = makePlayer()
        await startPlaying(chinese(4), player)
        player.pause()
        let stops = output.stopCount
        player.stop()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(output.stopCount, stops + 1)
        player.play()
        XCTAssertEqual(player.state, .playing, "from the cache")
        XCTAssertEqual(output.playedIDs, [0, 0], "the sentence again")
    }

    func testAResumeThatFailsIsAFailure() async {
        let player = makePlayer()
        await startPlaying(chinese(4), player)
        player.pause()
        output.resumeError = AudioOutputError.engine("device busy")
        player.play()
        XCTAssertEqual(player.state, .failed("Audio playback could not start: device busy"))
    }

    func testStopKeepsThePositionAndPlayStartsTheSentenceAgain() async {
        let player = makePlayer()
        let doc = chinese(6)
        await startPlaying(doc, player)
        output.finish()
        await waitUntil { self.synth.requests.count == 5 }
        await settle()
        player.stop()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.currentUnit, 1)
        XCTAssertNil(output.current)
        XCTAssertEqual(positions.positions[doc.positionKey]?.unit, 1, "saved at once on stop")
        let requests = synth.requests.count
        player.play()
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(output.playedIDs, [0, 1, 1])
        await settle()
        XCTAssertEqual(synth.requests.count, requests, "from the cache")
    }

    func testJumpingWhilePausedStaysPaused() async {
        let player = makePlayer()
        await startPlaying(chinese(6), player)
        player.pause()
        player.next()
        XCTAssertEqual(player.state, .paused)
        XCTAssertEqual(player.currentUnit, 1)
        XCTAssertNil(output.current)
        XCTAssertEqual(output.playedIDs, [0])
        player.play()
        XCTAssertEqual(output.playedIDs, [0, 1])
        XCTAssertEqual(player.state, .playing)
    }

    func testCloseSavesThePositionAndForgetsTheDocument() async {
        let player = makePlayer()
        let doc = chinese(6)
        await startPlaying(doc, player)
        output.finish()
        player.close()
        XCTAssertNil(player.document)
        XCTAssertEqual(player.state, .idle)
        XCTAssertNil(output.current)
        XCTAssertEqual(player.cache.count, 0)
        XCTAssertEqual(positions.positions[doc.positionKey]?.unit, 1)
        XCTAssertGreaterThan(nowPlaying.clearCount, 0)
    }

    // MARK: - Jumps and in-flight work

    func testAJumpCancelsWorkOutsideTheWindow() async {
        synth.hangUntilCancelled()
        let player = makePlayer()
        player.open(chinese(12), settings: PlaybackSettings(), autoplay: true)
        await waitUntil { self.synth.requests.count == 1 }
        player.seek(to: 8)
        await waitUntil { self.synth.cancelledCount == 1 && self.synth.requests.count == 2 }
        XCTAssertEqual(synth.requests.last?.text, "第8句。")
        XCTAssertEqual(player.state, .buffering)
        XCTAssertEqual(player.currentUnit, 8)
    }

    func testAJumpInsideTheWindowKeepsTheRequestInFlight() async {
        synth.holding = true
        let player = makePlayer()
        player.open(chinese(12), settings: PlaybackSettings(), autoplay: true)
        await waitUntil { self.synth.held == 1 }
        synth.release()
        await waitUntil { player.state == .playing && self.synth.held == 1 }  // unit 1's prefetch
        player.next()
        XCTAssertEqual(player.state, .buffering)
        await settle()
        XCTAssertEqual(synth.cancelledCount, 0)
        XCTAssertEqual(synth.requests.count, 2, "the new current unit was already being synthesized")
        synth.release()
        await waitUntil { player.state == .playing }
        XCTAssertEqual(output.playedIDs, [0, 1])
        synth.holding = false
    }

    func testSeekClampsAndMovesToAReadableUnit() {
        let player = makePlayer()
        player.open(document([("一。", .zh), ("ア。", nil), ("イ。", nil), ("四。", .zh)]), settings: PlaybackSettings(),
                    autoplay: false)
        player.seek(to: 1)
        XCTAssertEqual(player.currentUnit, 3)
        player.seek(to: -5)
        XCTAssertEqual(player.currentUnit, 0)
        player.seek(to: 99)
        XCTAssertEqual(player.currentUnit, 3)
        XCTAssertEqual(player.state, .idle)
        XCTAssertTrue(synth.requests.isEmpty)
    }

    // MARK: - Speed (R1-06, H6)

    func testSpeedIsInstantAndResynthesisWaitsUntilTheSliderRests() async {
        let player = makePlayer()
        await startPlaying(chinese(6), player)
        for speed in [1.1, 1.2, 1.3, 1.4, 1.5] { player.userSetSpeed(speed) }
        XCTAssertEqual(output.userSpeed, 1.5, "the rate follows the slider at once")
        XCTAssertEqual(player.settings.speed, 1.5)
        await settle()
        XCTAssertEqual(synth.requests.count, 4, "no requests while the slider moves")
        XCTAssertEqual(output.playedIDs, [0], "the playing sentence goes on")

        // Five debounce sleeps started; the first four were cancelled by the next move.
        await waitUntil { self.sleeper.waiting(for: PlaybackController.speedDebounce) == 5 }
        sleeper.release(PlaybackController.speedDebounce)
        await waitUntil { self.synth.requests.count == 7 }
        XCTAssertEqual(texts(synth.requests.suffix(3)), ["第1句。", "第2句。", "第3句。"])
        XCTAssertTrue(synth.requests.suffix(3).allSatisfy { $0.speed == 1.5 })
        await settle()
        XCTAssertEqual(synth.requests.count, 7, "one wave; the playing sentence is not synthesized again")

        output.finish()
        XCTAssertEqual(output.played.last?.synthSpeed, 1.5, "the next unit has audio at the new speed")
    }

    func testDuringTheDebounceTheOldSpeedsAudioPlaysWithoutAStall() async {
        let player = makePlayer()
        await startPlaying(chinese(6), player)
        player.userSetSpeed(1.5)
        output.finish()
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(output.played.last?.synthSpeed, 1.0, "time-stretched until new audio exists")
        await waitUntil { self.sleeper.waiting(for: PlaybackController.speedDebounce) == 1 }
        await settle()
        XCTAssertEqual(synth.requests.count, 4, "nothing is requested while the slider may still move")
        sleeper.release(PlaybackController.speedDebounce)
        await waitUntil { self.synth.requests.count == 7 }
        await settle()
        XCTAssertEqual(synth.requests.count, 7, "the playing unit keeps its time-stretched audio")
        XCTAssertEqual(texts(synth.requests.suffix(3)), ["第2句。", "第3句。", "第4句。"])
    }

    func testDuringTheDebounceOnlyTheCurrentUnitIsRequested() async {
        let player = makePlayer()
        await startPlaying(chinese(12), player)
        player.userSetSpeed(1.5)
        player.seek(to: 9)
        await waitUntil { player.state == .playing }
        XCTAssertEqual(synth.requests.last?.text, "第9句。")
        XCTAssertEqual(synth.requests.last?.speed, 1.5)
        await settle()
        XCTAssertEqual(synth.requests.count, 5, "no prefetch until the slider rests")
    }

    func testAnEngineWithoutSpeedNeverResynthesizes() async {
        synth.honoursSpeed = false
        let player = makePlayer()
        await startPlaying(chinese(6), player, settings: PlaybackSettings(speed: 1.3))
        XCTAssertTrue(synth.requests.allSatisfy { $0.speed == 1.0 }, "always synthesized at 1.0")
        XCTAssertEqual(output.userSpeed, 1.3)
        player.userSetSpeed(1.6)
        XCTAssertEqual(output.userSpeed, 1.6)
        await settle()
        XCTAssertFalse(sleeper.calls.contains(PlaybackController.speedDebounce))
        XCTAssertEqual(synth.requests.count, 4)
    }

    // MARK: - Voice and language (R1-08, R4-08)

    func testAVoiceChangeWhilePlayingRestartsTheSentenceWithTheNewVoice() async throws {
        let player = makePlayer()
        await startPlaying(chinese(6), player)
        player.userSetVoice(try XCTUnwrap(Voice.voice(id: "zm_009")))
        await waitUntil { self.output.played.count == 2 }
        XCTAssertEqual(output.playedIDs, [0, 0])
        XCTAssertEqual(synth.requests[4].voiceID, "zm_009")
        XCTAssertEqual(synth.requests[4].text, "第0句。")
        XCTAssertEqual(player.state, .playing)
        await waitUntil { self.synth.requests.count == 8 }
        XCTAssertTrue(player.cache.keys.allSatisfy { $0.voiceID == "zm_009" }, "the old voice's audio is gone")
    }

    func testAVoiceChangeWhilePausedStaysPaused() async throws {
        let player = makePlayer()
        await startPlaying(chinese(6), player)
        player.pause()
        player.userSetVoice(try XCTUnwrap(Voice.voice(id: "zm_009")))
        XCTAssertEqual(player.state, .paused)
        // The current unit first, then the three ahead again, all with the new voice.
        await waitUntil { self.synth.requests.count == 8 }
        XCTAssertEqual(synth.requests[4].text, "第0句。", "the current unit is synthesized with the new voice meanwhile")
        XCTAssertEqual(texts(Array(synth.requests[5...])), ["第1句。", "第2句。", "第3句。"])
        XCTAssertTrue(synth.requests[4...].allSatisfy { $0.voiceID == "zm_009" })
        await settle()
        XCTAssertEqual(synth.requests.count, 8)
        XCTAssertEqual(output.playedIDs, [0])
        XCTAssertEqual(player.state, .paused)
        player.play()
        XCTAssertEqual(output.playedIDs, [0, 0])
        XCTAssertEqual(player.state, .playing)
    }

    func testAVoiceForTheOtherLanguageChangesNothingThatPlays() async throws {
        let player = makePlayer()
        await startPlaying(chinese(6), player)
        player.userSetVoice(try XCTUnwrap(Voice.voice(id: "bf_emma")))
        await settle()
        XCTAssertEqual(output.playedIDs, [0])
        XCTAssertEqual(synth.requests.count, 4)
        XCTAssertEqual(player.settings.voice(for: .en).id, "bf_emma")
    }

    func testTheLanguageChoiceReadsEveryUnitInThatLanguage() async {
        let player = makePlayer()
        let mixed = document([("Hello there.", .en), ("第二句。", .zh), ("Third one.", .en)])
        await startPlaying(mixed, player, requests: 3)
        XCTAssertEqual(synth.requests.map(\.voiceID), ["af_heart", "zf_001", "af_heart"])
        player.userSetLanguageChoice(.zh)
        await waitUntil { self.output.played.count == 2 && self.synth.requests.count == 5 }
        XCTAssertEqual(output.playedIDs, [0, 0], "the sentence starts again in Chinese")
        XCTAssertEqual(synth.requests[3].text, "Hello there.")
        XCTAssertEqual(synth.requests[3].voiceID, "zf_001")
        XCTAssertEqual(synth.requests[4].text, "Third one.", "the Chinese unit's audio is reused")
        XCTAssertEqual(player.settings.languageChoice, .zh)
    }

    func testRestoringSettingsNeverRestartsAudio() async throws {
        let player = makePlayer()
        await startPlaying(chinese(6), player)
        let stops = output.stopCount
        var settings = PlaybackSettings(speed: 1.2)
        settings.voices[.zh] = try XCTUnwrap(Voice.voice(id: "zm_009"))
        player.restore(settings: settings)
        XCTAssertEqual(output.playedIDs, [0])
        XCTAssertEqual(output.stopCount, stops)
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(output.userSpeed, 1.2)
        await waitUntil { self.synth.requests.count == 7 }
        XCTAssertTrue(synth.requests.suffix(3).allSatisfy { $0.voiceID == "zm_009" && $0.speed == 1.2 },
                      "the next units use the restored settings")
        XCTAssertFalse(sleeper.calls.contains(PlaybackController.speedDebounce))
    }

    // MARK: - Errors and retry

    func testAFailureStopsOnTheFailedUnitAndRetryRestartsTheServer() async {
        synth.failures[0] = TTSError.crashed(status: -9, detail: "")
        let player = makePlayer()
        player.open(chinese(3), settings: PlaybackSettings(), autoplay: true)
        await waitUntil { player.state.isFailed }
        XCTAssertEqual(player.state, .failed("TTS server stopped unexpectedly (signal 9)."))
        XCTAssertEqual(player.failureCount, 1)
        XCTAssertEqual((player.lastError as? TTSError)?.isServerFailure, true)
        XCTAssertEqual(synth.playbackActiveHistory.last, false)
        XCTAssertEqual(nowPlaying.last?.state, .stopped)

        player.retry()
        XCTAssertEqual(player.state, .buffering)
        await waitUntil { player.state == .playing }
        XCTAssertEqual(synth.restartCount, 1)
        XCTAssertEqual(output.playedIDs, [0])
        XCTAssertNil(player.lastError)
    }

    func testRetryAfterARequestErrorDoesNotRestartTheServer() async {
        synth.failures[0] = TTSError.server(status: 400, code: "bad_request", message: "text is empty")
        let player = makePlayer()
        player.open(chinese(3), settings: PlaybackSettings(), autoplay: true)
        await waitUntil { player.state.isFailed }
        XCTAssertEqual(player.state, .failed("TTS error (bad_request): text is empty"))
        player.retry()
        await waitUntil { player.state == .playing }
        XCTAssertEqual(synth.restartCount, 0)
        XCTAssertEqual(synth.requests.count(where: { $0.text == "第0句。" }), 2)
    }

    func testAFailedRestartIsTheNewFailure() async {
        synth.failures[0] = TTSError.gaveUp(lastError: "boom", logPath: "/logs/tts-server.log")
        synth.restartError = TTSError.serverFatal("still broken")
        let player = makePlayer()
        player.open(chinese(3), settings: PlaybackSettings(), autoplay: true)
        await waitUntil { player.state.isFailed }
        player.retry()
        await waitUntil { player.state == .failed("TTS server failed to start: still broken") }
        XCTAssertEqual(player.failureCount, 2)
        XCTAssertEqual(synth.restartCount, 1)
    }

    func testStopDuringARetryCancelsIt() async {
        synth.failures[0] = TTSError.crashed(status: -9, detail: "")
        synth.holdRestart = true
        let player = makePlayer()
        player.open(chinese(3), settings: PlaybackSettings(), autoplay: true)
        await waitUntil { player.state.isFailed }
        player.retry()
        await waitUntil { self.synth.restartsWaiting == 1 }
        player.stop()
        XCTAssertEqual(player.state, .idle)
        synth.releaseRestart()
        await settle()
        XCTAssertEqual(player.state, .idle, "the retry never resumes by itself")
        XCTAssertEqual(synth.requests.count, 1)
    }

    func testStopAfterAFailureIsIdleAndPlayReadsTheUnitAgain() async {
        synth.failures[0] = TTSError.server(status: 500, code: "internal", message: "boom")
        let player = makePlayer()
        player.open(chinese(3), settings: PlaybackSettings(), autoplay: true)
        await waitUntil { player.state.isFailed }
        player.stop()
        XCTAssertEqual(player.state, .idle)
        XCTAssertNil(player.lastError)
        player.play()
        await waitUntil { player.state == .playing }
        XCTAssertEqual(texts(synth.requests).prefix(2), ["第0句。", "第0句。"])
    }

    /// The current unit failing while paused (paused during buffering) is a failure with its
    /// banner, not a request repeated in a tight loop (review: 43,883 requests in 0.5 s).
    func testTheCurrentUnitFailingWhilePausedIsAFailureNotALoop() async {
        synth.holding = true
        let player = makePlayer()
        player.open(chinese(6), settings: PlaybackSettings(), autoplay: true)
        await waitUntil { self.synth.held == 1 }
        player.pause()
        synth.failures[0] = TTSError.server(status: 500, code: "internal", message: "boom")
        synth.holding = false
        synth.release()
        await waitUntil { player.state.isFailed }
        await settle()
        XCTAssertEqual(player.state, .failed("TTS error (internal): boom"))
        XCTAssertEqual(synth.requests.count, 1)
        XCTAssertEqual(player.failureCount, 1)
        player.retry()
        await waitUntil { player.state == .playing }
        XCTAssertEqual(texts(synth.requests).prefix(2), ["第0句。", "第0句。"])
    }

    /// Next after a failure on a dead engine: one request for the new unit, then the failure
    /// again (banner and Retry), never a loop.
    func testNextAfterAFailureOnADeadEngineFailsOnceMore() async {
        synth.handler = { _ in throw TTSError.gaveUp(lastError: "boom", logPath: "/logs/tts-server.log") }
        let player = makePlayer()
        player.open(chinese(6), settings: PlaybackSettings(), autoplay: true)
        await waitUntil { player.state.isFailed }
        let before = synth.requests.count
        player.next()
        await waitUntil { player.state.isFailed }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(synth.requests.count, before + 1)
        XCTAssertEqual(player.currentUnit, 1)
        XCTAssertEqual(player.failureCount, 2)
        XCTAssertEqual((player.lastError as? TTSError)?.isServerFailure, true, "Retry restarts the server")
    }

    /// A prefetch that failed is not requested again while paused on its unit; Play asks once.
    func testAFailedPrefetchIsNotRequestedWhilePausedOnIt() async {
        synth.failures[1] = TTSError.server(status: 500, code: "internal", message: "boom")
        let player = makePlayer()
        await startPlaying(chinese(6), player)
        player.pause()
        player.next()
        await waitUntil { self.synth.requests.count == 5 }
        await settle()
        XCTAssertEqual(texts(synth.requests), ["第0句。", "第1句。", "第2句。", "第3句。", "第4句。"])
        XCTAssertEqual(player.state, .paused)
        player.play()
        await waitUntil { player.state == .playing }
        XCTAssertEqual(texts(synth.requests).last, "第1句。")
        XCTAssertEqual(output.playedIDs, [0, 1])
    }

    /// Play (after a pause) while Retry restarts the server is not dropped.
    func testPlayDuringARetryPlaysOnceTheServerIsBack() async {
        synth.failures[0] = TTSError.crashed(status: -9, detail: "")
        synth.holdRestart = true
        let player = makePlayer()
        player.open(chinese(3), settings: PlaybackSettings(), autoplay: true)
        await waitUntil { player.state.isFailed }
        player.retry()
        await waitUntil { self.synth.restartsWaiting == 1 }
        player.toggle()
        XCTAssertEqual(player.state, .paused)
        player.toggle()
        XCTAssertEqual(player.state, .buffering)
        synth.releaseRestart()
        await waitUntil { player.state == .playing }
        XCTAssertEqual(synth.restartCount, 1)
        XCTAssertEqual(output.playedIDs, [0])
    }

    func testAPrefetchFailureIsRetriedOnlyWhenItsUnitIsNeeded() async {
        synth.failures[1] = TTSError.server(status: 500, code: "internal", message: "boom")
        let player = makePlayer()
        await startPlaying(chinese(6), player)
        XCTAssertEqual(player.state, .playing, "a failed prefetch does not interrupt")
        XCTAssertEqual(texts(synth.requests), ["第0句。", "第1句。", "第2句。", "第3句。"])
        output.finish()
        await waitUntil { player.state == .playing && player.currentUnit == 1 }
        XCTAssertEqual(synth.requests[4].text, "第1句。")
        XCTAssertEqual(output.playedIDs, [0, 1])
    }

    func testAudioThatCannotPlayIsAFailureAndRetrySynthesizesItAgain() async {
        output.playError = AudioOutputError.engine("no device")
        let player = makePlayer()
        player.open(chinese(3), settings: PlaybackSettings(), autoplay: true)
        await waitUntil { player.state.isFailed }
        XCTAssertEqual(player.state, .failed("Audio playback could not start: no device"))
        XCTAssertFalse(player.cache.keys.contains { $0.unit == 0 }, "the bad audio is forgotten")
        output.playError = nil
        player.retry()
        await waitUntil { player.state == .playing }
        XCTAssertEqual(synth.requests.count(where: { $0.text == "第0句。" }), 2)
    }

    func testTheOutputGoingAwayIsAFailure() async {
        let player = makePlayer()
        await startPlaying(chinese(3), player, requests: 3)
        output.fail(AudioOutputError.engine("device gone"))
        XCTAssertEqual(player.state, .failed("Audio playback could not start: device gone"))
        player.play()
        XCTAssertEqual(player.state, .playing, "Play reads the failed unit again")
    }

    func testJumpingAfterAFailureClearsIt() async {
        synth.failures[0] = TTSError.server(status: 400, code: "bad_request", message: "x")
        let player = makePlayer()
        player.open(chinese(3), settings: PlaybackSettings(), autoplay: true)
        await waitUntil { player.state.isFailed }
        player.next()
        XCTAssertEqual(player.state, .paused)
        XCTAssertNil(player.lastError)
        XCTAssertEqual(player.currentUnit, 1)
    }

    // MARK: - The end, positions, progress

    func testTheEndIsFinishedWithFullProgressAndNoSavedPosition() async {
        let player = makePlayer()
        let doc = chinese(2)
        await startPlaying(doc, player, requests: 2)
        output.finish()
        output.finish()
        XCTAssertEqual(player.state, .finished)
        XCTAssertEqual(player.progress, 1)
        XCTAssertNil(positions.positions[doc.positionKey])
        await waitUntil { self.sleeper.waiting(for: PlaybackController.positionSaveDelay) >= 1 }
        sleeper.release(PlaybackController.positionSaveDelay)
        await settle()
        XCTAssertNil(positions.positions[doc.positionKey], "a pending save was cancelled")
        XCTAssertEqual(synth.playbackActiveHistory.last, false)
        XCTAssertEqual(nowPlaying.last?.state, .stopped)

        player.play()
        XCTAssertEqual(player.currentUnit, 0, "Play after the end starts again")
        XCTAssertEqual(output.playedIDs, [0, 1, 0])
    }

    /// The output is stopped at the end: a running engine keeps the Mac from idle sleep.
    func testTheOutputStopsAtTheEnd() async {
        let player = makePlayer()
        await startPlaying(chinese(2), player, requests: 2)
        let stops = output.stopCount
        output.finish()
        XCTAssertEqual(output.stopCount, stops, "between units the output plays on")
        output.finish()
        XCTAssertEqual(player.state, .finished)
        XCTAssertEqual(output.stopCount, stops + 1)
    }

    func testAJumpAfterTheEndIsIdle() async {
        let player = makePlayer()
        await startPlaying(chinese(3), player, requests: 3)
        for _ in 0..<3 { output.finish() }
        XCTAssertEqual(player.state, .finished)
        player.previous()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.currentUnit, 1)
        XCTAssertLessThan(player.progress, 1)
        player.play()
        XCTAssertEqual(player.state, .playing, "from the cache")
        XCTAssertEqual(output.playedIDs.last, 1)
    }

    func testStopAfterTheEndStartsOverWithoutSavingAPosition() async {
        let player = makePlayer()
        let doc = chinese(2)
        await startPlaying(doc, player, requests: 2)
        output.finish()
        output.finish()
        player.stop()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.currentUnit, 0)
        XCTAssertNil(positions.positions[doc.positionKey])
    }

    func testOpenResumesTheSavedPositionOnlyWhileTheContentMatches() {
        let file = DocumentSource.file(URL(fileURLWithPath: "/books/novel.txt"))
        let doc = chinese(5, source: file)
        positions.positions[doc.positionKey] = ReadingPosition(unit: 3, contentHash: doc.contentHash, date: .distantPast)
        let player = makePlayer()
        player.open(doc, settings: PlaybackSettings(), autoplay: false)
        XCTAssertEqual(player.currentUnit, 3)

        let edited = document([("改过了。", .zh), ("第1句。", .zh), ("第2句。", .zh), ("第3句。", .zh)], source: file)
        XCTAssertEqual(edited.positionKey, doc.positionKey)
        player.open(edited, settings: PlaybackSettings(), autoplay: false)
        XCTAssertEqual(player.currentUnit, 0, "the file changed: start from the beginning")
    }

    func testPositionsAreSavedOnceTheUnitRestsAndOnStop() async {
        let player = makePlayer()
        let doc = chinese(6)
        await startPlaying(doc, player)
        output.finish()
        XCTAssertNil(positions.positions[doc.positionKey])
        output.finish()
        await waitUntil { self.sleeper.waiting(for: PlaybackController.positionSaveDelay) == 2 }
        sleeper.release(PlaybackController.positionSaveDelay)
        await waitUntil { self.positions.saveCount == 1 }
        XCTAssertEqual(positions.positions[doc.positionKey],
                       ReadingPosition(unit: 2, contentHash: doc.contentHash, date: Date(timeIntervalSince1970: 1_000)))
        player.next()
        player.stop()
        XCTAssertEqual(positions.saveCount, 2)
        XCTAssertEqual(positions.positions[doc.positionKey]?.unit, 3)
    }

    func testProgressUsesRealDurationsWhereKnownAndEstimatesElsewhere() async {
        let player = makePlayer()
        let doc = chinese(4)
        player.open(doc, settings: PlaybackSettings(), autoplay: false)
        XCTAssertEqual(player.progress, 0)
        player.seek(to: 2)
        XCTAssertEqual(player.progress, 0.5, accuracy: 0.001, "equal estimates for equal units")

        synth.duration = { _ in 2.0 }
        player.seek(to: 0)
        player.play()
        await waitUntil { self.synth.requests.count == 4 && player.state == .playing }
        await settle()
        // Every unit is now 2.0 s + its pause (0.25, 0.5, 0.25, 0.5): 9.5 s in all.
        XCTAssertEqual(player.progress, 0, accuracy: 0.001)
        output.currentTime = 1.0
        XCTAssertEqual(player.progress, 1.0 / 9.5, accuracy: 0.001)
        output.finish()
        XCTAssertEqual(player.progress, 2.25 / 9.5, accuracy: 0.001)
    }

    /// A real duration replacing a smaller estimate ahead must not move the bar back; a jump
    /// back does.
    func testProgressNeverMovesBackWhileReading() async {
        synth.holding = true
        let player = makePlayer()
        player.open(chinese(4), settings: PlaybackSettings(), autoplay: true)
        synth.duration = { _ in 0.2 }
        synth.release()
        await waitUntil { player.state == .playing && self.synth.held == 1 }
        output.currentTime = 0.2
        let before = player.progress
        XCTAssertGreaterThan(before, 0)
        synth.duration = { _ in 30 }  // the units ahead are much longer than estimated
        synth.release(3)
        await waitUntil { self.synth.requests.count == 4 && self.synth.held == 0 }
        await settle()
        XCTAssertEqual(player.progress, before, "held, not moved back")
        output.finish()
        XCTAssertGreaterThanOrEqual(player.progress, before)
        player.seek(to: 0)
        XCTAssertEqual(player.progress, 0, "a jump back moves it back")
        synth.holding = false
    }

    // MARK: - Now Playing (R4-12)

    func testNowPlayingShowsTheDocumentAndItsCommandsControlPlayback() async {
        let player = makePlayer()
        let doc = document([("第一句。", .zh), ("第二句。", .zh), ("第三句。", .zh)],
                           source: .url(URL(string: "https://example.com/a")!), sourceLabel: "example.com")
        await startPlaying(doc, player, requests: 3)
        XCTAssertEqual(nowPlaying.last?.title, "第一句。")
        XCTAssertEqual(nowPlaying.last?.artist, "example.com")
        XCTAssertEqual(nowPlaying.last?.state, .playing)
        XCTAssertEqual(nowPlaying.last?.rate, 1.0)
        nowPlaying.onCommand?(.pause)
        XCTAssertEqual(player.state, .paused)
        XCTAssertEqual(nowPlaying.last?.state, .paused)
        XCTAssertEqual(nowPlaying.last?.rate, 0)
        nowPlaying.onCommand?(.toggle)
        XCTAssertEqual(player.state, .playing)
        nowPlaying.onCommand?(.next)
        XCTAssertEqual(player.currentUnit, 1)
        nowPlaying.onCommand?(.previous)
        XCTAssertEqual(player.currentUnit, 0)
        nowPlaying.onCommand?(.pause)
        nowPlaying.onCommand?(.play)
        XCTAssertEqual(player.state, .playing)
    }

    // MARK: - Engines

    /// v0.5.0: another engine restarts the sentence being read with it (as a new voice does).
    func testAnotherSynthesizerHasItsOwnCacheAndReadsTheSentenceAgain() async {
        let player = makePlayer()
        await startPlaying(chinese(4), player)
        let system = FakeSynthesizer()
        system.engineID = "apple"
        system.honoursSpeed = false
        player.setSynthesizer(system)
        XCTAssertEqual(synth.playbackActiveHistory.last, false)
        XCTAssertEqual(system.playbackActiveHistory.last, true)
        await waitUntil { system.requests.count == 4 && player.state == .playing }
        XCTAssertEqual(texts(system.requests), ["第0句。", "第1句。", "第2句。", "第3句。"],
                       "the sentence being read starts again with the new engine")
        XCTAssertEqual(output.playedIDs, [0, 0])
        XCTAssertEqual(synth.requests.count, 4, "the old engine gets nothing more")
        XCTAssertEqual(output.played.last?.synthSpeed, 1.0)
        XCTAssertTrue(player.cache.keys.allSatisfy { $0.engineID == "apple" })
    }

    func testAnotherSynthesizerWhilePausedStaysPaused() async {
        let player = makePlayer()
        await startPlaying(chinese(4), player)
        player.pause()
        let qwen = FakeSynthesizer.qwen()
        player.setSynthesizer(qwen)
        XCTAssertEqual(player.state, .paused)
        await waitUntil { qwen.requests.count == 4 }
        XCTAssertEqual(texts(qwen.requests), ["第0句。", "第1句。", "第2句。", "第3句。"],
                       "the current unit's audio is made meanwhile")
        await settle()
        XCTAssertEqual(output.playedIDs, [0])
        XCTAssertEqual(player.state, .paused)
        XCTAssertEqual(qwen.playbackActiveHistory.last, false, "paused: the new engine may go idle")
        player.play()
        XCTAssertEqual(output.playedIDs, [0, 0])
        XCTAssertEqual(player.state, .playing)
    }

    /// Qwen's voices come with the engine: one switch, one restart, every request with them.
    func testAnEngineWithItsOwnVoicesRestartsOnce() async throws {
        let player = makePlayer()
        let mixed = document([("Hello there.", .en), ("第二句。", .zh), ("Third one.", .en)])
        await startPlaying(mixed, player, requests: 3)
        let qwen = FakeSynthesizer.qwen()
        let voices = Dictionary(uniqueKeysWithValues: Voice.qwen.map { ($0.language, $0) })
        player.setSynthesizer(qwen, voices: voices)
        await waitUntil { qwen.requests.count == 3 && player.state == .playing }
        XCTAssertEqual(qwen.requests.map(\.voiceID), ["aiden", "serena", "aiden"])
        XCTAssertEqual(output.playedIDs, [0, 0])
        XCTAssertEqual(player.settings.voice(for: .zh).id, "serena")

        let before = qwen.requests.count
        player.setSynthesizer(qwen, voices: voices)
        await settle()
        XCTAssertEqual(qwen.requests.count, before, "the same engine and voices change nothing")
        XCTAssertEqual(output.playedIDs, [0, 0])
    }

    /// Qwen synthesizes at 1.0 and the player time-stretches: rate = speed / 1.0, and a speed
    /// change never synthesizes again.
    func testQwenIsTimeStretchedAndNeverResynthesizedForSpeed() async {
        let qwen = FakeSynthesizer.qwen()
        let sleeper = self.sleeper!
        let player = PlaybackController(
            synthesizer: qwen, output: output, positions: positions, nowPlaying: nowPlaying,
            sleep: { try await sleeper.sleep($0) })
        player.open(chinese(6), settings: PlaybackSettings(speed: 1.5), autoplay: true)
        await waitUntil { player.state == .playing && qwen.requests.count == 4 }
        XCTAssertTrue(qwen.requests.allSatisfy { $0.speed == 1.0 })
        XCTAssertEqual(output.played.last?.synthSpeed, 1.0)
        XCTAssertEqual(output.userSpeed, 1.5, "played at 1.5 / 1.0")
        XCTAssertTrue(player.cache.keys.allSatisfy { $0.engineID == "qwen-1.7b" && $0.speed == 1.0 })
        player.userSetSpeed(0.8)
        XCTAssertEqual(output.userSpeed, 0.8)
        await settle()
        XCTAssertEqual(qwen.requests.count, 4)
        XCTAssertFalse(sleeper.calls.contains(PlaybackController.speedDebounce))
        output.finish()
        await waitUntil { self.output.played.count == 2 && qwen.requests.count == 5 }
        await settle()
        XCTAssertEqual(qwen.requests.count, 5, "only the next unit ahead, at 1.0")
        XCTAssertEqual(qwen.requests.last?.speed, 1.0)
        XCTAssertEqual(output.played.last?.synthSpeed, 1.0)
        XCTAssertEqual(output.userSpeed, 0.8)
    }

    // MARK: - Word timeline (v0.4.0)

    /// Audio with word timings for the English units below ("Hello there." / "Second one.").
    private func timedResult(_ request: SynthesisRequest) -> SynthesisResult {
        let words = request.text.split(separator: " ").map(String.init)
        let tokens = words.enumerated().map { index, word in
            TimedSpan(text: word.trimmingCharacters(in: .punctuationCharacters), start: Double(index) * 0.4,
                      end: Double(index) * 0.4 + 0.35)
        }
        return SynthesisResult(wav: minimalWAV, duration: 1, sampleRate: 24_000, silent: false,
                               sentences: [TimedSpan(text: request.text, start: 0, end: 1)], tokens: tokens,
                               requestID: request.requestID, synthSpeed: request.speed)
    }

    func testTheLoadedUnitsTokensBecomeItsWordTimeline() async throws {
        synth.handler = { [unowned self] in self.timedResult($0) }
        let player = makePlayer()
        let doc = document([("Hello there.", .en), ("Second one.", .en)])
        XCTAssertNil(player.wordTimeline)
        await startPlaying(doc, player, requests: 2)
        let first = try XCTUnwrap(player.wordTimeline)
        XCTAssertEqual(first.unit, 0)
        XCTAssertEqual(first.timeline.words.map(\.range), [0..<5, 6..<11])
        output.currentTime = 0.5
        XCTAssertEqual(player.playbackTime, 0.5, "the output's own (synthesized) time")
        XCTAssertEqual(first.timeline.word(at: player.playbackTime)?.range, 6..<11)

        player.pause()
        XCTAssertEqual(player.wordTimeline, first, "paused: the word stays")
        player.play()
        output.finish()
        await waitUntil { player.wordTimeline?.unit == 1 }
        XCTAssertEqual(player.wordTimeline?.timeline.words.map(\.range), [0..<6, 7..<10])

        player.stop()
        XCTAssertNil(player.wordTimeline, "nothing loaded, no word")
    }

    func testAJumpDropsTheOldUnitsTimeline() async throws {
        synth.handler = { [unowned self] in self.timedResult($0) }
        synth.holding = true
        let player = makePlayer()
        let doc = document([("Hello there.", .en), ("Second one.", .en), ("Third one here.", .en)])
        player.open(doc, settings: PlaybackSettings(), autoplay: true)
        synth.release(1)
        await waitUntil { player.state == .playing }
        XCTAssertEqual(player.wordTimeline?.unit, 0)
        player.seek(to: 2)
        XCTAssertNil(player.wordTimeline, "unit 2 has no audio yet")
        XCTAssertEqual(player.state, .buffering)
        synth.holding = false
        await waitUntil { player.state == .playing && player.currentUnit == 2 }
        XCTAssertEqual(player.wordTimeline?.unit, 2)
    }

    func testAnEngineWithoutTokensHasNoWordTimeline() async {
        let player = makePlayer()
        await startPlaying(chinese(4), player)
        XCTAssertNil(player.wordTimeline, "sentence highlight only")
    }
}
