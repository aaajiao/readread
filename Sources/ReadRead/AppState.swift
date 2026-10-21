import AppKit
import Foundation

/// The app's state: the input field and the one document load that runs at a time
/// (InputParser → DocumentLoader), the player (PlaybackController), the error banner, and the
/// preferences: a voice per language, a speed per document language, and the language choice
/// per document (in memory, for this run).
@Observable
@MainActor
final class AppState {
    // MARK: - Input

    /// A URL, a file path or text to read.
    var urlInput = ""
    var showFilePicker = false
    /// A document is being fetched or read: Return is ignored, Cancel stops it (R1-15, H9).
    private(set) var isLoading = false

    // MARK: - Reading

    let player: PlaybackController

    var document: ReadingDocument? { player.document }
    var hasDocument: Bool { player.document != nil }

    // MARK: - Engines

    /// The Kokoro server (`TTSService` in the app).
    let engine: any SpeechSynthesizer
    /// Reading with the system voice instead of the engine (the engine could not run).
    private(set) var usingSystemVoice = false
    @ObservationIgnored private let makeSystemVoice: @MainActor () -> any SpeechSynthesizer
    @ObservationIgnored private var systemVoice: (any SpeechSynthesizer)?

    var engineStatus: SpeechEngineStatus { player.synthesizer.status }

    // MARK: - Settings

    let preferences: VoicePreferences
    /// The language of the last document opened (also stored, to prewarm its model).
    private(set) var lastLanguage: SpeechLanguage

    // MARK: - Errors

    /// A load that failed (fetch, file, nothing to read) or another message for the banner.
    private(set) var loadError: (any Error)?
    /// "No log yet at …" under the banner's error, which it does not replace (the setup hint,
    /// the system-voice offer and Retry stay those of the error).
    private(set) var logNotice: String?
    /// The player failure the user dismissed (`PlaybackController.failureCount`).
    private var dismissedFailure = 0

    // MARK: - Loading

    @ObservationIgnored private let loader: DocumentLoader
    @ObservationIgnored private let fileExists: (String) -> Bool
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var lastInput: ReadingInput?
    /// The language choice per document (by position key), for this run only.
    @ObservationIgnored private var languageChoices: [String: LanguageChoice] = [:]

    init(
        engine: any SpeechSynthesizer,
        output: any AudioOutput,
        defaults: any PreferencesStore = UserDefaults.standard,
        loader: DocumentLoader = DocumentLoader(),
        positions: (any ReadingPositionStoring)? = nil,
        nowPlaying: (any NowPlayingPublishing)? = nil,
        systemVoice: @escaping @MainActor () -> any SpeechSynthesizer = { AppleSpeechSynthesizer() },
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.engine = engine
        let preferences = VoicePreferences(defaults: defaults)
        preferences.migrate()
        self.preferences = preferences
        self.lastLanguage = preferences.lastLanguage ?? .zh
        self.loader = loader
        self.makeSystemVoice = systemVoice
        self.fileExists = fileExists
        player = PlaybackController(synthesizer: engine, output: output, positions: positions,
                                    nowPlaying: nowPlaying, sleep: sleep)
        player.restore(settings: settings(for: lastLanguage, choice: .auto))
    }

    /// The app: the Kokoro server, the audio device, UserDefaults, positions.json, Now Playing.
    convenience init() {
        self.init(
            engine: TTSService.live(),
            output: AudioQueuePlayer(),
            positions: ReadingPositionStore(fileURL: ReadingPositionStore.defaultFileURL()),
            nowPlaying: NowPlayingController()
        )
    }

    /// App termination: save the position, stop the audio and the server.
    func shutdown() {
        cancelLoad()
        player.stop()
        engine.shutdown()
        systemVoice?.shutdown()
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
        isLoading = true
        // The model loads while the page downloads.
        player.synthesizer.prewarm(for: lastLanguage)
        let loader = self.loader
        loadTask = Task { [weak self] in
            let result: Result<ReadingDocument, any Error>
            do {
                result = .success(try await loader.load(input))
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
        urlInput = ""
        player.restore(settings: settings(for: lastLanguage, choice: .auto))
    }

    // MARK: - Settings (user edits)

    /// The language the voice picker and the speed slider are for: the open document's,
    /// else the last one's.
    var settingsLanguage: SpeechLanguage {
        player.document?.language(under: player.settings.languageChoice) ?? lastLanguage
    }

    var voicesForSettingsLanguage: [Voice] { Voice.voices(for: settingsLanguage) }
    var selectedVoice: Voice { player.settings.voice(for: settingsLanguage) }
    var speed: Double { player.settings.speed }
    var languageChoice: LanguageChoice { player.settings.languageChoice }

    func selectVoice(_ voice: Voice) {
        preferences.saveVoice(voice)
        player.userSetVoice(voice)
    }

    func setSpeed(_ speed: Double) {
        preferences.saveSpeed(speed, for: settingsLanguage)
        player.userSetSpeed(speed)
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

    private func settings(for language: SpeechLanguage, choice: LanguageChoice) -> PlaybackSettings {
        PlaybackSettings(
            voices: Dictionary(uniqueKeysWithValues: SpeechLanguage.allCases.map { ($0, preferences.voice(for: $0)) }),
            speed: preferences.speed(for: language),
            languageChoice: choice
        )
    }

    private func remember(_ language: SpeechLanguage) {
        lastLanguage = language
        preferences.lastLanguage = language
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
        player.setSynthesizer(voice)
        if resume { player.play() }
    }

    /// Back to the engine's voices.
    func useEngineVoice() {
        guard usingSystemVoice else { return }
        usingSystemVoice = false
        player.setSynthesizer(engine)
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

    /// The engine's files are missing: the setup hint applies.
    var errorNeedsSetup: Bool { (bannerError as? TTSError)?.isResourcesMissing ?? false }

    /// The engine cannot run: offer the system voice.
    var offersSystemVoice: Bool { !usingSystemVoice && ((bannerError as? TTSError)?.isServerFailure ?? false) }

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
        dismissedFailure = player.failureCount
    }

    func showError(_ error: any Error) {
        loadError = error
    }

    func showLog() {
        guard let url = engine.logFileURL else { return }
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            NSWorkspace.shared.open(url)
        } else {
            logNotice = "No log yet at \(url.path(percentEncoded: false))"
        }
    }

    static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

extension PlaybackController.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
