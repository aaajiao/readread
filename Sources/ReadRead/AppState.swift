import Foundation
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
    var playbackState: PlaybackState = .idle
    var textChunks: [String] = []
    var currentChunkIndex = 0

    var isPlaying: Bool { playbackState == .playing }
    var isPaused: Bool { playbackState == .paused }
    var hasContent: Bool { !currentText.isEmpty }
    var progress: Double {
        guard !textChunks.isEmpty else { return 0 }
        return Double(currentChunkIndex) / Double(textChunks.count)
    }

    // MARK: - Settings
    var selectedVoice = "af_heart"
    var speed: Double = 1.0
    var autoDetectLanguage = true
    var selectedLanguage = "en-us"

    // MARK: - TTS Server
    enum ServerState: Equatable {
        case notStarted
        case starting
        case ready
        case error(String)
    }
    var serverState: ServerState = .notStarted

    // MARK: - Error
    var errorMessage: String?

    // MARK: - Services
    let ttsEngine = TTSEngine()
    let audioPlayer = AudioPlayerService()

    // MARK: - Tasks
    private var readingTask: Task<Void, Never>?

    // MARK: - Server

    func startTTSServer() async {
        serverState = .starting
        do {
            try await ttsEngine.start()
            serverState = .ready
        } catch {
            serverState = .error(error.localizedDescription)
        }
    }

    func stopTTSServer() {
        ttsEngine.stop()
    }

    // MARK: - Fetch & Read

    func fetchURL() async {
        var input = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return }

        if !input.contains("://") {
            input = "https://" + input
        }

        guard let url = URL(string: input) else {
            errorMessage = "Invalid URL"
            return
        }

        playbackState = .loading
        errorMessage = nil

        do {
            let content = try await WebExtractor.extractFromURL(url)
            currentTitle = content.title
            currentText = content.text
            currentDomain = content.domain

            if autoDetectLanguage {
                // Always detect from actual text — metadata can be wrong
                let lang = detectLanguage(content.text)
                selectedLanguage = lang
                selectedVoice = defaultVoice(for: lang)
            }

            startReading()
        } catch {
            playbackState = .idle
            errorMessage = error.localizedDescription
        }
    }

    func openFile(url: URL) async {
        playbackState = .loading
        errorMessage = nil

        do {
            let content = try await WebExtractor.readFile(url)
            currentTitle = content.title
            currentText = content.text
            currentDomain = ""

            if autoDetectLanguage {
                let detected = detectLanguage(content.text)
                selectedLanguage = detected
                selectedVoice = defaultVoice(for: detected)
            }

            startReading()
        } catch {
            playbackState = .idle
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Playback Controls

    func startReading() {
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
        readingTask?.cancel()
        audioPlayer.stop()
        playbackState = .playing
        readingTask = Task {
            await readChunks(from: currentChunkIndex)
        }
    }

    func togglePlayPause() {
        switch playbackState {
        case .playing:
            audioPlayer.pause()
            playbackState = .paused
        case .paused:
            audioPlayer.resume()
            playbackState = .playing
        case .idle where hasContent:
            startReading()
        default:
            break
        }
    }

    func stop() {
        readingTask?.cancel()
        readingTask = nil
        audioPlayer.stop()
        playbackState = .idle
        currentChunkIndex = 0
    }

    func nextChunk() {
        guard currentChunkIndex < textChunks.count - 1 else { return }
        audioPlayer.stop()
        currentChunkIndex += 1

        readingTask?.cancel()
        playbackState = .playing
        readingTask = Task {
            await readChunks(from: currentChunkIndex)
        }
    }

    func previousChunk() {
        guard currentChunkIndex > 0 else { return }
        audioPlayer.stop()
        currentChunkIndex -= 1

        readingTask?.cancel()
        playbackState = .playing
        readingTask = Task {
            await readChunks(from: currentChunkIndex)
        }
    }

    // MARK: - Private

    private func readChunks(from startIndex: Int = 0) async {
        // Pre-fetch first chunk
        var pendingAudio: Task<Data, any Error>? = Task {
            try await ttsEngine.synthesize(
                text: textChunks[startIndex],
                voice: selectedVoice, speed: speed, lang: selectedLanguage
            )
        }

        for index in startIndex..<textChunks.count {
            guard !Task.isCancelled else {
                pendingAudio?.cancel()
                break
            }

            currentChunkIndex = index

            do {
                // Await current chunk's audio (already pre-fetching or fetch now)
                let audioData: Data
                if let pending = pendingAudio {
                    audioData = try await pending.value
                } else {
                    audioData = try await ttsEngine.synthesize(
                        text: textChunks[index],
                        voice: selectedVoice, speed: speed, lang: selectedLanguage
                    )
                }

                guard !Task.isCancelled else {
                    pendingAudio?.cancel()
                    break
                }

                // Start pre-fetching next chunk BEFORE playing current
                if index + 1 < textChunks.count {
                    let nextText = textChunks[index + 1]
                    let voice = selectedVoice
                    let spd = speed
                    let lang = selectedLanguage
                    pendingAudio = Task {
                        try await ttsEngine.synthesize(
                            text: nextText, voice: voice, speed: spd, lang: lang
                        )
                    }
                } else {
                    pendingAudio = nil
                }

                try await audioPlayer.playAndWait(data: audioData)
            } catch {
                pendingAudio?.cancel()
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
                return
            }
        }

        if !Task.isCancelled {
            playbackState = .idle
        }
    }

    private func splitIntoChunks(_ text: String, maxLength: Int = 200) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
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

    private func detectLanguage(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1000)))

        guard let lang = recognizer.dominantLanguage else { return "en-us" }

        switch lang {
        case .simplifiedChinese, .traditionalChinese: return "zh"
        case .japanese: return "ja"
        case .spanish: return "es"
        case .french: return "fr"
        case .hindi: return "hi"
        case .italian: return "it"
        case .portuguese: return "pt"
        default: return "en-us"
        }
    }

    private func mapLanguageCode(_ code: String) -> String {
        let prefix = code.prefix(2)
        switch prefix {
        case "zh": return "zh"
        case "ja": return "ja"
        case "es": return "es"
        case "fr": return "fr"
        case "hi": return "hi"
        case "it": return "it"
        case "pt": return "pt"
        case "en": return "en-us"
        default: return "en-us"
        }
    }

    private func defaultVoice(for language: String) -> String {
        switch language {
        case "zh": return "zf_xiaobei"
        case "ja": return "jf_alpha"
        case "es": return "ef_dora"
        case "fr": return "ff_siwis"
        default: return "af_heart"
        }
    }
}
