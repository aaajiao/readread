import XCTest

@testable import ReadRead

/// The app flow: input → the document loader → PlaybackController, one load at a time, errors,
/// preferences, the system-voice fallback, and the v0.4.0 entry points (drops, the clipboard,
/// commands from the keyboard and the status item, Settings), with a fake loader, synthesizer,
/// audio outputs, clipboard, Finder, login item and app shell.
@MainActor
final class AppStateTests: XCTestCase {
    private var synth: FakeSynthesizer!
    private var system: FakeSynthesizer!
    private var output: FakeAudioOutput!
    private var previewOutput: FakeAudioOutput!
    private var store: MemoryPreferences!
    private var positions: MemoryPositions!
    private var loader: FakeDocumentLoader!
    private var pasteboard: FakePasteboard!
    private var workspace: FakeWorkspace!
    private var loginItem: FakeLoginItem!
    private var shell: FakeShell!
    private var directories: RuntimeDirectories!
    private var clearedCaches = 0
    private var clearCacheError: (any Error)?

    override func setUp() async throws {
        synth = FakeSynthesizer()
        system = FakeSynthesizer()
        system.engineID = "apple"
        system.honoursSpeed = false
        system.status = .ready
        output = FakeAudioOutput()
        previewOutput = FakeAudioOutput()
        store = MemoryPreferences()
        positions = MemoryPositions()
        loader = FakeDocumentLoader()
        pasteboard = FakePasteboard()
        workspace = FakeWorkspace()
        loginItem = FakeLoginItem()
        shell = FakeShell()
        let scratch = try makeTemporaryDirectory()
        directories = RuntimeDirectories(
            logDirectory: scratch.appending(path: "logs").path, cacheDirectory: scratch.appending(path: "cache").path,
            userLexicon: scratch.appending(path: "support/lexicon_zh.json").path)
        clearedCaches = 0
        clearCacheError = nil
    }

    /// Never `AppState()`: that would start the real server and audio and use UserDefaults.standard.
    /// The sleeper's sleeps end at once unless the test passes its own.
    private func makeState(sleeper: TestSleeper? = nil) -> AppState {
        let system = self.system!
        let sleeper = sleeper ?? {
            let immediate = TestSleeper()
            immediate.setDefault(.immediate)
            return immediate
        }()
        let state = AppState(
            engine: synth, output: output, defaults: store, loadDocument: loader.load,
            positions: positions, nowPlaying: nil, systemVoice: { system },
            sleep: { try await sleeper.sleep($0) },
            pasteboard: pasteboard, workspace: workspace, loginItem: loginItem, previewOutput: previewOutput,
            directories: directories,
            clearArticleCache: { [weak self] in
                guard let self else { return }
                self.clearedCaches += 1
                if let error = self.clearCacheError { throw error }
            })
        state.shell = shell
        return state
    }

    private func submit(_ input: String, in state: AppState) {
        state.urlInput = input
        state.submit()
    }

    private enum LoadFailure: LocalizedError {
        case nothingToRead
        var errorDescription: String? { "Nothing to read here." }
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
        XCTAssertEqual(loader.inputs, [.text("第一句话在这里。第二句话也在这里。")])
        XCTAssertTrue(loader.urlCalls.isEmpty, "text is never sent anywhere")
    }

    func testAURLIsFetchedAndItsPageRead() async throws {
        loader.set("# A Post\n\nFirst sentence here. Second one.", title: "A Post", domain: "example.com",
                   for: "https://example.com/post")
        let state = makeState()
        submit("example.com/post", in: state)
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(loader.urlCalls.map(\.absoluteString), ["https://example.com/post"])
        let document = try XCTUnwrap(state.document)
        XCTAssertEqual(document.title, "A Post")
        XCTAssertEqual(document.sourceLabel, "example.com")
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
        guard case .file(let asked) = loader.inputs.first else { return XCTFail("\(loader.inputs)") }
        XCTAssertEqual(asked.standardizedFileURL.path, url.standardizedFileURL.path)
        let document = try XCTUnwrap(state.document)
        guard case .file(let opened) = document.source else { return XCTFail("\(document.source)") }
        XCTAssertEqual(opened.standardizedFileURL.path, url.standardizedFileURL.path)
        XCTAssertEqual(document.units.filter { $0.kind == .sentence }.map(\.speakText), ["Hello there.", "This is a file."])
        XCTAssertTrue(loader.urlCalls.isEmpty)
    }

    func testANewLoadCancelsTheOneRunning() async throws {
        let slow = "https://slow.example/a"
        loader.hold(slow)
        loader.set("Slow page text.", title: "Slow", domain: "slow.example", for: slow)
        loader.set("Fast page text.", title: "Fast", domain: "fast.example", for: "https://fast.example/b")
        let state = makeState()
        state.load(.url(try XCTUnwrap(URL(string: slow))))
        await waitUntil { self.loader.inputs.count == 1 }
        state.load(.url(try XCTUnwrap(URL(string: "https://fast.example/b"))))
        await waitUntil { state.document != nil }
        XCTAssertEqual(state.document?.title, "Fast")
        await waitUntil { self.loader.cancelled.count == 1 }
        loader.release(slow)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(state.document?.title, "Fast", "the cancelled load never opens")
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.isLoading)
    }

    func testReturnIsIgnoredWhileLoadingAndCancelStopsTheLoad() async throws {
        let slow = "https://slow.example/a"
        loader.hold(slow)
        loader.set("Slow page text.", title: "Slow", domain: "slow.example", for: slow)
        let state = makeState()
        submit(slow, in: state)
        await waitUntil { self.loader.inputs.count == 1 }
        submit("https://other.example/b", in: state)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(loader.inputs.count, 1, "Return is ignored while loading")
        XCTAssertTrue(state.isLoading)

        state.cancelLoad()
        XCTAssertFalse(state.isLoading)
        await waitUntil { self.loader.cancelled.count == 1 }
        loader.release(slow)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(state.document)
        XCTAssertNil(state.errorMessage, "a cancelled load is not an error")
        XCTAssertTrue(synth.requests.isEmpty)
    }

    func testAFailedLoadIsAnError() async {
        loader.fail(.text("only markup"), with: LoadFailure.nothingToRead)
        let state = makeState()
        submit("only markup", in: state)
        await waitUntil { !state.isLoading }
        XCTAssertNil(state.document)
        XCTAssertEqual(state.errorMessage, "Nothing to read here.")
        XCTAssertEqual(state.bannerMessage, "Nothing to read here.")
        XCTAssertFalse(state.errorNeedsSetup)
        XCTAssertFalse(state.offersSystemVoice)
        XCTAssertTrue(synth.requests.isEmpty)
    }

    func testEmptyInputDoesNothing() {
        let state = makeState()
        submit("   \n ", in: state)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(synth.prewarmed.isEmpty)
        XCTAssertTrue(loader.inputs.isEmpty)
    }

    func testRetryAfterAFailedFetchLoadsAgain() async throws {
        let url = "https://example.com/flaky"
        loader.set("It works now.", title: "Flaky", domain: "example.com", for: url)
        loader.fail(.url(try XCTUnwrap(URL(string: url))), with: URLError(.timedOut))
        let state = makeState()
        submit(url, in: state)
        await waitUntil { state.errorMessage != nil }
        XCTAssertNil(state.document)
        XCTAssertFalse(state.offersSystemVoice)
        state.retry()
        XCTAssertNil(state.errorMessage)
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(loader.urlCalls.count, 2)
        XCTAssertEqual(state.document?.title, "Flaky")
    }

    // MARK: - Drops, the clipboard, Services, Open With

    func testDroppedFilesLinksAndTextAreRead() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "chapter.md")
        try "第一章的第一句。".write(to: file, atomically: true, encoding: .utf8)
        let state = makeState()
        state.handle(PasteboardItems(fileURLs: [directory.appending(path: "archive.zip"), file], strings: ["ignored"]))
        await waitUntil { state.document != nil }
        XCTAssertEqual(loader.inputs, [.file(file)], "the first readable file wins")

        loader.set("Linked page.", title: "Linked", domain: "example.com", for: "https://example.com/linked")
        state.handle(PasteboardItems(urls: [try XCTUnwrap(URL(string: "https://example.com/linked"))]))
        await waitUntil { state.document?.title == "Linked" }

        state.handle(PasteboardItems(strings: ["Dropped text is read as it is."]))
        await waitUntil { state.document?.source == .text }
        XCTAssertEqual(loader.inputs.last, .text("Dropped text is read as it is."))
    }

    func testAnUnreadableFileGivesANoticeAndNothingLoads() async throws {
        let state = makeState()
        state.handle(PasteboardItems(fileURLs: [URL(fileURLWithPath: "/tmp/photo.heic")]))
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(loader.inputs.isEmpty)
        XCTAssertNil(state.errorMessage, "a notice is not an error: no Retry")
        XCTAssertTrue(state.bannerMessage?.contains("photo.heic") == true)
        state.dismissError()
        XCTAssertNil(state.bannerMessage)

        state.handle(PasteboardItems())
        XCTAssertNotNil(state.notice)
    }

    func testReadClipboardReadsWhatIsOnIt() async throws {
        let state = makeState()
        state.readClipboard()
        XCTAssertEqual(state.notice, "The clipboard is empty.")
        XCTAssertTrue(loader.inputs.isEmpty)

        pasteboard.items = PasteboardItems(strings: ["  第一句。第二句。 "])
        state.perform(.readClipboard)
        XCTAssertNil(state.notice, "a load clears the notice")
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(loader.inputs, [.text("第一句。第二句。")])
    }

    // MARK: - Commands

    func testPlaybackCommandsDriveThePlayerAndCountUserJumps() async throws {
        let state = makeState()
        submit("第一句。第二句。第三句。", in: state)
        await waitUntil { state.player.state == .playing }
        state.perform(.togglePlayPause)
        XCTAssertEqual(state.player.state, .paused)
        state.perform(.togglePlayPause)
        XCTAssertEqual(state.player.state, .playing)
        XCTAssertEqual(state.navigationCount, 0)
        state.perform(.nextSentence)
        XCTAssertEqual(state.player.currentUnit, 1)
        state.perform(.previousSentence)
        XCTAssertEqual(state.player.currentUnit, 0)
        state.seek(to: 2)
        XCTAssertEqual(state.player.currentUnit, 2)
        XCTAssertEqual(state.navigationCount, 3, "the reading view follows again after each")
        state.perform(.stop)
        XCTAssertEqual(state.player.state, .idle)
        XCTAssertEqual(state.player.currentUnit, 2, "Stop keeps the position")
    }

    func testWindowCommandsGoToTheShell() {
        let state = makeState()
        state.perform(.hidePanel)
        state.perform(.openSettings)
        state.perform(.quit)
        XCTAssertEqual(shell.calls, [.hidePanel, .showSettings, .quit])
        state.perform(.edit(.paste))
        XCTAssertEqual(shell.calls.count, 3, "edit actions are the panel's, not AppState's")
    }

    func testOpenFileBringsTheAppForwardForThePicker() {
        let state = makeState()
        XCTAssertFalse(state.showFilePicker)
        state.perform(.openFile)
        XCTAssertTrue(state.showFilePicker)
        XCTAssertEqual(shell.calls, [.activateApp, .showPanel])
    }

    func testTextSizeCommandsAreClampedAndSaved() {
        let state = makeState()
        XCTAssertEqual(state.fontSize, ReadingPreferences.defaultFontSize)
        state.perform(.largerText)
        state.perform(.largerText)
        XCTAssertEqual(state.fontSize, ReadingPreferences.defaultFontSize + 2)
        XCTAssertEqual(store.object(forKey: "font_size") as? Double, ReadingPreferences.defaultFontSize + 2)
        for _ in 0..<40 { state.perform(.largerText) }
        XCTAssertEqual(state.fontSize, ReadingPreferences.fontSizeRange.upperBound)
        XCTAssertFalse(state.canEnlargeText)
        for _ in 0..<40 { state.perform(.smallerText) }
        XCTAssertEqual(state.fontSize, ReadingPreferences.fontSizeRange.lowerBound)
        XCTAssertFalse(state.canShrinkText)
        state.perform(.defaultTextSize)
        XCTAssertEqual(state.fontSize, ReadingPreferences.defaultFontSize)
        XCTAssertEqual(makeState().fontSize, ReadingPreferences.defaultFontSize, "a new run reads it back")
    }

    func testThePanelIsCountedEachTimeItShows() {
        let state = makeState()
        state.panelDidShow()
        state.panelDidShow()
        XCTAssertEqual(state.panelShowCount, 2)
    }

    // MARK: - Preferences

    func testFreshInstallStartsWithTheChineseDefault() {
        let state = makeState()
        XCTAssertEqual(state.settingsLanguage, .zh)
        XCTAssertEqual(state.selectedVoice.id, "zf_001")
        XCTAssertEqual(state.speed, 1.0)
        XCTAssertEqual(state.voicesForSettingsLanguage.map(\.language), Array(repeating: .zh, count: 4))
        XCTAssertEqual(state.languageChoice, .auto)
        XCTAssertEqual(state.voice(for: .en).id, "af_heart")
        XCTAssertTrue(state.autoFollow)
        XCTAssertEqual(state.extractionMode, .localFirst)
        XCTAssertEqual(state.panelSize, ReadingPreferences.defaultPanelSize)
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
        XCTAssertEqual(state.speed(for: .en), 1.3)
        XCTAssertEqual(state.voice(for: .en).id, "bf_emma")
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

    /// R4-07: what input mode shows for each language is what a text in it is read with.
    func testInputModeChoicesForBothLanguagesApplyWhenATextLoads() async throws {
        let state = makeState()
        XCTAssertEqual(state.settingsLanguage, .zh)
        state.selectVoice(try XCTUnwrap(Voice.voice(id: "bm_lewis")))
        state.setSpeed(1.6, for: .en)
        state.setSpeed(0.7, for: .zh)
        XCTAssertEqual(state.speed(for: .en), 1.6)
        XCTAssertEqual(state.speed(for: .zh), 0.7)
        XCTAssertEqual(state.speed, 0.7, "the zh speed is the player's while zh is the settings language")
        XCTAssertEqual(output.userSpeed, 0.7)
        XCTAssertEqual(store.object(forKey: "speed_en") as? Double, 1.6)

        submit("Hello there. This is an English article about the weather in London.", in: state)
        await waitUntil { state.player.state == .playing }
        let request = try XCTUnwrap(synth.requests.first)
        XCTAssertEqual(request.voiceID, "bm_lewis")
        XCTAssertEqual(request.speed, 1.6)
        XCTAssertEqual(state.voice(for: .zh).id, "zf_001", "the other language keeps its own")
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
        state.setSpeed(0.6, for: .zh)
        XCTAssertEqual(output.userSpeed, 1.5, "another language's speed is saved, not heard")
        XCTAssertEqual(store.object(forKey: "speed_zh") as? Double, 0.6)
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

    func testReadingSettingsAreSaved() {
        let state = makeState()
        state.setAutoFollow(false)
        state.setExtractionMode(.remoteOnly)
        state.savePanelSize(CGSize(width: 5_000, height: 100))
        XCTAssertEqual(store.object(forKey: "auto_follow") as? Bool, false)
        XCTAssertEqual(store.string(forKey: ExtractionMode.defaultsKey), "remote", "the loader's key and value")
        let again = makeState()
        XCTAssertFalse(again.autoFollow)
        XCTAssertEqual(again.extractionMode, .remoteOnly)
        XCTAssertEqual(again.panelSize, CGSize(width: ReadingPreferences.maximumPanelSize.width,
                                               height: ReadingPreferences.minimumPanelSize.height))
        store.set("bogus", forKey: ExtractionMode.defaultsKey)
        XCTAssertEqual(makeState().extractionMode, .localFirst)
    }

    // MARK: - Voice preview

    func testAPreviewPausesTheDocumentAndResumesItAfterwards() async throws {
        let state = makeState()
        submit("第一句。第二句。", in: state)
        await waitUntil { state.player.state == .playing && self.synth.requests.count == 2 }
        let voice = try XCTUnwrap(Voice.voice(id: "zm_009"))
        state.previewVoice(voice)
        XCTAssertEqual(state.player.state, .paused)
        await waitUntil { state.previewer.phase == .playing(voiceID: "zm_009") }
        let request = try XCTUnwrap(synth.requests.last)
        XCTAssertEqual(request.text, VoicePreviewer.samples[.zh])
        XCTAssertEqual(request.voiceID, "zm_009")
        XCTAssertEqual(request.speed, 1.0)
        XCTAssertEqual(previewOutput.playedIDs, [VoicePreviewer.itemID])
        XCTAssertEqual(output.playedIDs, [0], "the document's output is not used")
        XCTAssertEqual(store.string(forKey: "voice_zh"), nil, "a preview chooses nothing")

        previewOutput.finish()
        XCTAssertEqual(state.previewer.phase, .idle)
        XCTAssertEqual(state.player.state, .playing, "the document goes on")
    }

    func testAPausedDocumentStaysPausedAfterAPreview() async throws {
        let state = makeState()
        submit("第一句。第二句。", in: state)
        await waitUntil { state.player.state == .playing }
        state.player.pause()
        state.previewVoice(try XCTUnwrap(Voice.voice(id: "zf_032")))
        await waitUntil { state.previewer.phase == .playing(voiceID: "zf_032") }
        previewOutput.finish()
        XCTAssertEqual(state.player.state, .paused)
    }

    func testAFailedPreviewIsANotice() async throws {
        synth.failures[0] = TTSError.server(status: 400, code: "bad_voice", message: "no such voice")
        let state = makeState()
        state.previewVoice(try XCTUnwrap(Voice.voice(id: "af_bella")))
        await waitUntil { state.notice != nil }
        XCTAssertEqual(state.previewer.phase, .idle)
        XCTAssertTrue(state.notice?.contains("no such voice") == true)
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.settingsNotice, "started in the panel: shown in the panel")
    }

    /// R4-21: ▶ in Settings fails in Settings (the panel's banner may be hidden).
    func testAPreviewFromSettingsFailsInSettings() async throws {
        synth.failures[0] = TTSError.server(status: 400, code: "bad_voice", message: "no such voice")
        let state = makeState()
        state.previewVoice(try XCTUnwrap(Voice.voice(id: "af_bella")), inSettings: true)
        await waitUntil { state.settingsNotice != nil }
        XCTAssertEqual(state.settingsNotice?.section, .preview)
        XCTAssertTrue(state.settingsNotice?.message.contains("no such voice") == true)
        XCTAssertTrue(state.settingsNotice?.isError == true)
        XCTAssertNil(state.notice, "nothing left for the panel to show later")
        state.clearSettingsNotice()
        XCTAssertNil(state.settingsNotice, "the window closed")
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
        loader.set("First sentence here.", title: nil, domain: "example.com", for: "https://example.com/post")
        let state = makeState()
        submit("https://example.com/post", in: state)
        await waitUntil { state.errorMessage != nil }
        let error = state.errorMessage
        state.showLog()
        XCTAssertEqual(state.errorMessage, (error ?? "") + "\nNo log yet at /logs/tts-server.log")
        XCTAssertTrue(workspace.opened.isEmpty)
        XCTAssertTrue(state.errorNeedsSetup)
        XCTAssertTrue(state.offersSystemVoice)
        state.retry()
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(synth.restartCount, 1, "the engine is restarted")
        XCTAssertEqual(loader.urlCalls.count, 1, "the page is not fetched again")
        XCTAssertNil(state.logNotice)
    }

    func testShowLogOpensAnExistingLog() throws {
        let log = try makeTemporaryDirectory().appending(path: "tts-server.log")
        try Data("log".utf8).write(to: log)
        synth.logFileURL = log
        let state = makeState()
        state.showLog()
        XCTAssertEqual(workspace.opened, [log])
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

    func testCopyPutsTheWholeBannerOnTheClipboard() async {
        synth.failures[0] = TTSError.crashed(status: 3, detail: "Traceback (most recent call last):\nValueError: boom")
        let state = makeState()
        submit("第一句。", in: state)
        await waitUntil { state.errorMessage != nil }
        state.copyBannerMessage()
        XCTAssertEqual(pasteboard.written, [state.errorMessage ?? "?"])
        XCTAssertTrue(pasteboard.written.first?.contains("ValueError: boom") == true)
    }

    // MARK: - Settings

    func testLaunchAtLoginShowsTheRealStatus() {
        loginItem.status = .disabled
        loginItem.statusWhenEnabled = .requiresApproval
        let state = makeState()
        XCTAssertEqual(state.loginItemStatus, .disabled)
        state.setLaunchAtLogin(true)
        XCTAssertEqual(loginItem.requests, [true])
        XCTAssertEqual(state.loginItemStatus, .requiresApproval, "read back from the system")
        state.openLoginItemsSettings()
        XCTAssertEqual(loginItem.settingsOpened, 1)
        loginItem.status = .enabled
        state.openSettings()
        XCTAssertEqual(state.loginItemStatus, .enabled, "refreshed when Settings opens")

        loginItem.error = CocoaError(.featureUnsupported)
        state.setLaunchAtLogin(false)
        XCTAssertEqual(state.loginItemStatus, .enabled)
        XCTAssertEqual(state.settingsNotice?.section, .launchAtLogin, "shown under the toggle")
        XCTAssertTrue(state.settingsNotice?.message.hasPrefix("Launch at login could not be changed") == true)
        XCTAssertNil(state.notice, "not in the panel's banner")
        loginItem.error = nil
        state.setLaunchAtLogin(false)
        XCTAssertNil(state.settingsNotice, "it worked this time")
        XCTAssertEqual(state.loginItemStatus, .disabled)
    }

    func testRestartEngineRestartsTheServer() async {
        let state = makeState()
        state.restartEngine()
        await waitUntil { self.synth.restartCount == 1 }
        synth.restartError = TTSError.startTimeout(seconds: 90)
        state.restartEngine()
        await waitUntil { state.settingsNotice != nil }
        XCTAssertEqual(state.settingsNotice?.section, .engine)
        XCTAssertTrue(state.settingsNotice?.message.contains("90 s") == true)
        XCTAssertNil(state.notice)
    }

    func testRestartEngineAfterAFailureGoesOnReading() async {
        synth.failures[0] = TTSError.crashed(status: -9, detail: "")
        let state = makeState()
        submit("第一句。第二句。", in: state)
        await waitUntil { state.errorMessage != nil }
        state.restartEngine()
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(synth.restartCount, 1)
        XCTAssertNil(state.errorMessage)
    }

    func testClearCachedArticlesCallsTheInjectedCache() async {
        let state = makeState()
        state.clearArticleCache()
        await waitUntil { state.settingsNotice != nil }
        XCTAssertEqual(clearedCaches, 1)
        XCTAssertEqual(state.settingsNotice, SettingsNotice(section: .articleCache, message: "Cached articles were removed.",
                                                            isError: false))
        clearCacheError = CocoaError(.fileWriteNoPermission)
        state.clearArticleCache()
        await waitUntil { state.settingsNotice?.isError == true }
        XCTAssertEqual(clearedCaches, 2)
        XCTAssertTrue(state.settingsNotice?.message.hasPrefix("Cached articles could not be removed") == true)
        XCTAssertNil(state.notice, "the panel's banner shows none of it")
    }

    func testTheDefaultArticleCacheActionIsANoOp() async {
        let state = AppState(engine: synth, output: output, defaults: store, loadDocument: loader.load,
                             pasteboard: pasteboard, workspace: workspace, loginItem: loginItem,
                             previewOutput: previewOutput, directories: directories)
        state.clearArticleCache()
        await waitUntil { state.settingsNotice != nil }
        XCTAssertEqual(state.settingsNotice?.message, "Cached articles were removed.")
    }

    func testThePronunciationFileIsCreatedOnceAndShown() throws {
        let state = makeState()
        let url = state.userLexiconURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        state.revealUserLexicon()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), AppState.emptyLexicon)
        XCTAssertEqual(workspace.revealed, [url])
        let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(entries?["version"] as? Int, 1)

        try Data("{\"version\": 1, \"entries\": [{\"text\": \"还\", \"pinyin\": \"huan2\"}]}".utf8).write(to: url)
        state.revealUserLexicon()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("huan2"), "an existing file is kept")
        XCTAssertEqual(workspace.revealed.count, 2)
    }

    /// R4-21: Show Log in Settings says "no log yet" in Settings, the banner's in the banner.
    func testShowLogWithoutALogSaysSoWhereItWasAsked() {
        let state = makeState()  // the fake engine's log, /logs/tts-server.log, does not exist
        state.showLog(inSettings: true)
        XCTAssertEqual(state.settingsNotice?.section, .files)
        XCTAssertTrue(state.settingsNotice?.message.hasPrefix("No log yet at ") == true)
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(workspace.opened.isEmpty)
    }

    func testEngineStatusText() {
        let state = makeState()
        synth.status = .idle
        XCTAssertEqual(state.engineStatusText, "Not running (starts when needed)")
        synth.status = .starting
        XCTAssertEqual(state.engineStatusText, "Starting…")
        synth.status = .ready
        XCTAssertEqual(state.engineStatusText, "Running")
        synth.status = .failed("boom")
        XCTAssertEqual(state.engineStatusText, "Failed: boom")
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

    /// A document opened over the one being read (a drop, ⌘V, Services, Open With) saves the old
    /// one's position first, the jump just made included (its 2 s save had not run yet).
    func testOpeningAnotherDocumentSavesThePositionOfTheOpenOne() async throws {
        let sleeper = TestSleeper()
        sleeper.setDefault(.immediate)
        sleeper.set(.gated, for: PlaybackController.positionSaveDelay)
        let state = makeState(sleeper: sleeper)
        submit("第一句。第二句。第三句。第四句。", in: state)
        await waitUntil { state.player.state == .playing }
        let key = try XCTUnwrap(state.document?.positionKey)
        state.player.seek(to: 2)
        await waitUntil { sleeper.waiting(for: PlaybackController.positionSaveDelay) >= 1 }
        XCTAssertNil(positions.positions[key], "the save waits for the position to rest")

        state.handle(PasteboardItems(strings: ["Another text replaces it. It is read now."]))
        await waitUntil { state.document?.positionKey != key && state.player.state == .playing }
        XCTAssertEqual(positions.positions[key]?.unit, 2, "the old document resumes where the user left it")
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
