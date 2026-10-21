import XCTest

@testable import ReadRead

/// ▶ in the voice picker (H8, R4-07): the sample through the engine at speed 1.0, its own output,
/// the cache per (engine, voice) in memory and on disk, and the document paused meanwhile.
@MainActor
final class VoicePreviewTests: XCTestCase {
    private var synth: FakeSynthesizer!
    private var output: FakeAudioOutput!
    private var cache: URL!
    private var pauses = 0
    private var resumes = 0
    private var errors: [String] = []

    override func setUp() async throws {
        synth = FakeSynthesizer()
        output = FakeAudioOutput()
        cache = try makeTemporaryDirectory().appending(path: "previews")
        pauses = 0
        resumes = 0
        errors = []
    }

    private func makePreviewer(documentPlaying: Bool = true) -> VoicePreviewer {
        let previewer = VoicePreviewer(output: output, cacheDirectory: cache)
        previewer.pauseDocument = { [unowned self] in
            pauses += 1
            return documentPlaying
        }
        previewer.resumeDocument = { [unowned self] in resumes += 1 }
        previewer.onError = { [unowned self] in errors.append(AppState.message(for: $0)) }
        return previewer
    }

    private func voice(_ id: String) throws -> Voice { try XCTUnwrap(Voice.voice(id: id)) }

    func testTheSampleIsSynthesizedAtSpeedOneAndPlayedOnItsOwnOutput() async throws {
        let previewer = makePreviewer()
        output.userSpeed = 1.7
        previewer.toggle(try voice("bf_emma"), synthesizer: synth)
        XCTAssertEqual(previewer.phase, .loading(voiceID: "bf_emma"))
        XCTAssertEqual(pauses, 1)
        await waitUntil { previewer.phase == .playing(voiceID: "bf_emma") }
        XCTAssertEqual(synth.requests.map(\.text), [VoicePreviewer.samples[.en]])
        XCTAssertEqual(synth.requests.first?.voiceID, "bf_emma")
        XCTAssertEqual(synth.requests.first?.speed, 1.0)
        XCTAssertEqual(output.played.first?.id, VoicePreviewer.itemID)
        XCTAssertEqual(output.played.first?.pause, 0)
        XCTAssertEqual(output.userSpeed, 1.0, "heard at speed 1.0")
        output.finish()
        XCTAssertEqual(previewer.phase, .idle)
        XCTAssertEqual(resumes, 1)
    }

    func testTheSecondPreviewComesFromMemoryAndANewRunFromDisk() async throws {
        let previewer = makePreviewer()
        previewer.toggle(try voice("zf_001"), synthesizer: synth)
        await waitUntil { previewer.phase == .playing(voiceID: "zf_001") }
        output.finish()
        previewer.toggle(try voice("zf_001"), synthesizer: synth)
        XCTAssertEqual(previewer.phase, .playing(voiceID: "zf_001"), "no wait")
        XCTAssertEqual(synth.requests.count, 1)
        output.finish()

        let key = VoicePreviewer.cacheKey(engineID: "kokoro", voiceID: "zf_001", language: .zh)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appending(path: key + ".wav").path))
        let again = makePreviewer()
        again.toggle(try voice("zf_001"), synthesizer: synth)
        XCTAssertEqual(again.phase, .playing(voiceID: "zf_001"))
        XCTAssertEqual(synth.requests.count, 1, "read from $READREAD_CACHE_DIR/previews")
    }

    func testABrokenCacheFileIsRemovedAndMadeAgain() async throws {
        let key = VoicePreviewer.cacheKey(engineID: "kokoro", voiceID: "zm_009", language: .zh)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appending(path: key + ".wav")
        try Data("not a wav".utf8).write(to: file)
        let previewer = makePreviewer()
        previewer.toggle(try voice("zm_009"), synthesizer: synth)
        await waitUntil { previewer.phase == .playing(voiceID: "zm_009") }
        XCTAssertEqual(synth.requests.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), minimalWAV)
    }

    func testEachEngineHasItsOwnPreviews() async throws {
        let previewer = makePreviewer()
        previewer.toggle(try voice("af_heart"), synthesizer: synth)
        await waitUntil { previewer.phase == .playing(voiceID: "af_heart") }
        output.finish()
        let system = FakeSynthesizer()
        system.engineID = "apple"
        previewer.toggle(try voice("af_heart"), synthesizer: system)
        await waitUntil { previewer.phase == .playing(voiceID: "af_heart") }
        XCTAssertEqual(system.requests.count, 1)
        XCTAssertNotEqual(VoicePreviewer.cacheKey(engineID: "kokoro", voiceID: "af_heart", language: .en),
                          VoicePreviewer.cacheKey(engineID: "apple", voiceID: "af_heart", language: .en))
    }

    func testTheSameButtonStopsAndAnotherVoiceTakesOver() async throws {
        let previewer = makePreviewer()
        previewer.toggle(try voice("af_heart"), synthesizer: synth)
        await waitUntil { previewer.phase == .playing(voiceID: "af_heart") }
        previewer.toggle(try voice("af_bella"), synthesizer: synth)
        await waitUntil { previewer.phase == .playing(voiceID: "af_bella") }
        XCTAssertEqual(pauses, 1, "the document was paused once")
        XCTAssertEqual(resumes, 0, "and goes on only when the previews are over")
        XCTAssertGreaterThanOrEqual(output.stopCount, 1)
        previewer.toggle(try voice("af_bella"), synthesizer: synth)
        XCTAssertEqual(previewer.phase, .idle)
        XCTAssertNil(output.current)
        XCTAssertEqual(resumes, 1)
    }

    func testStoppingWhileLoadingCancelsTheRequest() async throws {
        synth.hangUntilCancelled()
        let previewer = makePreviewer()
        previewer.toggle(try voice("zf_032"), synthesizer: synth)
        await waitUntil { self.synth.requests.count == 1 }
        previewer.stop()
        XCTAssertEqual(previewer.phase, .idle)
        await waitUntil { self.synth.cancelledCount == 1 }
        XCTAssertTrue(output.played.isEmpty)
        XCTAssertEqual(resumes, 1)
    }

    func testAPausedDocumentIsNotResumed() async throws {
        let previewer = makePreviewer(documentPlaying: false)
        previewer.toggle(try voice("zf_001"), synthesizer: synth)
        await waitUntil { previewer.phase == .playing(voiceID: "zf_001") }
        output.finish()
        XCTAssertEqual(resumes, 0)
    }

    func testAFailureEndsThePreviewAndReportsIt() async throws {
        synth.failures[0] = TTSError.connectionFailed("refused")
        let previewer = makePreviewer()
        previewer.toggle(try voice("zf_001"), synthesizer: synth)
        await waitUntil { !self.errors.isEmpty }
        XCTAssertEqual(previewer.phase, .idle)
        XCTAssertEqual(errors, ["Could not reach the TTS server: refused"])
        XCTAssertEqual(resumes, 1)

        output.playError = AudioOutputError.engine("no device")
        previewer.toggle(try voice("zf_001"), synthesizer: synth)
        await waitUntil { self.errors.count == 2 }
        XCTAssertEqual(errors.last, "Audio playback could not start: no device")
        XCTAssertEqual(previewer.phase, .idle)
    }

    func testTheDocumentsEndOfItemIsNotThePreviews() async throws {
        let previewer = makePreviewer()
        previewer.toggle(try voice("zf_001"), synthesizer: synth)
        await waitUntil { previewer.phase == .playing(voiceID: "zf_001") }
        output.onFinished?(3)
        XCTAssertEqual(previewer.phase, .playing(voiceID: "zf_001"), "only the preview's own id ends it")
    }

    func testTheCacheKeyNamesEngineVoiceAndSample() {
        let key = VoicePreviewer.cacheKey(engineID: "kokoro", voiceID: "zf_001", language: .zh)
        XCTAssertTrue(key.hasPrefix("kokoro-zf_001-"))
        XCTAssertEqual(key.count, "kokoro-zf_001-".count + 8)
        XCTAssertNotEqual(key, VoicePreviewer.cacheKey(engineID: "kokoro", voiceID: "zf_001", language: .en),
                          "another sample text, another file")
        XCTAssertFalse(VoicePreviewer.samples[.zh]?.isEmpty ?? true)
        XCTAssertFalse(VoicePreviewer.samples[.en]?.isEmpty ?? true)
    }
}
