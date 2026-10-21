import AppKit
import Foundation

/// The windows and the app around AppState (the app delegate): AppState asks, the shell acts.
@MainActor
protocol AppShell: AnyObject {
    func showPanel()
    func hidePanel()
    func showSettings()
    /// Bring the app forward: only for what needs it (the file picker, Settings), never to show
    /// the panel (R4-20).
    func activateApp()
    func quit()
    /// The Settings window is open: a Settings action's result is shown there, else in the panel.
    var isSettingsVisible: Bool { get }
}

/// Finder and the default apps, behind a protocol for the tests.
@MainActor
protocol WorkspaceOpening: AnyObject {
    func open(_ url: URL)
    func reveal(_ url: URL)
}

@MainActor
final class SystemWorkspace: WorkspaceOpening {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

/// The app's state: the input field and the one document load that runs at a time
/// (InputParser → the document loader), the player (PlaybackController), the engine it reads with
/// (Kokoro, or Qwen3-TTS from the high-quality install, or the system voice standing in), the error
/// banner, the preferences (a voice and a speed per language, the engine, the reading view's
/// settings, the language choice per document for this run) and what the Settings window changes,
/// the high-quality installer included. Every user action from the keyboard, the status item's
/// menu, drops, Services and "Open With" ends up here (`perform`, `handle`); the windows themselves
/// belong to the `AppShell`.
@Observable
@MainActor
final class AppState {
    // MARK: - Input

    /// A URL, a file path or text to read.
    var urlInput = ""
    var showFilePicker = false
    /// A document is being fetched or read: Return is ignored, Cancel stops it (R1-15, H9).
    private(set) var isLoading = false
    /// Counts the times the panel was shown: the URL field takes the focus in input mode (R4-11).
    private(set) var panelShowCount = 0
    /// Counts the sentences the user chose (tap, ←/→, the transport buttons): the reading view
    /// follows the reading again (R4-16).
    private(set) var navigationCount = 0

    // MARK: - Reading

    let player: PlaybackController

    var document: ReadingDocument? { player.document }
    var hasDocument: Bool { player.document != nil }

    // MARK: - Engines

    /// The Kokoro server (`TTSService` in the app).
    let engine: any SpeechSynthesizer
    /// The engine documents are read with (`engine` in UserDefaults): Qwen3-TTS only while the
    /// high-quality install is usable, else Kokoro. The system voice, when in use, stands in for it.
    private(set) var engineKind: EngineKind
    /// Runs install-hq.sh and reads install.json (Settings › Advanced › High-quality mode).
    let installer: any HQInstalling
    /// Reading with the system voice instead of the engine (the engine could not run).
    private(set) var usingSystemVoice = false
    @ObservationIgnored private let makeSystemVoice: @MainActor () -> any SpeechSynthesizer
    @ObservationIgnored private var systemVoice: (any SpeechSynthesizer)?
    @ObservationIgnored private let makeQwenEngine: QwenEngineFactory?
    /// The Qwen engine, made on first use for the installation it runs from.
    private var qwen: QwenEngine?
    /// An install or uninstall waiting for the Qwen server to stop first.
    private var pendingInstallerOperation: InstallerOperation?
    @ObservationIgnored private var installerStart: Task<Void, Never>?
    /// Qwen was the engine when an install or uninstall set it aside for Kokoro: one that does not
    /// finish (failed, cancelled) gives it back while Qwen can still be chosen.
    @ObservationIgnored private var qwenBeforeInstaller = false

    private struct QwenEngine {
        let installation: HQInstallation
        let synthesizer: any SpeechSynthesizer
    }

    /// The engine's synthesizer (Kokoro or Qwen), whatever the system voice does meanwhile.
    var activeEngine: any SpeechSynthesizer {
        engineKind == .qwen ? qwen?.synthesizer ?? engine : engine
    }

    var engineStatus: SpeechEngineStatus { player.synthesizer.status }

    // MARK: - Settings

    let preferences: VoicePreferences
    let readingPreferences: ReadingPreferences
    /// The language of the last document opened (also stored, to prewarm its model).
    private(set) var lastLanguage: SpeechLanguage
    /// Body text size of the reading view, in points (⌘+ / ⌘−, persisted).
    private(set) var fontSize: Double
    /// The reading view follows the sentence being read.
    private(set) var autoFollow: Bool
    private(set) var extractionMode: ExtractionMode
    private(set) var loginItemStatus: LoginItemStatus

    // MARK: - Voice preview

    let previewer: VoicePreviewer

    // MARK: - Errors and notices

    /// A load that failed (fetch, file, nothing to read) or another message for the banner.
    private(set) var loadError: (any Error)?
    /// "No log yet at …" under the banner's error, which it does not replace (the setup hint,
    /// the system-voice offer and Retry stay those of the error).
    private(set) var logNotice: String?
    /// The player failure the user dismissed (`PlaybackController.failureCount`).
    private var dismissedFailure = 0
    /// A message without Retry: an empty clipboard, a file type ReadRead cannot read, a preview
    /// from the panel that failed, an installer result while Settings is closed.
    private(set) var notice: String?
    /// The result of the last Settings action (R4-21), shown under the section it came from:
    /// the panel's banner may be hidden while Settings is open. Cleared when Settings closes.
    private(set) var settingsNotice: SettingsNotice?
    /// The voice preview playing was started in Settings (its failure is shown there).
    @ObservationIgnored private var previewStartedInSettings = false

    // MARK: - Collaborators

    /// The windows (the app delegate); nil in tests that do not need it.
    @ObservationIgnored weak var shell: (any AppShell)?
    @ObservationIgnored private let loadDocument: @Sendable (ReadingInput) async throws -> ReadingDocument
    @ObservationIgnored private let fileExists: (String) -> Bool
    @ObservationIgnored private let pasteboard: any PasteboardAccess
    @ObservationIgnored private let workspace: any WorkspaceOpening
    @ObservationIgnored private let loginItem: any LoginItemControlling
    @ObservationIgnored private let directories: RuntimeDirectories
    @ObservationIgnored private let clearArticleCacheAction: @MainActor () async throws -> Void
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var lastInput: ReadingInput?
    /// The language choice per document (by position key), for this run only.
    @ObservationIgnored private var languageChoices: [String: LanguageChoice] = [:]

    /// - Parameters:
    ///   - qwenEngine: makes the Qwen engine for an installation (the app: `TTSService.qwen`);
    ///     nil: Qwen3-TTS cannot be used.
    ///   - installer: the high-quality installer (the app: `HQInstaller`, the install-hq.sh runner); nil:
    ///     `NoHQInstaller` (nothing installed, nothing to run).
    ///   - loadDocument: input → document, off the main actor (`DocumentLoader.load`).
    ///   - previewOutput: the voice preview's own output (not the document's).
    ///   - clearArticleCache: Settings › Advanced › Clear Cached Articles (the app passes
    ///     `ArticleCache.removeAll`; a no-op by default, for the tests).
    init(
        engine: any SpeechSynthesizer,
        qwenEngine: QwenEngineFactory? = nil,
        installer: (any HQInstalling)? = nil,
        output: any AudioOutput,
        defaults: any PreferencesStore = UserDefaults.standard,
        loadDocument: @escaping @Sendable (ReadingInput) async throws -> ReadingDocument = { try await DocumentLoader().load($0) },
        positions: (any ReadingPositionStoring)? = nil,
        nowPlaying: (any NowPlayingPublishing)? = nil,
        systemVoice: @escaping @MainActor () -> any SpeechSynthesizer = { AppleSpeechSynthesizer() },
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        pasteboard: (any PasteboardAccess)? = nil,
        workspace: (any WorkspaceOpening)? = nil,
        loginItem: (any LoginItemControlling)? = nil,
        previewOutput: (any AudioOutput)? = nil,
        directories: RuntimeDirectories = RuntimeDirectories(
            environment: ProcessInfo.processInfo.environment, homeDirectory: NSHomeDirectory()),
        clearArticleCache: @escaping @MainActor () async throws -> Void = {}
    ) {
        self.engine = engine
        let preferences = VoicePreferences(defaults: defaults)
        preferences.migrate()
        self.preferences = preferences
        let reading = ReadingPreferences(defaults: defaults)
        self.readingPreferences = reading
        self.lastLanguage = preferences.lastLanguage ?? .zh
        self.fontSize = reading.fontSize
        self.autoFollow = reading.autoFollow
        self.extractionMode = defaults.string(forKey: ExtractionMode.defaultsKey).flatMap(ExtractionMode.init(rawValue:))
            ?? .localFirst
        self.loadDocument = loadDocument
        self.makeSystemVoice = systemVoice
        self.fileExists = fileExists
        self.pasteboard = pasteboard ?? SystemPasteboard()
        self.workspace = workspace ?? SystemWorkspace()
        let loginItem = loginItem ?? MainAppLoginItem()
        self.loginItem = loginItem
        self.loginItemStatus = loginItem.status
        self.directories = directories
        self.clearArticleCacheAction = clearArticleCache
        self.defaults = defaults

        // Qwen3-TTS when it was chosen and its install is usable; a choice whose install went
        // away falls back to Kokoro once, with a notice (the preference is reset).
        let installer = installer ?? NoHQInstaller(logDirectory: directories.logDirectory)
        installer.refresh()
        var chosenQwen: QwenEngine?
        var fallbackNotice: String?
        if preferences.engine == .qwen {
            if let installation = installer.installState.installation, let qwenEngine {
                chosenQwen = QwenEngine(installation: installation, synthesizer: qwenEngine(installation))
            } else {
                preferences.engine = nil
                fallbackNotice = Self.fallbackMessage(for: installer.installState)
            }
        }
        self.installer = installer
        self.makeQwenEngine = qwenEngine
        self.qwen = chosenQwen
        self.engineKind = chosenQwen == nil ? .kokoro : .qwen

        player = PlaybackController(synthesizer: chosenQwen?.synthesizer ?? engine, output: output, positions: positions,
                                    nowPlaying: nowPlaying, sleep: sleep)
        previewer = VoicePreviewer(
            output: previewOutput ?? AudioQueuePlayer(),
            cacheDirectory: URL(fileURLWithPath: directories.cacheDirectory).appending(path: "previews"))
        player.restore(settings: settings(for: lastLanguage, choice: .auto))
        notice = fallbackNotice
        previewer.pauseDocument = { [weak self] in
            guard let player = self?.player, player.state == .playing || player.state == .buffering else { return false }
            player.pause()
            return true
        }
        previewer.resumeDocument = { [weak self] in
            guard let player = self?.player, player.state == .paused else { return }
            player.play()
        }
        previewer.onError = { [weak self] error in
            guard let self else { return }
            let message = String(localized: "The voice preview failed: \(Self.message(for: error))")
            if previewStartedInSettings {
                settingsNotice = SettingsNotice(section: .preview, message: message, isError: true)
            } else {
                notice = message
            }
        }
        installer.onFinish = { [weak self] operation, outcome in
            self?.installerFinished(operation, outcome)
        }
    }

    @ObservationIgnored private let defaults: any PreferencesStore

    /// The app: the Kokoro server, the Qwen engine of the high-quality install (a server of its
    /// own) and the install-hq.sh runner, the audio device, UserDefaults (where the loader reads
    /// the extraction mode too), positions.json, Now Playing, the article cache.
    convenience init() {
        self.init(
            engine: TTSService.live(),
            qwenEngine: { TTSService.qwen(installation: $0) },
            installer: HQInstaller(),
            output: AudioQueuePlayer(),
            positions: ReadingPositionStore(fileURL: ReadingPositionStore.defaultFileURL()),
            nowPlaying: NowPlayingController(),
            clearArticleCache: { try ArticleCache.live().removeAll() }
        )
    }

    /// App termination: save the position, stop the audio, the servers and the installer.
    func shutdown() {
        cancelLoad()
        installerStart?.cancel()
        installerStart = nil
        previewer.stop()
        player.stop()
        engine.shutdown()
        qwen?.synthesizer.shutdown()
        systemVoice?.shutdown()
        installer.shutdown()
    }

    // MARK: - Loading

    /// Return in the field or the Read button. Ignored while a load runs.
    func submit() {
        guard !isLoading, let input = InputParser.parse(urlInput, fileExists: fileExists) else { return }
        load(input)
    }

    func openFile(url: URL) {
        load(.file(url))
    }

    /// Load `input` and start reading it. A load still running is cancelled first.
    func load(_ input: ReadingInput) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        lastInput = input
        loadError = nil
        logNotice = nil
        notice = nil
        isLoading = true
        if engineKind == .qwen {
            // Reading with Qwen needs its install still there (it is read again: no process).
            installer.refresh()
            reconcileEngine()
        }
        // The model loads while the page downloads.
        player.synthesizer.prewarm(for: lastLanguage)
        let loadDocument = self.loadDocument
        loadTask = Task { [weak self] in
            let result: Result<ReadingDocument, any Error>
            do {
                result = .success(try await loadDocument(input))
            } catch {
                result = .failure(error)
            }
            self?.finishLoad(result, generation: generation)
        }
    }

    func cancelLoad() {
        guard isLoading else { return }
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        isLoading = false
    }

    private func finishLoad(_ result: Result<ReadingDocument, any Error>, generation: Int) {
        guard generation == loadGeneration else { return }  // cancelled or replaced
        loadTask = nil
        isLoading = false
        switch result {
        case .success(let document):
            open(document)
        case .failure(let error):
            if !(error is CancellationError) { loadError = error }
        }
    }

    private func open(_ document: ReadingDocument) {
        previewer.stop()
        let choice = languageChoices[document.positionKey] ?? .auto
        let language = document.language(under: choice)
        remember(language)
        player.open(document, settings: settings(for: language, choice: choice), autoplay: true)
    }

    /// Back to the input field: the position is saved and the document forgotten.
    func closeDocument() {
        player.close()
        loadError = nil
        logNotice = nil
        notice = nil
        urlInput = ""
        player.restore(settings: settings(for: lastLanguage, choice: .auto))
    }

    // MARK: - Drops, the clipboard, Services, Open With (R4-13, R4-06)

    /// Files, links or text from anywhere: the first readable file, else a link, else the text.
    func handle(_ items: PasteboardItems) {
        switch DropResolver.resolve(items, fileExists: fileExists) {
        case .read(let input):
            load(input)
        case .unsupportedFile(let url):
            notice = String(localized: "ReadRead cannot read “\(url.lastPathComponent)”: not a text, Markdown, web page, Word, RTF, OpenDocument, PDF or EPUB file.")
        case .nothing:
            notice = String(localized: "There is nothing to read in what was dropped.")
        }
    }

    /// ⌘V outside the text field, the paste button and the status item's Read Clipboard.
    func readClipboard() {
        let items = pasteboard.readItems()
        guard !items.isEmpty else {
            notice = String(localized: "The clipboard is empty.")
            return
        }
        handle(items)
    }

    /// The file picker; the app is brought forward for it (a sheet of an inactive app has no focus).
    func requestOpenFile() {
        shell?.activateApp()
        shell?.showPanel()
        showFilePicker = true
    }

    /// The panel was ordered in.
    func panelDidShow() {
        panelShowCount += 1
    }

    /// A keyboard shortcut, a status item menu entry or a toolbar button.
    func perform(_ command: AppCommand) {
        switch command {
        case .togglePlayPause: player.toggle()
        case .previousSentence:
            navigationCount += 1
            player.previous()
        case .nextSentence:
            navigationCount += 1
            player.next()
        case .stop: player.stop()
        case .readClipboard: readClipboard()
        case .openFile: requestOpenFile()
        case .openSettings: openSettings()
        case .hidePanel: shell?.hidePanel()
        case .quit: shell?.quit()
        case .largerText: setFontSize(fontSize + ReadingPreferences.fontSizeStep)
        case .smallerText: setFontSize(fontSize - ReadingPreferences.fontSizeStep)
        case .defaultTextSize: setFontSize(ReadingPreferences.defaultFontSize)
        case .edit: break  // the panel sends it to the focused text field
        }
    }

    func openSettings() {
        refreshForSettings()
        shell?.showSettings()
    }

    /// Settings is about to show: the login item and the high-quality install as they are now. A
    /// Qwen choice whose install went away is reported under High-quality mode (the window is not
    /// visible yet, so `report` would send it to the panel).
    func refreshForSettings() {
        refreshLoginItemStatus()
        installer.refresh()
        reconcileEngine(reportsInSettings: true)
    }

    /// A sentence tapped in the reading view: read from there.
    func seek(to unit: Int) {
        navigationCount += 1
        player.seek(to: unit)
    }

    /// The header's file name: the file in Finder.
    func revealInFinder(_ url: URL) {
        workspace.reveal(url)
    }

    // MARK: - Settings (user edits)

    /// The language the reading mode's voice picker and speed slider are for: the open
    /// document's, else the last one's.
    var settingsLanguage: SpeechLanguage {
        player.document?.language(under: player.settings.languageChoice) ?? lastLanguage
    }

    /// The engine's voices, in picker order: Kokoro's, or Qwen's one per language.
    var voiceCatalog: [Voice] { Voice.catalog(for: engineKind) }
    var voicesForSettingsLanguage: [Voice] { Voice.voices(for: settingsLanguage, in: voiceCatalog) }
    var selectedVoice: Voice { player.settings.voice(for: settingsLanguage) }
    var speed: Double { player.settings.speed }
    var languageChoice: LanguageChoice { player.settings.languageChoice }

    /// The voice for `language` (input mode and Settings show both languages, R4-07).
    func voice(for language: SpeechLanguage) -> Voice {
        player.settings.voice(for: language)
    }

    /// The engine has more than one voice for `language` to choose from (Qwen has one).
    func hasVoiceChoice(for language: SpeechLanguage) -> Bool {
        Voice.voices(for: language, in: voiceCatalog).count > 1
    }

    /// The speed for documents in `language`.
    func speed(for language: SpeechLanguage) -> Double {
        language == settingsLanguage ? player.settings.speed : preferences.speed(for: language)
    }

    /// A voice of the engine's catalog; Kokoro's is saved for its language (Qwen's is the only one).
    func selectVoice(_ voice: Voice) {
        guard voiceCatalog.contains(voice) else { return }
        if engineKind == .kokoro { preferences.saveVoice(voice) }
        player.userSetVoice(voice)
    }

    /// The reading mode's slider: the speed of the document's language.
    func setSpeed(_ speed: Double) {
        setSpeed(speed, for: settingsLanguage)
    }

    /// Saved for `language`; heard at once when that is the language being read.
    func setSpeed(_ speed: Double, for language: SpeechLanguage) {
        preferences.saveSpeed(speed, for: language)
        if language == settingsLanguage {
            player.userSetSpeed(speed)
        }
    }

    /// Auto / 中文 / English for the open document; the speed of the language it is now read
    /// in applies.
    func setLanguageChoice(_ choice: LanguageChoice) {
        guard let document = player.document, choice != player.settings.languageChoice else { return }
        languageChoices[document.positionKey] = choice
        let language = document.language(under: choice)
        remember(language)
        player.userSetSpeed(preferences.speed(for: language))
        player.userSetLanguageChoice(choice)
    }

    /// ▶ next to a voice: its sample through the current engine; the document pauses meanwhile.
    /// `inSettings`: the button is in the Settings window, where a failure is then shown.
    func previewVoice(_ voice: Voice, inSettings: Bool = false) {
        previewStartedInSettings = inSettings
        if inSettings, settingsNotice?.section == .preview { settingsNotice = nil }
        previewer.toggle(voice, synthesizer: player.synthesizer)
    }

    func setFontSize(_ size: Double) {
        let clamped = ReadingPreferences.clampedFontSize(size)
        guard clamped != fontSize else { return }
        fontSize = clamped
        readingPreferences.fontSize = clamped
    }

    var canEnlargeText: Bool { fontSize < ReadingPreferences.fontSizeRange.upperBound }
    var canShrinkText: Bool { fontSize > ReadingPreferences.fontSizeRange.lowerBound }

    func setAutoFollow(_ follows: Bool) {
        autoFollow = follows
        readingPreferences.autoFollow = follows
    }

    /// Settings › Reading: how web pages are read (the loader reads it at each load).
    func setExtractionMode(_ mode: ExtractionMode) {
        extractionMode = mode
        defaults.set(mode.rawValue, forKey: ExtractionMode.defaultsKey)
    }

    /// The panel was resized (its size is restored next time).
    func savePanelSize(_ size: CGSize) {
        readingPreferences.panelSize = size
    }

    var panelSize: CGSize { readingPreferences.panelSize }

    private func settings(for language: SpeechLanguage, choice: LanguageChoice) -> PlaybackSettings {
        PlaybackSettings(voices: engineVoices(), speed: preferences.speed(for: language), languageChoice: choice)
    }

    /// The voices the engine reads with: Qwen's one per language, else the Kokoro voices chosen.
    private func engineVoices() -> [SpeechLanguage: Voice] {
        Dictionary(uniqueKeysWithValues: SpeechLanguage.allCases.map { language in
            let voice = engineKind == .qwen ? Voice.voices(for: language, in: Voice.qwen).first : nil
            return (language, voice ?? preferences.voice(for: language))
        })
    }

    private func remember(_ language: SpeechLanguage) {
        lastLanguage = language
        preferences.lastLanguage = language
    }

    // MARK: - Launch at login (R4-15)

    func refreshLoginItemStatus() {
        loginItemStatus = loginItem.status
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            clearSettingsNotice(.launchAtLogin)
        } catch {
            settingsNotice = SettingsNotice(
                section: .launchAtLogin,
                message: String(localized: "Launch at login could not be changed: \(Self.message(for: error))"), isError: true)
        }
        refreshLoginItemStatus()
    }

    func openLoginItemsSettings() {
        loginItem.openSystemSettings()
    }

    // MARK: - Advanced

    /// The engine's state, for Settings › Advanced.
    var engineStatusText: String {
        switch activeEngine.status {
        case .idle: String(localized: "Not running (starts when needed)")
        case .starting: String(localized: "Starting…")
        case .ready: String(localized: "Running")
        case .failed(let message): String(localized: "Failed: \(message)")
        }
    }

    /// Restart the engine (Kokoro or Qwen); a failed reading goes on once it is back.
    func restartEngine() {
        if !usingSystemVoice, player.state.isFailed {
            logNotice = nil
            player.retry()
            return
        }
        let engine = activeEngine
        clearSettingsNotice(.engine)
        Task { [weak self] in
            do {
                try await engine.restart()
            } catch {
                self?.settingsNotice = SettingsNotice(
                    section: .engine, message: String(localized: "The voice engine did not restart: \(Self.message(for: error))"),
                    isError: true)
            }
        }
    }

    /// Settings › Advanced › Clear Cached Articles.
    func clearArticleCache() {
        let action = clearArticleCacheAction
        Task { [weak self] in
            do {
                try await action()
                self?.settingsNotice = SettingsNotice(
                    section: .articleCache, message: String(localized: "Cached articles were removed."), isError: false)
            } catch {
                self?.settingsNotice = SettingsNotice(
                    section: .articleCache,
                    message: String(localized: "Cached articles could not be removed: \(Self.message(for: error))"), isError: true)
            }
        }
    }

    /// The user pronunciation file (READREAD_USER_LEXICON): created empty if missing, then shown
    /// in Finder.
    var userLexiconURL: URL { URL(fileURLWithPath: directories.userLexicon) }

    func revealUserLexicon() {
        let url = userLexiconURL
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(Self.emptyLexicon.utf8).write(to: url, options: .withoutOverwriting)
            } catch {
                settingsNotice = SettingsNotice(
                    section: .files,
                    message: String(localized: "The pronunciation file could not be created: \(Self.message(for: error))"),
                    isError: true)
                return
            }
        }
        clearSettingsNotice(.files)
        workspace.reveal(url)
    }

    /// The lexicon format with no entries (see `readread_tts/lexicon.py`).
    static let emptyLexicon = "{\"version\": 1, \"entries\": []}\n"

    // MARK: - The engine (Settings › Advanced)

    /// Qwen3-TTS can be chosen: it is installed, and no install or uninstall is running.
    var canChooseQwen: Bool {
        guard canRunQwen, installer.installState.installation != nil else { return false }
        if pendingInstallerOperation != nil { return false }
        if case .running(let operation, _) = installer.state, operation != .check { return false }
        return true
    }

    /// This build can run Qwen3-TTS (the app's engine factory is wired in).
    var canRunQwen: Bool { makeQwenEngine != nil }

    /// An installer operation runs, or waits for the Qwen server to stop first.
    var installerIsBusy: Bool { pendingInstallerOperation != nil || installer.state.isRunning }

    /// Settings › Advanced › Engine (a user edit): the player switches (the sentence being read
    /// starts again with the new engine, a pause stays), the engine left behind stops (Qwen frees
    /// 3–4 GB) and the new one loads when a document is open. Qwen only while `canChooseQwen`.
    /// Choosing an engine also ends the system voice, and is a fresh attempt: a failure that kept
    /// the chosen engine from starting is forgotten, and a reading that failed (its banner still
    /// up) goes on from the failed sentence with it.
    func setEngine(_ kind: EngineKind) {
        if kind == .qwen, !canChooseQwen { return }
        preferences.engine = kind
        guard kind != engineKind || usingSystemVoice else { return }
        let resumes = loadError == nil && player.state.isFailed && player.failureCount != dismissedFailure
        switchEngine(to: kind, freshAttempt: true)
        if resumes, player.state.isFailed { player.play() }
    }

    /// The banner's Use Kokoro after a Qwen failure: Kokoro reads on from the failed sentence (the
    /// choice is saved; Settings can choose Qwen again).
    func useKokoro() {
        let resume = player.state.isFailed
        dismissError()
        setEngine(.kokoro)
        if resume, player.state.isFailed { player.play() }
    }

    /// The player reads with `kind` from now on; the engine left behind stops (`stopsPrevious`).
    /// A player failure on screen was the engine left behind's (its offers, its log), so it is
    /// dismissed; `freshAttempt` (a user's choice) also forgets the new engine's failure.
    private func switchEngine(to kind: EngineKind, stopsPrevious: Bool = true, freshAttempt: Bool = false) {
        let previous = activeEngine
        if kind == .qwen {
            guard let installation = installer.installState.installation,
                  qwenSynthesizer(for: installation) != nil else { return }
        }
        engineKind = kind
        usingSystemVoice = false
        previewer.stop()
        if player.state.isFailed {
            dismissedFailure = player.failureCount
            logNotice = nil
        }
        let current = activeEngine
        if freshAttempt { current.resetFailure() }
        player.setSynthesizer(current, voices: engineVoices())
        if stopsPrevious, previous !== current {
            Task { await previous.stop() }
        }
        if hasDocument { current.prewarm(for: settingsLanguage) }
    }

    /// The Qwen engine for `installation`: made on first use, and again when the installation
    /// changed (the caller stops the old one if it was reading).
    private func qwenSynthesizer(for installation: HQInstallation) -> (any SpeechSynthesizer)? {
        if let qwen, qwen.installation == installation { return qwen.synthesizer }
        guard let makeQwenEngine else { return nil }
        let synthesizer = makeQwenEngine(installation)
        qwen = QwenEngine(installation: installation, synthesizer: synthesizer)
        return synthesizer
    }

    /// The engine against install.json (after an installer run, when Settings opens, before a
    /// load): Qwen with nothing usable installed falls back to Kokoro (the preference is reset,
    /// with a notice: under High-quality mode when `reportsInSettings`); a changed installation
    /// gets a new Qwen engine.
    private func reconcileEngine(reportsInSettings: Bool = false) {
        guard engineKind == .qwen else { return }
        if let installation = installer.installState.installation, makeQwenEngine != nil {
            if qwen?.installation != installation { switchEngine(to: .qwen) }
            return
        }
        preferences.engine = nil
        switchEngine(to: .kokoro)
        let message = Self.fallbackMessage(for: installer.installState)
        if reportsInSettings {
            settingsNotice = SettingsNotice(section: .highQuality, message: message, isError: true)
        } else {
            report(message, isError: true)
        }
    }

    /// Why a Qwen choice reads with Kokoro instead.
    private static func fallbackMessage(for state: HQInstallState) -> String {
        switch state {
        case .notInstalled:
            String(localized: "High-quality mode is no longer installed, so ReadRead reads with Kokoro.")
        case .damaged(let message) where state.hasNoHome:
            // Nothing to repair: the message says what to change.
            String(localized: "High-quality mode cannot be used (\(message)), so ReadRead reads with Kokoro.")
        case .damaged(let message):
            String(localized: "High-quality mode cannot be used (\(message)), so ReadRead reads with Kokoro. Repair it in Settings › Advanced › High-quality mode.")
        case .installed:
            String(localized: "This build of ReadRead cannot run high-quality mode, so it reads with Kokoro.")
        }
    }

    // MARK: - High-quality mode (Settings › Advanced)

    /// What Settings › Advanced › High-quality mode shows: the operation running or how the last
    /// one failed, else what is installed.
    var highQualityStatus: HighQualityStatus {
        if let pendingInstallerOperation { return .running(pendingInstallerOperation, InstallerProgress()) }
        switch installer.state {
        case .running(let operation, let progress): return .running(operation, progress)
        case .failed(let operation, let message): return .failed(operation, message: message)
        case .cancelled(let operation): return .cancelled(operation)
        case .idle, .finished: break
        }
        switch installer.installState {
        case .notInstalled: return .notInstalled
        case .installed(let installation): return .installed(installation)
        case .damaged(let message): return .damaged(message)
        }
    }

    /// What Uninstall… would remove: an install (installed or damaged), the files an install that
    /// never finished left (Remove Downloaded Files…), or nothing (no files, or no HQ home).
    var highQualityRemoval: HighQualityRemoval {
        switch installer.installState {
        case .installed: .install
        case .damaged: installer.installState.hasNoHome ? .nothing : .install
        case .notInstalled: installer.hasLeftoverFiles ? .leftovers : .nothing
        }
    }

    /// Install (also Repair and Try Again), Verify or Uninstall. An install may rebuild the venv
    /// the Qwen server runs from and an uninstall removes it, so for both the player leaves Qwen
    /// for Kokoro and the Qwen server stops first.
    func runInstaller(_ operation: InstallerOperation) {
        guard !installer.state.isRunning, pendingInstallerOperation == nil else { return }
        clearSettingsNotice(.highQuality)
        guard operation != .check else {
            installer.start(operation)
            return
        }
        let qwenEngine = qwen?.synthesizer
        qwenBeforeInstaller = engineKind == .qwen
        if engineKind == .qwen {
            preferences.engine = .kokoro
            switchEngine(to: .kokoro, stopsPrevious: false)
        }
        pendingInstallerOperation = operation
        installerStart = Task { [weak self] in
            await qwenEngine?.stop()
            guard !Task.isCancelled, let self else { return }
            self.installerStart = nil
            self.pendingInstallerOperation = nil
            self.installer.start(operation)
        }
    }

    /// Cancel: install-hq.sh stops at once; installing again resumes.
    func cancelInstaller() {
        if let installerStart, let operation = pendingInstallerOperation {
            installerStart.cancel()
            self.installerStart = nil
            pendingInstallerOperation = nil
            report(Self.cancelledMessage(operation), isError: false)
            restoreQwenChoice()
            return
        }
        installer.cancel()
    }

    /// The installer's log (the stderr of every run) in the default app; "no log yet" under the
    /// section the button is in.
    func showInstallerLog(inSettings section: SettingsNotice.Section = .highQuality) {
        let url = installer.logFileURL
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            clearSettingsNotice(section)
            workspace.open(url)
        } else {
            settingsNotice = SettingsNotice(
                section: section, message: String(localized: "No log yet at \(url.path(percentEncoded: false))"),
                isError: false)
        }
    }

    /// An operation ended (install.json was read again): a new install is chosen, results are
    /// reported, an install that went away leaves Qwen.
    private func installerFinished(_ operation: InstallerOperation, _ outcome: InstallerState) {
        installer.refresh()
        switch outcome {
        case .finished:
            switch operation {
            case .install:
                if canChooseQwen {
                    setEngine(.qwen)
                    report(String(localized: "High-quality mode is installed. ReadRead now reads with Qwen3-TTS."), isError: false)
                } else {
                    report(String(localized: "The installer finished, but high-quality mode cannot be used: \(Self.unusableReason(installer.installState))"),
                           isError: true)
                }
            case .check:
                report(String(localized: "High-quality mode is intact: every file was verified."), isError: false)
            case .uninstall:
                qwen = nil
                report(String(localized: "High-quality mode was uninstalled."), isError: false)
            }
        case .failed(_, let message):
            // Settings shows the failure in the section itself (with Try Again).
            report(Self.failureMessage(operation, message), isError: true, inSettings: false)
            restoreQwenChoice()
        case .cancelled:
            report(Self.cancelledMessage(operation), isError: false, inSettings: false)
            restoreQwenChoice()
        case .idle, .running:
            break
        }
        qwenBeforeInstaller = false
        reconcileEngine()
    }

    /// An install or uninstall that did not finish: the Qwen choice it set aside comes back while
    /// Qwen can still be chosen (an install it stopped on the way reads as damaged: not then).
    private func restoreQwenChoice() {
        guard qwenBeforeInstaller else { return }
        qwenBeforeInstaller = false
        if canChooseQwen { setEngine(.qwen) }
    }

    /// An installer result under Settings › Advanced › High-quality mode while Settings is open
    /// (`inSettings` false: the section's own state says it there), else as the panel's notice.
    private func report(_ message: String, isError: Bool, inSettings: Bool = true) {
        if shell?.isSettingsVisible == true {
            if inSettings { settingsNotice = SettingsNotice(section: .highQuality, message: message, isError: isError) }
        } else {
            notice = message
        }
    }

    static func failureMessage(_ operation: InstallerOperation, _ message: String) -> String {
        switch operation {
        case .install: String(localized: "Installing high-quality mode failed: \(message)")
        case .check: String(localized: "Verifying high-quality mode failed: \(message)")
        case .uninstall: String(localized: "Uninstalling high-quality mode failed: \(message)")
        }
    }

    static func cancelledMessage(_ operation: InstallerOperation) -> String {
        switch operation {
        case .install: String(localized: "Cancelled. Installing again resumes where it stopped.")
        case .check: String(localized: "Verifying was cancelled.")
        case .uninstall: String(localized: "Uninstalling was cancelled.")
        }
    }

    private static func unusableReason(_ state: HQInstallState) -> String {
        switch state {
        case .damaged(let message): message
        case .notInstalled: String(localized: "install.json was not written")
        case .installed: String(localized: "this build cannot run it")
        }
    }

    // MARK: - System voice

    /// The engine cannot run: read with the system voice, from the failed sentence on.
    func useSystemVoice() {
        guard !usingSystemVoice else { return }
        let voice = systemVoice ?? makeSystemVoice()
        systemVoice = voice
        usingSystemVoice = true
        let resume = player.state.isFailed
        dismissError()
        previewer.stop()
        player.setSynthesizer(voice)
        if resume { player.play() }
    }

    /// Back to the engine's voices.
    func useEngineVoice() {
        guard usingSystemVoice else { return }
        usingSystemVoice = false
        previewer.stop()
        player.setSynthesizer(activeEngine, voices: engineVoices())
    }

    // MARK: - Errors

    /// The banner: a failed load, else a player failure that was not dismissed (and the log
    /// notice under it).
    var errorMessage: String? {
        let message: String
        if let loadError {
            message = Self.message(for: loadError)
        } else if case .failed(let failure) = player.state, player.failureCount != dismissedFailure {
            message = failure
        } else {
            return nil
        }
        return logNotice.map { message + "\n" + $0 } ?? message
    }

    /// What the banner shows: the error, else the notice.
    var bannerMessage: String? { errorMessage ?? notice }

    /// Kokoro's files are missing: the setup hint applies (never to Qwen, whose install is set up
    /// in Settings).
    var errorNeedsSetup: Bool { engineKind == .kokoro && ((bannerError as? TTSError)?.isResourcesMissing ?? false) }

    /// Kokoro cannot run: offer the system voice.
    var offersSystemVoice: Bool {
        engineKind == .kokoro && !usingSystemVoice && ((bannerError as? TTSError)?.isServerFailure ?? false)
    }

    /// Qwen failed: offer Kokoro, from the failed sentence on.
    var offersKokoro: Bool {
        engineKind == .qwen && !usingSystemVoice && loadError == nil && player.state.isFailed
            && player.failureCount != dismissedFailure
    }

    private var bannerError: (any Error)? {
        if let loadError { return loadError }
        if player.state.isFailed, player.failureCount != dismissedFailure { return player.lastError }
        return nil
    }

    /// Retry the failed load, or let the player retry (restarting the server when it was the
    /// problem) at the failed sentence.
    func retry() {
        logNotice = nil
        if loadError != nil {
            if let lastInput {
                load(lastInput)
            } else {
                loadError = nil
            }
        } else if player.state.isFailed {
            player.retry()
        }
    }

    func dismissError() {
        loadError = nil
        logNotice = nil
        notice = nil
        dismissedFailure = player.failureCount
    }

    func showError(_ error: any Error) {
        loadError = error
    }

    /// The banner's Copy button.
    func copyBannerMessage() {
        guard let message = bannerMessage else { return }
        pasteboard.write(message)
    }

    /// The engine's log (Kokoro's or Qwen's, whichever reads).
    var engineLogURL: URL? { activeEngine.logFileURL }

    /// Show Log, in the banner or (`inSettings`) in Settings › Advanced, where "no log yet" is
    /// then shown: the log of the engine reading (Qwen's or Kokoro's).
    func showLog(inSettings: Bool = false) {
        guard let url = engineLogURL else { return }
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            if inSettings { clearSettingsNotice(.files) }
            workspace.open(url)
        } else {
            let message = String(localized: "No log yet at \(url.path(percentEncoded: false))")
            if inSettings {
                settingsNotice = SettingsNotice(section: .files, message: message, isError: false)
            } else {
                logNotice = message
            }
        }
    }

    // MARK: - Settings notices (R4-21)

    /// The Settings window closed: its notices go with it.
    func clearSettingsNotice() {
        settingsNotice = nil
    }

    private func clearSettingsNotice(_ section: SettingsNotice.Section) {
        if settingsNotice?.section == section { settingsNotice = nil }
    }

    static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// A Settings action's result, under the section of the button or toggle that caused it.
struct SettingsNotice: Equatable, Sendable {
    enum Section: Equatable, Sendable {
        /// General › Launch at login.
        case launchAtLogin
        /// Voices: ▶ failed.
        case preview
        /// Advanced › Voice engine: Restart Engine.
        case engine
        /// Advanced › High-quality mode: Install, Verify, Uninstall.
        case highQuality
        /// Advanced › Files: Show Log, Show in Finder.
        case files
        /// Advanced › Article cache.
        case articleCache
    }

    let section: Section
    let message: String
    let isError: Bool
}

/// Settings › Advanced › High-quality mode: an operation running or how the last one ended
/// (failed, cancelled), else the install as install.json says.
enum HighQualityStatus: Equatable, Sendable {
    case notInstalled
    case running(InstallerOperation, InstallerProgress)
    case installed(HQInstallation)
    case damaged(String)
    case failed(InstallerOperation, message: String)
    case cancelled(InstallerOperation)
}

/// What Settings › Advanced › High-quality mode can remove (`AppState.highQualityRemoval`).
enum HighQualityRemoval: Equatable, Sendable {
    case nothing
    /// An install, intact or damaged: Uninstall….
    case install
    /// What an install that never finished left: Remove Downloaded Files….
    case leftovers
}

/// High-quality mode where no installer is wired in (the tests' default; the app passes
/// `HQInstaller`): nothing is installed, and an operation fails at once, saying so.
@Observable
@MainActor
final class NoHQInstaller: HQInstalling {
    private(set) var state: InstallerState = .idle
    let installState: HQInstallState = .notInstalled
    let hasLeftoverFiles = false
    let logFileURL: URL
    @ObservationIgnored var onFinish: (@MainActor (InstallerOperation, InstallerState) -> Void)?

    init(logDirectory: String) {
        logFileURL = URL(fileURLWithPath: logDirectory).appending(path: "hq-install.log")
    }

    func refresh() {}

    func start(_ operation: InstallerOperation) {
        state = .failed(operation, message: String(localized: "This build of ReadRead has no installer for high-quality mode."))
        onFinish?(operation, state)
    }

    func cancel() {}
    func shutdown() {}
}

extension PlaybackController.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
