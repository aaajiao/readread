import Synchronization
import XCTest

@testable import ReadRead

/// The app flow: input → DocumentLoader → PlaybackController, one load at a time, errors,
/// preferences and the system-voice fallback (a fake loader, synthesizer and audio output).
@MainActor
final class AppStateTests: XCTestCase {
    private var synth: FakeSynthesizer!
    private var system: FakeSynthesizer!
    private var output: FakeAudioOutput!
    private var store: MemoryPreferences!
    private var positions: MemoryPositions!
    private var pages: PageFetcher!

    override func setUp() async throws {
        synth = FakeSynthesizer()
        system = FakeSynthesizer()
        system.engineID = "apple"
        system.honoursSpeed = false
        system.status = .ready
        output = FakeAudioOutput()
        store = MemoryPreferences()
        positions = MemoryPositions()
        pages = PageFetcher()
    }

    /// Never `AppState()`: that would start the real server and audio and use UserDefaults.standard.
    private func makeState() -> AppState {
        let pages = self.pages!
        let system = self.system!
        let sleeper = TestSleeper()
        sleeper.setDefault(.immediate)
        return AppState(
            engine: synth, output: output, defaults: store,
            loader: DocumentLoader(fetchPage: { try await pages.fetch($0) }, readFile: { try await WebExtractor.readFile($0) }),
            positions: positions, nowPlaying: nil, systemVoice: { system },
            sleep: { try await sleeper.sleep($0) })
    }

    private func submit(_ input: String, in state: AppState) {
        state.urlInput = input
        state.submit()
    }

    // MARK: - Load → open → play

    func testPastedTextIsReadAtOnce() async throws {
        let state = makeState()
        submit("第一句话在这里。第二句话也在这里。", in: state)
        XCTAssertTrue(state.isLoading)
        await waitUntil { state.player.state == .playing }
        XCTAssertFalse(state.isLoading)
        let document = try XCTUnwrap(state.document)
        XCTAssertEqual(document.source, .text)
        XCTAssertEqual(document.units.map(\.speakText), ["第一句话在这里。", "第二句话也在这里。"])
        XCTAssertEqual(output.playedIDs, [0])
        XCTAssertEqual(synth.requests.first?.text, "第一句话在这里。")
        XCTAssertEqual(synth.requests.first?.voiceID, "zf_001")
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(pages.calls.isEmpty, "text is never sent anywhere")
    }

    func testAURLIsFetchedAndItsPageRead() async throws {
        pages.set(WebPage(title: "A Post", markdown: "# A Post\n\nFirst sentence here. Second one.", domain: "example.com"),
                  for: "https://example.com/post")
        let state = makeState()
        submit("example.com/post", in: state)
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(pages.calls.map(\.absoluteString), ["https://example.com/post"])
        let document = try XCTUnwrap(state.document)
        XCTAssertEqual(document.title, "A Post")
        XCTAssertEqual(document.sourceLabel, "example.com")
        XCTAssertEqual(document.units.first?.kind, .title, "the title is read first, once")
        XCTAssertEqual(document.units.map(\.speakText), ["A Post.", "First sentence here.", "Second one."])
        XCTAssertEqual(synth.requests.first?.text, "A Post.")
        XCTAssertEqual(synth.requests.first?.voiceID, "af_heart")
        XCTAssertEqual(synth.prewarmed, [.zh], "the last language's model loads during the fetch")
    }

    func testAFilePathIsReadAsAFile() async throws {
        let url = try makeTemporaryDirectory().appending(path: "notes.txt")
        try "Hello there. This is a file.".write(to: url, atomically: true, encoding: .utf8)
        let state = makeState()
        submit(url.path, in: state)
        await waitUntil { state.player.state == .playing }
        let document = try XCTUnwrap(state.document)
        guard case .file(let opened) = document.source else { return XCTFail("\(document.source)") }
        XCTAssertEqual(opened.standardizedFileURL.path, url.standardizedFileURL.path)
        XCTAssertEqual(document.title, "notes")
        XCTAssertEqual(document.sourceLabel, "notes.txt")
        XCTAssertEqual(document.units.map(\.speakText), ["Hello there.", "This is a file."], "a file name is not read")
        XCTAssertTrue(pages.calls.isEmpty)
    }

    func testANewLoadCancelsTheOneRunning() async throws {
        let slow = "https://slow.example/a"
        pages.hold(slow)
        pages.set(WebPage(title: "Slow", markdown: "Slow page text.", domain: "slow.example"), for: slow)
        pages.set(WebPage(title: "Fast", markdown: "Fast page text.", domain: "fast.example"), for: "https://fast.example/b")
        let state = makeState()
        state.load(.url(try XCTUnwrap(URL(string: slow))))
        await waitUntil { self.pages.calls.count == 1 }
        state.load(.url(try XCTUnwrap(URL(string: "https://fast.example/b"))))
        await waitUntil { state.document != nil }
        XCTAssertEqual(state.document?.title, "Fast")
        await waitUntil { self.pages.cancelled.count == 1 }
        pages.release(slow)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(state.document?.title, "Fast", "the cancelled load never opens")
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.isLoading)
    }

    func testReturnIsIgnoredWhileLoadingAndCancelStopsTheLoad() async throws {
        let slow = "https://slow.example/a"
        pages.hold(slow)
        pages.set(WebPage(title: "Slow", markdown: "Slow page text.", domain: "slow.example"), for: slow)
        let state = makeState()
        submit(slow, in: state)
        await waitUntil { self.pages.calls.count == 1 }
        submit("https://other.example/b", in: state)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(pages.calls.count, 1, "Return is ignored while loading")
        XCTAssertTrue(state.isLoading)

        state.cancelLoad()
        XCTAssertFalse(state.isLoading)
        await waitUntil { self.pages.cancelled.count == 1 }
        pages.release(slow)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(state.document)
        XCTAssertNil(state.errorMessage, "a cancelled load is not an error")
        XCTAssertTrue(synth.requests.isEmpty)
    }

    func testAnEmptyDocumentIsAnError() async {
        let state = makeState()
        submit("```\nlet x = 1\n```", in: state)
        await waitUntil { !state.isLoading }
        XCTAssertNil(state.document)
        XCTAssertEqual(state.errorMessage, DocumentError.nothingToRead.errorDescription)
        XCTAssertTrue(state.errorMessage?.contains("没有可读的内容") == true)
        XCTAssertFalse(state.errorNeedsSetup)
        XCTAssertFalse(state.offersSystemVoice)
        XCTAssertTrue(synth.requests.isEmpty)
    }

    func testEmptyInputDoesNothing() {
        let state = makeState()
        submit("   \n ", in: state)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(synth.prewarmed.isEmpty)
    }

    func testRetryAfterAFailedFetchLoadsAgain() async throws {
        let url = "https://example.com/flaky"
        pages.set(WebPage(title: "Flaky", markdown: "It works now.", domain: "example.com"), for: url)
        pages.fail(url, .timedOut)
        let state = makeState()
        submit(url, in: state)
        await waitUntil { state.errorMessage != nil }
        XCTAssertNil(state.document)
        XCTAssertFalse(state.offersSystemVoice)
        state.retry()
        XCTAssertNil(state.errorMessage)
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(pages.calls.count, 2)
        XCTAssertEqual(state.document?.title, "Flaky")
    }

    // MARK: - Preferences

    func testFreshInstallStartsWithTheChineseDefault() {
        let state = makeState()
        XCTAssertEqual(state.settingsLanguage, .zh)
        XCTAssertEqual(state.selectedVoice.id, "zf_001")
        XCTAssertEqual(state.speed, 1.0)
        XCTAssertEqual(state.voicesForSettingsLanguage.map(\.language), Array(repeating: .zh, count: 4))
        XCTAssertEqual(state.languageChoice, .auto)
    }

    func testInitMigratesOldPreferencesAndRestoresTheLastLanguage() {
        store.set("bm_george", forKey: "voice_en-us")
        store.set(1.4, forKey: "speed_en-us")
        store.set("jf_alpha", forKey: "voice_ja")
        store.set("en", forKey: "last_language")
        let state = makeState()
        XCTAssertEqual(state.settingsLanguage, .en)
        XCTAssertEqual(state.selectedVoice.id, "bm_george")
        XCTAssertEqual(state.speed, 1.4)
        XCTAssertEqual(state.voicesForSettingsLanguage.count, 27)
        XCTAssertNil(store.object(forKey: "voice_ja"))
        XCTAssertNil(store.object(forKey: "voice_en-us"))
    }

    func testTheDocumentLanguagePicksItsVoiceAndSpeed() async throws {
        store.set("bf_emma", forKey: "voice_en")
        store.set(1.3, forKey: "speed_en")
        store.set("zm_009", forKey: "voice_zh")
        store.set(0.8, forKey: "speed_zh")
        let state = makeState()
        XCTAssertEqual(state.speed, 0.8, "before a document: the last language's (zh) speed")
        submit("Hello there. This is an English article about the weather in London.", in: state)
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(state.settingsLanguage, .en)
        XCTAssertEqual(store.string(forKey: "last_language"), "en")
        let request = try XCTUnwrap(synth.requests.first)
        XCTAssertEqual(request.voiceID, "bf_emma")
        XCTAssertEqual(request.language, .en)
        XCTAssertEqual(request.speed, 1.3)
        XCTAssertEqual(output.userSpeed, 1.3)

        state.closeDocument()
        XCTAssertEqual(state.settingsLanguage, .en, "the last document's language")
        XCTAssertEqual(state.speed, 1.3)
        let before = synth.requests.count
        submit("这是一篇中文文章。今天天气很好，我们去公园散步吧。", in: state)
        await waitUntil { state.player.state == .playing && state.document?.detectedLanguage == .zh }
        XCTAssertEqual(synth.prewarmed, [.zh, .en])
        let chinese = synth.requests.dropFirst(before)
        XCTAssertFalse(chinese.isEmpty)
        XCTAssertTrue(chinese.allSatisfy { $0.voiceID == "zm_009" && $0.speed == 0.8 })
    }

    func testChoosingAVoiceSavesItAndRestartsTheSentence() async throws {
        let state = makeState()
        submit("第一句话在这里。第二句话也在这里。", in: state)
        await waitUntil { state.player.state == .playing && self.synth.requests.count == 2 }
        let voice = try XCTUnwrap(Voice.voice(id: "zm_055"))
        state.selectVoice(voice)
        XCTAssertEqual(store.string(forKey: "voice_zh"), "zm_055")
        XCTAssertEqual(state.selectedVoice, voice)
        await waitUntil { state.player.state == .playing && self.output.played.count == 2 }
        XCTAssertEqual(output.playedIDs, [0, 0], "the sentence starts again with the new voice")
        XCTAssertEqual(synth.requests[2].voiceID, "zm_055")
        XCTAssertEqual(synth.requests[2].text, "第一句话在这里。")
    }

    func testTheSpeedIsSavedForTheDocumentLanguage() async throws {
        let state = makeState()
        submit("Hello there. This is an English text.", in: state)
        await waitUntil { state.player.state == .playing }
        state.setSpeed(1.5)
        XCTAssertEqual(output.userSpeed, 1.5, "the rate changes at once")
        XCTAssertEqual(store.object(forKey: "speed_en") as? Double, 1.5)
        XCTAssertNil(store.object(forKey: "speed_zh"))
        XCTAssertEqual(state.speed, 1.5)
    }

    func testTheLanguageChoiceIsPerDocumentAndNotSaved() async throws {
        let state = makeState()
        let text = "这是一篇中文文章。今天天气很好。"
        submit(text, in: state)
        await waitUntil { state.player.state == .playing }
        state.setLanguageChoice(.en)
        XCTAssertEqual(state.languageChoice, .en)
        XCTAssertEqual(state.settingsLanguage, .en)
        XCTAssertEqual(state.voicesForSettingsLanguage.first?.language, .en)
        await waitUntil { self.synth.requests.contains { $0.voiceID == "af_heart" && $0.text == "这是一篇中文文章。" } }
        XCTAssertEqual(Set(store.values.keys), ["last_language"], "the choice is not a preference")

        state.closeDocument()
        submit(text, in: state)
        await waitUntil { state.document != nil }
        XCTAssertEqual(state.languageChoice, .en, "the same document keeps its choice")
        state.closeDocument()
        submit("另一篇文章。", in: state)
        await waitUntil { state.document != nil }
        XCTAssertEqual(state.languageChoice, .auto)
    }

    // MARK: - Errors and the system voice

    func testTheSystemVoiceTakesOverWhenTheEngineCannotRun() async throws {
        synth.failures[0] = TTSError.serverFatal("model file missing: voices-v1.0.bin")
        let state = makeState()
        submit("第一句话在这里。第二句话也在这里。", in: state)
        await waitUntil { state.errorMessage != nil }
        XCTAssertEqual(state.errorMessage, "TTS server failed to start: model file missing: voices-v1.0.bin")
        XCTAssertTrue(state.offersSystemVoice)
        XCTAssertFalse(state.errorNeedsSetup)

        state.useSystemVoice()
        XCTAssertTrue(state.usingSystemVoice)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.offersSystemVoice)
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(system.requests.first?.text, "第一句话在这里。", "from the failed sentence on")
        XCTAssertEqual(output.played.last?.synthSpeed, 1.0)
        XCTAssertTrue(state.player.synthesizer === system)
        XCTAssertEqual(state.engineStatus, .ready)

        state.setSpeed(1.5)
        XCTAssertEqual(output.userSpeed, 1.5, "time-stretched: the system voice has no speed")
        state.useEngineVoice()
        XCTAssertFalse(state.usingSystemVoice)
        XCTAssertTrue(state.player.synthesizer === synth)
    }

    func testMissingResourcesShowTheSetupHint() async {
        synth.failures[0] = TTSError.resourcesMissing(["Python runtime (looked for /rr/env/bin/python3)"])
        let state = makeState()
        submit("Some text.", in: state)
        await waitUntil { state.errorMessage != nil }
        XCTAssertTrue(state.errorNeedsSetup)
        XCTAssertTrue(state.offersSystemVoice)
        XCTAssertTrue(state.errorMessage?.contains("/rr/env/bin/python3") == true)
    }

    /// "No log yet" (the server never started) goes under the error without replacing it: the
    /// setup hint, the system-voice offer and Retry stay the engine's.
    func testShowLogWithoutALogKeepsTheEngineError() async {
        synth.failures[0] = TTSError.resourcesMissing(["Python runtime (looked for /rr/env/bin/python3)"])
        pages.set(WebPage(title: nil, markdown: "First sentence here.", domain: "example.com"), for: "https://example.com/post")
        let state = makeState()
        submit("https://example.com/post", in: state)
        await waitUntil { state.errorMessage != nil }
        let error = state.errorMessage
        state.showLog()
        XCTAssertEqual(state.errorMessage, (error ?? "") + "\nNo log yet at /logs/tts-server.log")
        XCTAssertTrue(state.errorNeedsSetup)
        XCTAssertTrue(state.offersSystemVoice)
        state.retry()
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(synth.restartCount, 1, "the engine is restarted")
        XCTAssertEqual(pages.calls.count, 1, "the page is not fetched again")
        XCTAssertNil(state.logNotice)
    }

    func testRetryRestartsTheServerAndContinuesAtTheFailedSentence() async {
        synth.failures[0] = TTSError.crashed(status: -9, detail: "")
        let state = makeState()
        submit("第一句。第二句。", in: state)
        await waitUntil { state.errorMessage != nil }
        state.retry()
        XCTAssertNil(state.errorMessage)
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(synth.restartCount, 1)
        XCTAssertEqual(output.playedIDs, [0])
    }

    func testDismissingHidesTheFailureUntilTheNextOne() async {
        synth.failures[0] = TTSError.server(status: 400, code: "bad_request", message: "text is empty")
        synth.failures[1] = TTSError.server(status: 400, code: "bad_request", message: "again")
        let state = makeState()
        submit("第一句。第二句。", in: state)
        await waitUntil { state.errorMessage != nil }
        XCTAssertFalse(state.offersSystemVoice, "a request error is not the engine failing")
        state.dismissError()
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.player.state.isFailed, "Play still reads the failed sentence again")
        state.player.play()
        await waitUntil { state.errorMessage != nil }
        XCTAssertEqual(state.errorMessage, "TTS error (bad_request): again")
    }

    // MARK: - Positions and shutdown

    func testClosingSavesThePositionAndReopeningResumesThere() async throws {
        let text = "第一句。第二句。第三句。"
        let state = makeState()
        submit(text, in: state)
        await waitUntil { state.player.state == .playing && self.synth.requests.count == 3 }
        output.finish()
        await waitUntil { state.player.currentUnit == 1 && state.player.state == .playing }
        let key = try XCTUnwrap(state.document?.positionKey)
        state.closeDocument()
        XCTAssertNil(state.document)
        XCTAssertEqual(state.urlInput, "")
        XCTAssertNil(output.current)
        XCTAssertEqual(positions.positions[key]?.unit, 1)

        submit(text, in: state)
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(state.player.currentUnit, 1)
    }

    func testShutdownSavesThePositionAndStopsTheEngine() async throws {
        let state = makeState()
        submit("第一句。第二句。", in: state)
        await waitUntil { state.player.state == .playing }
        let key = try XCTUnwrap(state.document?.positionKey)
        state.shutdown()
        XCTAssertEqual(synth.shutdownCount, 1)
        XCTAssertEqual(state.player.state, .idle)
        XCTAssertEqual(positions.positions[key]?.unit, 0)
    }
}

/// `DocumentLoader.fetchPage` for the tests: pages by URL, held until released, failing once.
final class PageFetcher: Sendable {
    private struct State {
        var pages: [String: WebPage] = [:]
        var held: Set<String> = []
        var failures: [String: URLError.Code] = [:]
        var calls: [URL] = []
        var cancelled: [URL] = []
    }

    private let state = Mutex(State())

    var calls: [URL] { state.withLock { $0.calls } }
    var cancelled: [URL] { state.withLock { $0.cancelled } }

    func set(_ page: WebPage, for url: String) { state.withLock { $0.pages[url] = page } }
    func hold(_ url: String) { _ = state.withLock { $0.held.insert(url) } }
    func release(_ url: String) { _ = state.withLock { $0.held.remove(url) } }
    func fail(_ url: String, _ code: URLError.Code) { state.withLock { $0.failures[url] = code } }

    func fetch(_ url: URL) async throws -> WebPage {
        let key = url.absoluteString
        state.withLock { $0.calls.append(url) }
        do {
            while state.withLock({ $0.held.contains(key) }) { try await Task.sleep(for: .milliseconds(1)) }
        } catch {
            state.withLock { $0.cancelled.append(url) }
            throw error
        }
        if let code = state.withLock({ $0.failures.removeValue(forKey: key) }) { throw URLError(code) }
        guard let page = state.withLock({ $0.pages[key] }) else { throw WebExtractorError.fetchFailed(404) }
        return page
    }
}
