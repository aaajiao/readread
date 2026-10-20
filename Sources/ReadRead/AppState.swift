import Foundation
import AppKit
import SwiftUI
import NaturalLanguage

@Observable
@MainActor
final class AppState {
    // MARK: - Input
    var urlInput = ""
    var showFilePicker = false

    // MARK: - Content
    var currentTitle = ""
    var currentText = ""
    var currentDomain = ""

    // MARK: - Playback
    enum PlaybackState: Equatable {
        case idle
        case loading
        case playing
        case paused
    }
    var playbackState: PlaybackState = .idle {
        didSet { synthesizer.setPlaybackActive(playbackState == .playing) }
    }
    var textChunks: [String] = []
    var currentChunkIndex = 0
    /// Set when an error interrupted reading: Play (or Retry) synthesizes the
    /// current chunk again instead of resuming a player that has nothing left.
    private(set) var needsResynthesis = false

    var isPlaying: Bool { playbackState == .playing }
    var isPaused: Bool { playbackState == .paused }
    var hasContent: Bool { !currentText.isEmpty }
    var progress: Double {
        guard !textChunks.isEmpty else { return 0 }
        return Double(currentChunkIndex) / Double(textChunks.count)
    }

    // MARK: - Settings
    var selectedVoice: String
    var speed: Double
    /// The text's language (from detection). The picker offers only its voices.
    var selectedLanguage: SpeechLanguage

    var voicesForCurrentLanguage: [Voice] { Voice.voices(for: selectedLanguage) }
    var currentVoice: Voice {
        Voice.voice(id: selectedVoice) ?? Voice.defaultVoice(for: selectedLanguage)
    }

    // MARK: - Error
    var errorMessage: String?
    /// The engine's files are missing: show the setup hint.
    private(set) var errorNeedsSetup = false
    /// The error came from the server lifecycle: Retry restarts the server.
    private(set) var errorIsServerFailure = false

    // MARK: - Services
    let synthesizer: any SpeechSynthesizer
    let audioPlayer: any AudioPlaying
    let preferences: VoicePreferences

    var engineStatus: SpeechEngineStatus { synthesizer.status }

    // MARK: - Tasks
    private(set) var readingTask: Task<Void, Never>?
    private(set) var retryTask: Task<Void, Never>?

    /// The server rejects text over 4000 characters; stay well below.
    static let maxRequestCharacters = 3000

    init(
        synthesizer: any SpeechSynthesizer,
        audioPlayer: any AudioPlaying,
        defaults: any PreferencesStore = UserDefaults.standard
    ) {
        self.synthesizer = synthesizer
        self.audioPlayer = audioPlayer
        let preferences = VoicePreferences(defaults: defaults)
        preferences.migrate()
        self.preferences = preferences
        let language = preferences.lastLanguage ?? .zh
        self.selectedLanguage = language
        self.selectedVoice = preferences.voice(for: language).id
        self.speed = preferences.speed(for: language)
    }

    convenience init() {
        self.init(synthesizer: TTSService.live(), audioPlayer: AudioPlayerService())
    }

    /// App termination: stop audio and the server.
    func shutdown() {
        readingTask?.cancel()
        retryTask?.cancel()
        audioPlayer.stop()
        synthesizer.shutdown()
    }

    // MARK: - Fetch & Read

    func fetchURL() async {
        var input = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return }

        if !input.contains("://") {
            input = "https://" + input
        }

        guard let url = URL(string: input) else {
            showError("Invalid URL")
            return
        }

        cancelRetry()
        playbackState = .loading
        clearError()
        // Load the model while the article downloads.
        synthesizer.prewarm(for: selectedLanguage)

        do {
            let content = try await WebExtractor.extractFromURL(url)
            load(content, domain: content.domain)
        } catch {
            playbackState = .idle
            showError(error)
        }
    }

    func openFile(url: URL) async {
        cancelRetry()
        playbackState = .loading
        clearError()
        synthesizer.prewarm(for: selectedLanguage)

        do {
            let content = try await WebExtractor.readFile(url)
            load(content, domain: "")
        } catch {
            playbackState = .idle
            showError(error)
        }
    }

    private func load(_ content: ExtractedContent, domain: String) {
        currentTitle = content.title
        currentText = content.text
        currentDomain = domain

        // Always detect from the text itself; metadata can be wrong.
        let language = detectLanguage(content.text)
        applyLanguagePreferences(for: language)
        preferences.lastLanguage = language

        startReading()
    }

    // MARK: - Playback Controls

    func startReading() {
        cancelRetry()
        readingTask?.cancel()
        audioPlayer.stop()

        textChunks = splitIntoChunks(currentText)
        currentChunkIndex = 0
        playbackState = .playing

        readingTask = Task {
            await readChunks()
        }
    }

    /// Restart from current chunk with new voice/speed settings
    func restartCurrentChunk() {
        guard isPlaying || isPaused else { return }
        cancelRetry()
        resumeFromCurrentChunk()
    }

    func togglePlayPause() {
        cancelRetry()
        switch playbackState {
        case .playing:
            audioPlayer.pause()
            playbackState = .paused
        case .paused:
            if needsResynthesis {
                resumeFromCurrentChunk()
            } else {
                audioPlayer.resume()
                playbackState = .playing
            }
        case .idle where hasContent:
            if needsResynthesis {
                resumeFromCurrentChunk()
            } else {
                startReading()
            }
        default:
            break
        }
    }

    func stop() {
        cancelRetry()
        readingTask?.cancel()
        readingTask = nil
        audioPlayer.stop()
        needsResynthesis = false
        playbackState = .idle
        currentChunkIndex = 0
    }

    func nextChunk() {
        guard currentChunkIndex < textChunks.count - 1 else { return }
        cancelRetry()
        currentChunkIndex += 1
        resumeFromCurrentChunk()
    }

    func previousChunk() {
        guard currentChunkIndex > 0 else { return }
        cancelRetry()
        currentChunkIndex -= 1
        resumeFromCurrentChunk()
    }

    /// (Re)start reading at `currentChunkIndex`.
    private func resumeFromCurrentChunk() {
        readingTask?.cancel()
        audioPlayer.stop()
        if needsResynthesis { clearError() }
        playbackState = .playing
        let index = currentChunkIndex
        readingTask = Task {
            await readChunks(from: index)
        }
    }

    // MARK: - Errors

    /// Retry after an error: restart the server if it was the problem, then
    /// continue reading where it stopped (or redo the failed fetch). Any other
    /// playback intent (Stop, Play, Next, Previous, new content) cancels a retry
    /// still restarting the server, so it never resumes reading by itself.
    func retry() {
        retryTask?.cancel()
        let restartServer = errorIsServerFailure
        let stoppedOnError = hasContent && needsResynthesis
        clearError()
        retryTask = Task {
            if restartServer {
                do {
                    try await synthesizer.restart()
                } catch is CancellationError {
                    return
                } catch {
                    if !Task.isCancelled { showError(error) }
                    return
                }
            }
            guard !Task.isCancelled else { return }
            retryTask = nil
            if stoppedOnError {
                // Only if still paused on the failed chunk, as the error left it.
                guard playbackState == .paused, needsResynthesis else { return }
                resumeFromCurrentChunk()
            } else if hasContent {
                resumeFromCurrentChunk()
            } else if !urlInput.isEmpty {
                await fetchURL()
            }
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    func showLog() {
        guard let url = synthesizer.logFileURL else { return }
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            NSWorkspace.shared.open(url)
        } else {
            showError("No log yet at \(url.path(percentEncoded: false))")
        }
    }

    func showError(_ error: any Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let ttsError = error as? TTSError
        errorNeedsSetup = ttsError?.isResourcesMissing ?? false
        errorIsServerFailure = ttsError?.isServerFailure ?? false
    }

    func showError(_ message: String) {
        errorMessage = message
        errorNeedsSetup = false
        errorIsServerFailure = false
    }

    func clearError() {
        errorMessage = nil
        errorNeedsSetup = false
        errorIsServerFailure = false
    }

    // MARK: - Language Preferences Persistence

    func saveLanguagePreferences() {
        guard hasContent, let voice = Voice.voice(id: selectedVoice) else { return }
        preferences.save(voice: voice, speed: speed, language: selectedLanguage)
    }

    func applyLanguagePreferences(for language: SpeechLanguage) {
        selectedLanguage = language
        selectedVoice = preferences.voice(for: language).id
        speed = preferences.speed(for: language)
    }

    // MARK: - Private

    private func readChunks(from startIndex: Int = 0) async {
        guard startIndex < textChunks.count else {
            if !Task.isCancelled { playbackState = .idle }
            return
        }
        needsResynthesis = false

        // Capture text and settings now, not when the tasks first run.
        let voice = currentVoice
        let speed = speed
        let chunks = textChunks
        let synthesizer = synthesizer
        func synthesis(_ index: Int) -> Task<SynthesisResult, any Error> {
            let request = SynthesisRequest(text: chunks[index], voice: voice, speed: speed)
            return Task { try await synthesizer.synthesize(request) }
        }

        var pendingAudio: Task<SynthesisResult, any Error>? = synthesis(startIndex)

        for index in startIndex..<chunks.count {
            guard !Task.isCancelled, let pending = pendingAudio else {
                pendingAudio?.cancel()
                return
            }

            currentChunkIndex = index

            do {
                // Cancelling the reading task cancels the in-flight request too.
                let audio = try await withTaskCancellationHandler {
                    try await pending.value
                } onCancel: {
                    pending.cancel()
                }

                guard !Task.isCancelled else { return }

                // Start pre-fetching next chunk BEFORE playing current
                pendingAudio = index + 1 < chunks.count ? synthesis(index + 1) : nil

                try await audioPlayer.playAndWait(data: audio.wav)
            } catch {
                pendingAudio?.cancel()
                if !Task.isCancelled && !(error is CancellationError) {
                    // Stop in a consistent, recoverable state: paused on the failed
                    // chunk; Play or Retry synthesizes it again.
                    audioPlayer.stop()
                    needsResynthesis = true
                    playbackState = .paused
                    showError(error)
                }
                return
            }
        }

        if !Task.isCancelled {
            playbackState = .idle
        }
    }

    func splitIntoChunks(_ text: String, maxLength: Int = 200) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .flatMap { Self.capLength($0, limit: Self.maxRequestCharacters) }
        var chunks: [String] = []
        var current = ""

        for para in paragraphs {
            let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if current.count + trimmed.count > maxLength && !current.isEmpty {
                chunks.append(current)
                current = trimmed
            } else {
                if !current.isEmpty { current += "\n\n" }
                current += trimmed
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks.isEmpty ? [text] : chunks
    }

    /// Split text longer than `limit` Unicode scalars (the server counts Python
    /// characters) at sentence ends; overlong sentences at whitespace, else hard.
    static func capLength(_ text: String, limit: Int) -> [String] {
        guard text.unicodeScalars.count > limit else { return [text] }
        var pieces: [String] = []
        var current = ""
        var currentCount = 0
        func flush() {
            if !current.isEmpty { pieces.append(current) }
            current = ""
            currentCount = 0
        }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var consumed = text.startIndex
        var sentences: [Substring] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // Keep anything between tokens, so no text is ever dropped.
            sentences.append(text[consumed..<range.upperBound])
            consumed = range.upperBound
            return true
        }
        if consumed < text.endIndex { sentences.append(text[consumed...]) }

        for var sentence in sentences {
            while sentence.unicodeScalars.count > limit {
                flush()
                let cut = hardCutIndex(sentence, limit: limit)
                pieces.append(String(sentence[..<cut]))
                sentence = sentence[cut...]
            }
            let count = sentence.unicodeScalars.count
            if currentCount + count > limit { flush() }
            current += sentence
            currentCount += count
        }
        flush()
        return pieces
    }

    /// The last whitespace within `limit` scalars, else the last character
    /// boundary within it.
    private static func hardCutIndex(_ text: Substring, limit: Int) -> String.Index {
        var scalars = 0
        var lastBreak: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let count = character.unicodeScalars.count
            if scalars + count > limit { break }
            scalars += count
            index = text.index(after: index)
            if character.isWhitespace { lastBreak = index }
        }
        if let lastBreak { return lastBreak }
        return index > text.startIndex ? index : text.index(after: text.startIndex)
    }

    /// Interim zh/en detection until the script-census detector lands (Phase 3):
    /// NLLanguageRecognizer restricted to the languages ReadRead reads.
    static let languageConstraints: [NLLanguage] = [.simplifiedChinese, .traditionalChinese, .english]

    func detectLanguage(_ text: String) -> SpeechLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Self.languageConstraints
        recognizer.processString(String(text.prefix(1000)))

        switch recognizer.dominantLanguage {
        case .simplifiedChinese?, .traditionalChinese?: return .zh
        default: return .en
        }
    }
}
