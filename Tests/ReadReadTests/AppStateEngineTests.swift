import XCTest

@testable import ReadRead

/// v0.5.0: the engine AppState reads with (Kokoro, or Qwen3-TTS from the high-quality install) and
/// the installer actions of Settings › Advanced, with a fake installer, fake engines, loader,
/// outputs and app shell.
@MainActor
final class AppStateEngineTests: XCTestCase {
    private var kokoro: FakeSynthesizer!
    /// The Qwen engines the factory hands out, in order (a changed installation gets the next).
    private var qwenEngines: [FakeSynthesizer] = []
    /// The installations the factory was asked for.
    private var made: [HQInstallation] = []
    private var qwen: FakeSynthesizer { qwenEngines[0] }
    private var system: FakeSynthesizer!
    private var installer: FakeInstaller!
    private var output: FakeAudioOutput!
    private var previewOutput: FakeAudioOutput!
    private var store: MemoryPreferences!
    private var loader: FakeDocumentLoader!
    private var workspace: FakeWorkspace!
    private var shell: FakeShell!
    private var directories: RuntimeDirectories!
    private let installation = makeInstallation()
    private let updated = makeInstallation(installedAt: Date(timeIntervalSince1970: 1_792_600_000))

    override func setUp() async throws {
        kokoro = FakeSynthesizer()
        qwenEngines = [.qwen(), .qwen(), .qwen()]
        made = []
        system = FakeSynthesizer()
        system.engineID = "apple"
        system.honoursSpeed = false
        installer = FakeInstaller(.installed(installation))
        output = FakeAudioOutput()
        previewOutput = FakeAudioOutput()
        store = MemoryPreferences()
        loader = FakeDocumentLoader()
        workspace = FakeWorkspace()
        shell = FakeShell()
        let scratch = try makeTemporaryDirectory()
        directories = RuntimeDirectories(
            logDirectory: scratch.appending(path: "logs").path, cacheDirectory: scratch.appending(path: "cache").path,
            userLexicon: scratch.appending(path: "support/lexicon_zh.json").path)
    }

    /// Never `AppState()`. `withQwen`: the Qwen factory is wired in (the app's `TTSService.qwen`);
    /// `installer`: another installer than the fake one.
    private func makeState(withQwen: Bool = true, installer: (any HQInstalling)? = nil) -> AppState {
        let immediate = TestSleeper()
        immediate.setDefault(.immediate)
        let system = self.system!
        let factory: QwenEngineFactory = { [unowned self] installation in
            self.made.append(installation)
            return self.qwenEngines[self.made.count - 1]
        }
        let state = AppState(
            engine: kokoro, qwenEngine: withQwen ? factory : nil, installer: installer ?? self.installer,
            output: output, defaults: store, loadDocument: loader.load, positions: MemoryPositions(), nowPlaying: nil,
            systemVoice: { system }, sleep: { try await immediate.sleep($0) }, pasteboard: FakePasteboard(),
            workspace: workspace, loginItem: FakeLoginItem(), previewOutput: previewOutput, directories: directories)
        state.shell = shell
        return state
    }

    private func submit(_ text: String, in state: AppState) {
        state.urlInput = text
        state.submit()
    }

    /// The text's first sentence playing with `engine`, both sentences synthesized.
    private func startReading(_ text: String = "第一句话在这里。第二句话也在这里。", in state: AppState,
                              with engine: FakeSynthesizer) async {
        submit(text, in: state)
        await waitUntil { state.player.state == .playing && engine.requests.count >= 2 }
    }

    /// Let pending tasks run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
    }

    // MARK: - The choice and its fallbacks

    func testKokoroIsTheDefaultAndQwenNeedsAnInstall() {
        installer.installState = .notInstalled
        let state = makeState()
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertTrue(state.player.synthesizer === kokoro)
        XCTAssertFalse(state.canChooseQwen)
        state.setEngine(.qwen)
        XCTAssertEqual(state.engineKind, .kokoro, "nothing installed: Qwen cannot be chosen")
        XCTAssertNil(store.object(forKey: "engine"))
        XCTAssertTrue(made.isEmpty)
        XCTAssertNil(state.notice)
        XCTAssertEqual(state.highQualityStatus, .notInstalled)
    }

    func testAStoredQwenChoiceReadsWithQwen() async {
        store.set("qwen", forKey: "engine")
        store.set("zm_009", forKey: "voice_zh")
        let state = makeState()
        XCTAssertEqual(state.engineKind, .qwen)
        XCTAssertEqual(made, [installation], "made once, for the installation")
        XCTAssertTrue(state.player.synthesizer === qwen)
        XCTAssertNil(state.notice)
        XCTAssertEqual(state.highQualityStatus, .installed(installation))

        await startReading(in: state, with: qwen)
        XCTAssertEqual(qwen.requests.map(\.voiceID), ["serena", "serena"])
        XCTAssertTrue(qwen.requests.allSatisfy { $0.speed == 1.0 }, "Qwen has no speed of its own")
        XCTAssertTrue(kokoro.requests.isEmpty)
        XCTAssertEqual(qwen.prewarmed, [.zh], "its model loads while the text is read")
        XCTAssertEqual(store.string(forKey: "voice_zh"), "zm_009", "Kokoro's choice is kept")
    }

    /// The install went away since the last run: Kokoro, the choice reset, said once.
    func testAQwenChoiceWithNothingInstalledFallsBackOnceWithANotice() {
        store.set("qwen", forKey: "engine")
        installer.installState = .notInstalled
        let state = makeState()
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertTrue(state.player.synthesizer === kokoro)
        XCTAssertNil(store.object(forKey: "engine"), "the choice is reset")
        XCTAssertEqual(state.notice, "High-quality mode is no longer installed, so ReadRead reads with Kokoro.")
        XCTAssertEqual(state.bannerMessage, state.notice)
        XCTAssertTrue(made.isEmpty)

        let next = makeState()
        XCTAssertNil(next.notice, "said once")
        XCTAssertEqual(next.engineKind, .kokoro)
    }

    func testADamagedInstallSaysWhyAndWhereToRepairIt() {
        store.set("qwen", forKey: "engine")
        installer.installState = .damaged("venv/bin/python3 is missing")
        let state = makeState()
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertEqual(
            state.notice,
            "High-quality mode cannot be used (venv/bin/python3 is missing), so ReadRead reads with Kokoro. Repair it in Settings › Advanced › High-quality mode.")
        XCTAssertEqual(state.highQualityStatus, .damaged("venv/bin/python3 is missing"))
        XCTAssertFalse(state.canChooseQwen)
    }

    /// `$READREAD_HQ_HOME` set but empty: nothing to repair or remove, so no Repair advice.
    func testWithoutAnHQHomeThereIsNothingToRepairOrRemove() {
        store.set("qwen", forKey: "engine")
        installer.installState = .damaged(HQInstallation.emptyHomeMessage)
        let state = makeState()
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertEqual(
            state.notice,
            "High-quality mode cannot be used (READREAD_HQ_HOME is set but empty: unset it to use the default place, or give it a path.), so ReadRead reads with Kokoro.")
        XCTAssertEqual(state.highQualityRemoval, .nothing)
        XCTAssertFalse(state.canChooseQwen)
    }

    func testABuildWithoutTheQwenEngineReadsWithKokoro() {
        store.set("qwen", forKey: "engine")
        let state = makeState(withQwen: false)
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertFalse(state.canChooseQwen)
        XCTAssertEqual(state.notice, "This build of ReadRead cannot run high-quality mode, so it reads with Kokoro.")
    }

    func testAnUnknownStoredEngineIsKokoroWithoutANotice() {
        store.set("piper", forKey: "engine")
        let state = makeState()
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertNil(state.notice)
        XCTAssertTrue(made.isEmpty)
    }

    // MARK: - Switching (Settings › Advanced › Engine)

    func testChoosingQwenIsSavedRestartsTheSentenceAndStopsKokoro() async {
        let state = makeState()
        await startReading(in: state, with: kokoro)
        XCTAssertTrue(state.canChooseQwen)
        state.setEngine(.qwen)
        XCTAssertEqual(store.string(forKey: "engine"), "qwen")
        XCTAssertEqual(state.engineKind, .qwen)
        XCTAssertTrue(state.player.synthesizer === qwen)
        XCTAssertTrue(state.activeEngine === qwen)
        XCTAssertEqual(qwen.prewarmed, [.zh], "a document is open: the new engine loads")
        await waitUntil { self.kokoro.stopCount == 1 }
        await waitUntil { state.player.state == .playing && self.output.played.count == 2 }
        XCTAssertEqual(output.playedIDs, [0, 0], "the sentence being read starts again")
        XCTAssertEqual(qwen.requests.first?.text, "第一句话在这里。")
        XCTAssertEqual(qwen.requests.first?.voiceID, "serena")

        state.setEngine(.kokoro)
        XCTAssertEqual(store.string(forKey: "engine"), "kokoro")
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertTrue(state.player.synthesizer === kokoro)
        await waitUntil { self.qwen.stopCount == 1 }
        await waitUntil { state.player.state == .playing && self.output.played.count == 3 }
        XCTAssertEqual(kokoro.requests[2].text, "第一句话在这里。")
        XCTAssertEqual(kokoro.requests[2].voiceID, "zf_001")
        XCTAssertEqual(kokoro.stopCount, 1)

        state.setEngine(.qwen)
        XCTAssertEqual(made, [installation], "the Qwen engine is kept for its installation")
        XCTAssertTrue(state.player.synthesizer === qwen)
    }

    func testAPauseStaysAPauseAcrossAnEngineSwitch() async {
        let state = makeState()
        await startReading(in: state, with: kokoro)
        state.player.pause()
        state.setEngine(.qwen)
        XCTAssertEqual(state.player.state, .paused)
        await waitUntil { self.qwen.requests.count == 2 }
        XCTAssertEqual(output.playedIDs, [0])
        state.player.play()
        XCTAssertEqual(state.player.state, .playing)
        XCTAssertEqual(output.playedIDs, [0, 0])
    }

    func testChoosingWithoutADocumentLoadsNothing() async {
        let state = makeState()
        state.setEngine(.qwen)
        XCTAssertTrue(state.player.synthesizer === qwen)
        XCTAssertTrue(qwen.prewarmed.isEmpty)
        XCTAssertTrue(qwen.requests.isEmpty)
        await waitUntil { self.kokoro.stopCount == 1 }
    }

    func testChoosingTheEngineInUseChangesNothing() async {
        store.set("qwen", forKey: "engine")
        let state = makeState()
        state.setEngine(.qwen)
        await settle()
        XCTAssertEqual(kokoro.stopCount, 0)
        XCTAssertEqual(qwen.stopCount, 0)
        XCTAssertEqual(made.count, 1)
        XCTAssertTrue(state.player.synthesizer === qwen)
    }

    func testQwenCannotBeChosenWhileAnInstallOrUninstallRuns() {
        let state = makeState()
        installer.state = .running(.install, InstallerProgress())
        XCTAssertFalse(state.canChooseQwen)
        installer.state = .running(.uninstall, InstallerProgress())
        XCTAssertFalse(state.canChooseQwen)
        state.setEngine(.qwen)
        XCTAssertEqual(state.engineKind, .kokoro)
        installer.state = .running(.check, InstallerProgress())
        XCTAssertTrue(state.canChooseQwen, "verifying changes nothing")
        installer.state = .idle
        XCTAssertTrue(state.canChooseQwen)
    }

    // MARK: - Voices, speeds, the preview

    func testQwenHasOneVoicePerLanguageAndKokoroKeepsItsChoices() throws {
        store.set("zm_009", forKey: "voice_zh")
        store.set("bf_emma", forKey: "voice_en")
        let state = makeState()
        XCTAssertEqual(state.voiceCatalog, Voice.all)
        XCTAssertEqual(state.voice(for: .zh).id, "zm_009")
        XCTAssertTrue(state.hasVoiceChoice(for: .zh))

        state.setEngine(.qwen)
        XCTAssertEqual(state.voiceCatalog, Voice.qwen)
        XCTAssertEqual(state.voice(for: .zh).id, "serena")
        XCTAssertEqual(state.voice(for: .en).id, "aiden")
        XCTAssertEqual(state.selectedVoice.id, "serena")
        XCTAssertEqual(state.voicesForSettingsLanguage.map(\.id), ["serena"])
        XCTAssertFalse(state.hasVoiceChoice(for: .zh))
        XCTAssertFalse(state.hasVoiceChoice(for: .en))
        state.selectVoice(try XCTUnwrap(Voice.voice(id: "zm_055")))
        XCTAssertEqual(state.voice(for: .zh).id, "serena", "not one of Qwen's voices")
        state.selectVoice(Voice.qwen[0])
        XCTAssertEqual(store.string(forKey: "voice_zh"), "zm_009", "Qwen's voice is never stored")
        XCTAssertEqual(store.string(forKey: "voice_en"), "bf_emma")

        state.setEngine(.kokoro)
        XCTAssertEqual(state.voiceCatalog, Voice.all)
        XCTAssertEqual(state.voice(for: .zh).id, "zm_009")
        XCTAssertEqual(state.voice(for: .en).id, "bf_emma")
    }

    /// Speeds stay per document language with Qwen; it is time-stretched, never synthesized again.
    func testSpeedsStayPerLanguageAndQwenIsTimeStretched() async {
        store.set(1.5, forKey: "speed_en")
        store.set("qwen", forKey: "engine")
        let state = makeState()
        await startReading("First sentence here. Second one here.", in: state, with: qwen)
        XCTAssertEqual(state.speed, 1.5)
        XCTAssertEqual(output.userSpeed, 1.5)
        XCTAssertEqual(qwen.requests.map(\.voiceID), ["aiden", "aiden"])
        XCTAssertTrue(qwen.requests.allSatisfy { $0.speed == 1.0 })
        state.setSpeed(0.8)
        XCTAssertEqual(store.object(forKey: "speed_en") as? Double, 0.8)
        XCTAssertNil(store.object(forKey: "speed_zh"))
        XCTAssertEqual(output.userSpeed, 0.8)
        await settle()
        XCTAssertEqual(qwen.requests.count, 2, "nothing is synthesized again")
    }

    func testThePreviewUsesTheActiveEngine() async throws {
        store.set("qwen", forKey: "engine")
        let state = makeState()
        state.previewVoice(Voice.qwen[1], inSettings: true)
        await waitUntil { state.previewer.phase == .playing(voiceID: "aiden") }
        let request = try XCTUnwrap(qwen.requests.last)
        XCTAssertEqual(request.voiceID, "aiden")
        XCTAssertEqual(request.text, VoicePreviewer.samples[.en])
        XCTAssertTrue(kokoro.requests.isEmpty)
    }

    // MARK: - Failures

    func testAQwenFailureOffersKokoroFromTheFailedSentence() async throws {
        store.set("qwen", forKey: "engine")
        qwen.failures[0] = TTSError.crashed(status: -9, detail: "")
        let state = makeState()
        submit("第一句话在这里。第二句话也在这里。", in: state)
        await waitUntil { state.errorMessage != nil }
        XCTAssertTrue(state.offersKokoro)
        XCTAssertFalse(state.offersSystemVoice, "Kokoro, not the system voice, stands in for Qwen")
        XCTAssertFalse(state.errorNeedsSetup)
        XCTAssertEqual(state.engineLogURL, URL(fileURLWithPath: "/logs/tts-server-qwen.log"))
        state.showLog()
        XCTAssertTrue(state.errorMessage?.hasSuffix("\nNo log yet at /logs/tts-server-qwen.log") == true)
        XCTAssertTrue(workspace.opened.isEmpty)

        state.useKokoro()
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.offersKokoro)
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertEqual(store.string(forKey: "engine"), "kokoro")
        XCTAssertTrue(state.player.synthesizer === kokoro)
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(kokoro.requests.first?.text, "第一句话在这里。", "from the failed sentence on")
        XCTAssertEqual(kokoro.requests.first?.voiceID, "zf_001")
        await waitUntil { self.qwen.stopCount == 1 }
        XCTAssertEqual(state.engineLogURL, URL(fileURLWithPath: "/logs/tts-server.log"))
    }

    func testRetryAfterAQwenFailureRestartsQwen() async {
        store.set("qwen", forKey: "engine")
        qwen.failures[0] = TTSError.crashed(status: -9, detail: "")
        let state = makeState()
        submit("第一句。第二句。", in: state)
        await waitUntil { state.errorMessage != nil }
        state.retry()
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(qwen.restartCount, 1)
        XCTAssertEqual(kokoro.restartCount, 0)
        XCTAssertEqual(state.engineKind, .qwen)
    }

    func testMissingQwenFilesNeverShowKokorosSetupHint() async {
        store.set("qwen", forKey: "engine")
        qwen.failures[0] = TTSError.resourcesMissing(["Qwen3-TTS model (looked for /hq/models)"])
        let state = makeState()
        submit("Some text.", in: state)
        await waitUntil { state.errorMessage != nil }
        XCTAssertFalse(state.errorNeedsSetup, "high-quality mode is set up in Settings")
        XCTAssertFalse(state.offersSystemVoice)
        XCTAssertTrue(state.offersKokoro)
    }

    /// Kokoro failing still offers the system voice; choosing an engine ends it.
    func testKokoroFailingStillOffersTheSystemVoice() async {
        kokoro.failures[0] = TTSError.serverFatal("model file missing: voices-v1.0.bin")
        let state = makeState()
        submit("第一句。第二句。", in: state)
        await waitUntil { state.errorMessage != nil }
        XCTAssertTrue(state.offersSystemVoice)
        XCTAssertFalse(state.offersKokoro)
        state.useSystemVoice()
        await waitUntil { state.player.state == .playing }
        XCTAssertTrue(state.player.synthesizer === system)

        state.setEngine(.qwen)
        XCTAssertFalse(state.usingSystemVoice)
        XCTAssertTrue(state.player.synthesizer === qwen)
        await waitUntil { state.player.state == .playing && !self.qwen.requests.isEmpty }
    }

    // MARK: - Choosing an engine after a failure

    /// Kokoro's files are missing, then Qwen is chosen in Settings: Kokoro's failure goes with its
    /// setup hint and system-voice offer (no Use Kokoro for Kokoro's own failure), and Qwen reads
    /// the failed sentence, a fresh attempt.
    func testChoosingQwenAfterAKokoroFailureReadsTheFailedSentenceWithQwen() async {
        kokoro.failures[0] = TTSError.resourcesMissing(["Kokoro model files (looked for /rr/models)"])
        let state = makeState()
        submit("第一句话在这里。第二句话也在这里。", in: state)
        await waitUntil { state.errorMessage != nil }
        XCTAssertTrue(state.errorNeedsSetup)
        XCTAssertTrue(state.offersSystemVoice)

        state.setEngine(.qwen)
        XCTAssertNil(state.errorMessage, "the failure was Kokoro's")
        XCTAssertFalse(state.offersKokoro)
        XCTAssertFalse(state.offersSystemVoice)
        XCTAssertFalse(state.errorNeedsSetup)
        XCTAssertEqual(qwen.resetFailureCount, 1, "a fresh attempt")
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(qwen.requests.first?.text, "第一句话在这里。", "from the failed sentence on")
        XCTAssertEqual(state.engineLogURL, URL(fileURLWithPath: "/logs/tts-server-qwen.log"))
        await waitUntil { self.kokoro.stopCount == 1 }
    }

    /// A Qwen failure, then Kokoro chosen in Settings: no system-voice offer for Qwen's error, and
    /// Kokoro reads on from the failed sentence.
    func testChoosingKokoroAfterAQwenFailureReadsOnWithKokoro() async {
        store.set("qwen", forKey: "engine")
        qwen.failures[0] = TTSError.hqUnavailable("missing Python packages: numpy (run ./scripts/install-hq.sh)")
        let state = makeState()
        submit("第一句话在这里。第二句话也在这里。", in: state)
        await waitUntil { state.errorMessage != nil }
        XCTAssertTrue(state.offersKokoro)

        state.setEngine(.kokoro)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.offersSystemVoice, "the failure was Qwen's")
        XCTAssertFalse(state.offersKokoro)
        XCTAssertEqual(kokoro.resetFailureCount, 1)
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(kokoro.requests.first?.text, "第一句话在这里。")
        await waitUntil { self.qwen.stopCount == 1 }
    }

    /// Qwen chosen again after it failed to start: its failure is forgotten (the next request starts
    /// a new server); the banner was Use Kokoro's choice, so it is gone.
    func testChoosingQwenAgainAfterUsingKokoroIsAFreshAttempt() async {
        store.set("qwen", forKey: "engine")
        qwen.failures[0] = TTSError.hqUnavailable("loading the models failed")
        let state = makeState()
        submit("第一句。第二句。", in: state)
        await waitUntil { state.offersKokoro }
        state.useKokoro()
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(qwen.resetFailureCount, 0)
        state.setEngine(.qwen)
        XCTAssertEqual(qwen.resetFailureCount, 1)
        XCTAssertTrue(state.player.synthesizer === qwen)
    }

    /// A failure the user dismissed stays where it stopped; Play reads with the engine chosen.
    func testADismissedFailureIsNotReadAgainOnItsOwn() async {
        kokoro.failures[0] = TTSError.crashed(status: -9, detail: "")
        let state = makeState()
        submit("第一句。第二句。", in: state)
        await waitUntil { state.errorMessage != nil }
        state.dismissError()
        state.setEngine(.qwen)
        await settle()
        XCTAssertTrue(state.player.state.isFailed)
        XCTAssertTrue(qwen.requests.isEmpty)
        XCTAssertNil(state.errorMessage)
        state.player.play()
        await waitUntil { state.player.state == .playing }
        XCTAssertEqual(qwen.requests.first?.text, "第一句。")
    }

    // MARK: - Installing, verifying, uninstalling

    func testAnInstallSelectsQwenAndSaysSoInSettings() async {
        installer.installState = .notInstalled
        shell.isSettingsVisible = true
        let state = makeState()
        state.runInstaller(.install)
        XCTAssertEqual(state.highQualityStatus, .running(.install, InstallerProgress()))
        await waitUntil { self.installer.started == [.install] }
        let progress = InstallerProgress(stepName: "model", stepIndex: 3, stepCount: 6, file: "model.safetensors",
                                         bytesDone: 1_200_000_000, bytesTotal: 2_400_000_000)
        installer.state = .running(.install, progress)
        XCTAssertEqual(state.highQualityStatus, .running(.install, progress))
        XCTAssertFalse(state.canChooseQwen)

        installer.finish(as: .finished, onDisk: .installed(installation))
        XCTAssertEqual(state.engineKind, .qwen)
        XCTAssertEqual(store.string(forKey: "engine"), "qwen")
        XCTAssertTrue(state.player.synthesizer === qwen)
        XCTAssertEqual(made, [installation])
        XCTAssertEqual(
            state.settingsNotice,
            SettingsNotice(section: .highQuality, message: "High-quality mode is installed. ReadRead now reads with Qwen3-TTS.",
                           isError: false))
        XCTAssertNil(state.notice)
        XCTAssertEqual(state.highQualityStatus, .installed(installation))
    }

    func testAnInstallEndingWhileSettingsIsClosedIsThePanelsNotice() async {
        installer.installState = .notInstalled
        let state = makeState()
        state.runInstaller(.install)
        await waitUntil { self.installer.started == [.install] }
        installer.finish(as: .finished, onDisk: .installed(installation))
        XCTAssertEqual(state.notice, "High-quality mode is installed. ReadRead now reads with Qwen3-TTS.")
        XCTAssertNil(state.settingsNotice)
        XCTAssertEqual(state.engineKind, .qwen)
    }

    func testAnInstallThatLeavesNothingUsableSaysWhy() async {
        installer.installState = .notInstalled
        shell.isSettingsVisible = true
        let state = makeState()
        state.runInstaller(.install)
        await waitUntil { self.installer.started == [.install] }
        installer.finish(as: .finished, onDisk: .damaged("install.json lists no 1.7b model"))
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertEqual(
            state.settingsNotice,
            SettingsNotice(section: .highQuality,
                           message: "The installer finished, but high-quality mode cannot be used: install.json lists no 1.7b model",
                           isError: true))
        XCTAssertEqual(state.highQualityStatus, .damaged("install.json lists no 1.7b model"))
    }

    /// An install over a working one (Repair after a failed Verify) may rebuild the venv Qwen runs
    /// from: the player leaves Qwen for Kokoro, and Qwen's server stops before the installer starts.
    func testAnInstallOverAWorkingOneStopsQwenFirst() async {
        store.set("qwen", forKey: "engine")
        qwen.holdStop = true
        let state = makeState()
        await startReading(in: state, with: qwen)
        state.runInstaller(.install)
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertTrue(state.player.synthesizer === kokoro)
        XCTAssertEqual(state.highQualityStatus, .running(.install, InstallerProgress()))
        XCTAssertFalse(state.canChooseQwen)
        await waitUntil { self.qwen.stopCount == 1 }
        await settle()
        XCTAssertTrue(installer.started.isEmpty, "the installer waits for Qwen's server to stop")
        await waitUntil { state.player.state == .playing && self.kokoro.requests.count >= 1 }

        qwen.releaseStop()
        await waitUntil { self.installer.started == [.install] }
        installer.finish(as: .finished, onDisk: .installed(updated))
        XCTAssertEqual(state.engineKind, .qwen)
        XCTAssertEqual(made, [installation, updated], "a new installation gets a new engine")
        XCTAssertTrue(state.player.synthesizer === qwenEngines[1])
        await waitUntil { state.player.state == .playing && !self.qwenEngines[1].requests.isEmpty }
        await waitUntil { self.kokoro.stopCount == 1 }
    }

    func testUninstallSwitchesToKokoroAndStopsQwenBeforeTheInstallerRuns() async {
        store.set("qwen", forKey: "engine")
        shell.isSettingsVisible = true
        qwen.holdStop = true
        let state = makeState()
        await startReading(in: state, with: qwen)
        state.runInstaller(.uninstall)
        XCTAssertEqual(state.engineKind, .kokoro, "Kokoro first")
        XCTAssertTrue(state.player.synthesizer === kokoro)
        XCTAssertEqual(store.string(forKey: "engine"), "kokoro")
        XCTAssertEqual(state.highQualityStatus, .running(.uninstall, InstallerProgress()))
        XCTAssertFalse(state.canChooseQwen)
        await waitUntil { self.qwen.stopCount == 1 }
        await settle()
        XCTAssertTrue(installer.started.isEmpty)
        await waitUntil { state.player.state == .playing && !self.kokoro.requests.isEmpty }

        qwen.releaseStop()
        await waitUntil { self.installer.started == [.uninstall] }
        installer.finish(as: .finished, onDisk: .notInstalled)
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertEqual(state.highQualityStatus, .notInstalled)
        XCTAssertFalse(state.canChooseQwen)
        XCTAssertEqual(
            state.settingsNotice,
            SettingsNotice(section: .highQuality, message: "High-quality mode was uninstalled.", isError: false))
        XCTAssertEqual(qwen.stopCount, 1)
        XCTAssertEqual(kokoro.stopCount, 0, "Kokoro reads on")

        state.runInstaller(.install)
        await waitUntil { self.installer.started == [.uninstall, .install] }
        installer.finish(as: .finished, onDisk: .installed(installation))
        XCTAssertEqual(made, [installation, installation], "an engine for the new install")
        XCTAssertTrue(state.player.synthesizer === qwenEngines[1])
    }

    func testVerifyKeepsReadingWithQwen() async {
        store.set("qwen", forKey: "engine")
        shell.isSettingsVisible = true
        let state = makeState()
        state.runInstaller(.check)
        XCTAssertEqual(installer.started, [.check], "nothing to stop first")
        XCTAssertEqual(state.highQualityStatus, .running(.check, InstallerProgress()))
        XCTAssertEqual(state.engineKind, .qwen)
        XCTAssertTrue(state.canChooseQwen)
        installer.finish(as: .finished)
        XCTAssertEqual(
            state.settingsNotice,
            SettingsNotice(section: .highQuality, message: "High-quality mode is intact: every file was verified.",
                           isError: false))
        XCTAssertEqual(state.engineKind, .qwen)
        XCTAssertEqual(state.highQualityStatus, .installed(installation))
        await settle()
        XCTAssertEqual(qwen.stopCount, 0)
        XCTAssertEqual(made.count, 1)
    }

    func testAVerifyThatFindsDamageFallsBackToKokoro() async {
        store.set("qwen", forKey: "engine")
        shell.isSettingsVisible = true
        let state = makeState()
        state.runInstaller(.check)
        installer.finish(as: .failed, message: "a model file does not match its pin",
                         onDisk: .damaged("the model folder is missing"))
        XCTAssertEqual(state.highQualityStatus, .failed(.check, message: "a model file does not match its pin"))
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertNil(store.object(forKey: "engine"))
        XCTAssertEqual(
            state.settingsNotice?.message,
            "High-quality mode cannot be used (the model folder is missing), so ReadRead reads with Kokoro. Repair it in Settings › Advanced › High-quality mode.")
        XCTAssertNil(state.notice)
        await waitUntil { self.qwen.stopCount == 1 }
    }

    /// Settings open: the section shows the failure itself (Try Again); closed: the panel says it.
    func testFailuresAndCancelsShowInTheSectionOrInThePanel() async {
        installer.installState = .notInstalled
        shell.isSettingsVisible = true
        let state = makeState()
        state.runInstaller(.install)
        await waitUntil { self.installer.started.count == 1 }
        installer.finish(as: .failed, message: "pip install failed (exit 1)")
        XCTAssertEqual(state.highQualityStatus, .failed(.install, message: "pip install failed (exit 1)"))
        XCTAssertNil(state.settingsNotice, "the section says it, with Try Again")
        XCTAssertNil(state.notice)

        shell.isSettingsVisible = false
        state.runInstaller(.install)
        await waitUntil { self.installer.started.count == 2 }
        XCTAssertEqual(state.highQualityStatus, .running(.install, InstallerProgress()))
        installer.finish(as: .failed, message: "pip install failed (exit 1)")
        XCTAssertEqual(state.notice, "Installing high-quality mode failed: pip install failed (exit 1)")

        state.runInstaller(.install)
        await waitUntil { self.installer.started.count == 3 }
        state.cancelInstaller()
        XCTAssertEqual(installer.cancelCount, 1)
        XCTAssertEqual(state.highQualityStatus, .cancelled(.install))
        XCTAssertEqual(state.notice, "Cancelled. Installing again resumes where it stopped.")
    }

    func testCancellingBeforeTheInstallerStartsStartsNothing() async {
        store.set("qwen", forKey: "engine")
        shell.isSettingsVisible = true
        qwen.holdStop = true
        let state = makeState()
        state.runInstaller(.uninstall)
        XCTAssertEqual(state.highQualityStatus, .running(.uninstall, InstallerProgress()))
        await waitUntil { self.qwen.stopCount == 1 }
        state.cancelInstaller()
        XCTAssertEqual(state.highQualityStatus, .installed(installation))
        XCTAssertEqual(
            state.settingsNotice, SettingsNotice(section: .highQuality, message: "Uninstalling was cancelled.", isError: false))
        qwen.releaseStop()
        await settle()
        XCTAssertTrue(installer.started.isEmpty)
        XCTAssertEqual(installer.cancelCount, 0, "nothing ran to cancel")
        XCTAssertTrue(state.canChooseQwen, "Qwen can be chosen again")
        XCTAssertEqual(state.engineKind, .qwen, "and is: nothing was removed")
        XCTAssertEqual(store.string(forKey: "engine"), "qwen")
        XCTAssertTrue(state.player.synthesizer === qwen)
    }

    /// A Repair over a working install that is cancelled or fails before it changed anything, or an
    /// uninstall cancelled before its removal: install.json still says installed, so the Qwen choice
    /// they set aside comes back. One that stopped half way (install.json.prev: damaged) cannot.
    func testAnInstallerRunThatDoesNotFinishGivesTheQwenChoiceBack() async {
        store.set("qwen", forKey: "engine")
        let state = makeState()
        state.runInstaller(.install)
        XCTAssertEqual(state.engineKind, .kokoro)
        await waitUntil { self.installer.started == [.install] }
        installer.finish(as: .cancelled)
        XCTAssertEqual(state.engineKind, .qwen)
        XCTAssertEqual(store.string(forKey: "engine"), "qwen")
        XCTAssertTrue(state.player.synthesizer === qwen)

        state.runInstaller(.install)
        await waitUntil { self.installer.started.count == 2 }
        installer.finish(as: .failed, message: "a download failed")
        XCTAssertEqual(state.engineKind, .qwen)

        state.runInstaller(.uninstall)
        await waitUntil { self.installer.started.count == 3 }
        state.cancelInstaller()
        XCTAssertEqual(state.engineKind, .qwen)

        state.runInstaller(.install)
        await waitUntil { self.installer.started.count == 4 }
        installer.finish(as: .cancelled, onDisk: .damaged("The last install or repair has not finished."))
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertEqual(store.string(forKey: "engine"), "kokoro")
        XCTAssertFalse(state.canChooseQwen)

        // Kokoro was the engine: a run that does not finish leaves it.
        installer.onDisk = .installed(installation)
        state.runInstaller(.install)
        await waitUntil { self.installer.started.count == 5 }
        installer.finish(as: .cancelled)
        XCTAssertEqual(state.engineKind, .kokoro)
    }

    /// Settings opening finds the Qwen install gone: said under High-quality mode (the window is
    /// not visible yet), not in the panel.
    func testAFallbackFoundWhenSettingsOpensIsSaidInSettings() {
        store.set("qwen", forKey: "engine")
        let state = makeState()
        installer.onDisk = .notInstalled
        state.openSettings()
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertEqual(
            state.settingsNotice,
            SettingsNotice(section: .highQuality,
                           message: "High-quality mode is no longer installed, so ReadRead reads with Kokoro.", isError: true))
        XCTAssertNil(state.notice)
        XCTAssertEqual(shell.calls, [.showSettings])
    }

    /// Uninstall… for an install, intact or damaged; Remove Downloaded Files… for what an install
    /// that never finished left; nothing without files or an HQ home.
    func testWhatUninstallingWouldRemove() {
        let state = makeState()
        XCTAssertEqual(state.highQualityRemoval, .install)
        installer.installState = .damaged("/hq/venv is incomplete (an install or repair did not finish).")
        XCTAssertEqual(state.highQualityRemoval, .install)
        installer.installState = .notInstalled
        XCTAssertEqual(state.highQualityRemoval, .nothing)
        installer.hasLeftoverFiles = true
        XCTAssertEqual(state.highQualityRemoval, .leftovers)
        installer.installState = .damaged(HQInstallation.emptyHomeMessage)
        XCTAssertEqual(state.highQualityRemoval, .nothing)
    }

    func testAnotherOperationWaitsForTheOneRunning() async {
        let state = makeState()
        state.runInstaller(.check)
        state.runInstaller(.uninstall)
        state.runInstaller(.install)
        await settle()
        XCTAssertEqual(installer.started, [.check])
    }

    func testShowInstallerLog() throws {
        shell.isSettingsVisible = true
        let state = makeState()
        state.showInstallerLog()
        XCTAssertEqual(
            state.settingsNotice,
            SettingsNotice(section: .highQuality, message: "No log yet at /logs/hq-install.log", isError: false))
        XCTAssertTrue(workspace.opened.isEmpty)
        state.showInstallerLog(inSettings: .files)
        XCTAssertEqual(state.settingsNotice?.section, .files, "under the button that asked")

        let log = try makeTemporaryDirectory().appending(path: "hq-install.log")
        try Data("log".utf8).write(to: log)
        installer.logFileURL = log
        state.showInstallerLog(inSettings: .files)
        XCTAssertEqual(workspace.opened, [log])
        XCTAssertNil(state.settingsNotice)
    }

    func testWithoutAnInstallerNothingCanBeInstalled() async {
        let state = makeState(installer: NoHQInstaller(logDirectory: directories.logDirectory))
        XCTAssertEqual(state.highQualityStatus, .notInstalled)
        XCTAssertFalse(state.canChooseQwen)
        state.runInstaller(.install)
        await waitUntil {
            state.highQualityStatus == .failed(.install, message: "This build of ReadRead has no installer for high-quality mode.")
        }
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertEqual(state.notice, "Installing high-quality mode failed: This build of ReadRead has no installer for high-quality mode.")
    }

    // MARK: - The installation changing under the app

    func testAChangedInstallationGetsANewQwenEngine() async {
        store.set("qwen", forKey: "engine")
        let state = makeState()
        XCTAssertEqual(made, [installation])
        installer.onDisk = .installed(updated)
        state.openSettings()
        XCTAssertEqual(shell.calls, [.showSettings])
        XCTAssertEqual(made, [installation, updated])
        XCTAssertTrue(state.player.synthesizer === qwenEngines[1])
        await waitUntil { self.qwen.stopCount == 1 }

        state.openSettings()
        XCTAssertEqual(made.count, 2, "the same installation keeps its engine")
    }

    func testAnInstallThatWentAwayIsNoticedBeforeTheNextDocument() async {
        store.set("qwen", forKey: "engine")
        let state = makeState()
        installer.onDisk = .notInstalled
        submit("第一句。第二句。", in: state)
        XCTAssertEqual(state.engineKind, .kokoro)
        XCTAssertNil(store.object(forKey: "engine"))
        XCTAssertEqual(state.notice, "High-quality mode is no longer installed, so ReadRead reads with Kokoro.")
        await waitUntil { state.player.state == .playing }
        XCTAssertFalse(kokoro.requests.isEmpty)
        XCTAssertTrue(qwen.requests.isEmpty)
        await waitUntil { self.qwen.stopCount == 1 }
    }

    // MARK: - Status, restart, termination

    func testStatusRestartAndLogAreTheActiveEngines() async {
        store.set("qwen", forKey: "engine")
        let state = makeState()
        qwen.status = .starting
        kokoro.status = .ready
        XCTAssertEqual(state.engineStatus, .starting)
        XCTAssertEqual(state.engineStatusText, "Starting…")
        state.restartEngine()
        await waitUntil { self.qwen.restartCount == 1 }
        XCTAssertEqual(kokoro.restartCount, 0)
        state.showLog(inSettings: true)
        XCTAssertEqual(
            state.settingsNotice,
            SettingsNotice(section: .files, message: "No log yet at /logs/tts-server-qwen.log", isError: false))
    }

    func testTerminationStopsTheInstallerAndBothEngines() async {
        store.set("qwen", forKey: "engine")
        let state = makeState()
        await startReading(in: state, with: qwen)
        state.shutdown()
        XCTAssertEqual(installer.shutdownCount, 1)
        XCTAssertEqual(qwen.shutdownCount, 1)
        XCTAssertEqual(kokoro.shutdownCount, 1)
        XCTAssertEqual(state.player.state, .idle)
    }
}
