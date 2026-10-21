import CryptoKit
import Foundation

/// ▶ in the voice picker (H8, R4-07): a fixed short sample per language, synthesized through the
/// current engine at speed 1.0 and kept per (engine, voice) in memory and as a WAV under
/// `$READREAD_CACHE_DIR/previews/`. It plays on its own output; the document pauses while it plays
/// and goes on afterwards.
@MainActor
@Observable
final class VoicePreviewer {
    static let samples: [SpeechLanguage: String] = [
        .zh: "你好，这是我的声音。今天我们一起读点什么吧。",
        .en: "Hello, this is my voice. Let's read something together.",
    ]

    enum Phase: Equatable {
        case idle
        case loading(voiceID: String)
        case playing(voiceID: String)

        var voiceID: String? {
            switch self {
            case .idle: nil
            case .loading(let id), .playing(let id): id
            }
        }
    }

    /// The id `AudioOutput.onFinished` reports for a preview.
    static let itemID = -1

    private(set) var phase: Phase = .idle

    @ObservationIgnored private let output: any AudioOutput
    @ObservationIgnored private let cacheDirectory: URL?
    @ObservationIgnored private var memory: [String: Data] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The document was playing when the preview started (it goes on afterwards).
    @ObservationIgnored private var resumesDocument = false
    /// Pause the document; true if it was playing.
    @ObservationIgnored var pauseDocument: () -> Bool = { false }
    @ObservationIgnored var resumeDocument: () -> Void = {}
    @ObservationIgnored var onError: (any Error) -> Void = { _ in }

    init(output: any AudioOutput, cacheDirectory: URL?) {
        self.output = output
        self.cacheDirectory = cacheDirectory
        output.onFinished = { [weak self] id in
            if id == Self.itemID { self?.finished() }
        }
        output.onFailure = { [weak self] error in self?.failed(error) }
    }

    /// ▶ on a voice: play its sample; ■ (the voice already previewing) stops it.
    func toggle(_ voice: Voice, synthesizer: any SpeechSynthesizer) {
        if phase.voiceID == voice.id {
            stop()
            return
        }
        cancelCurrent()
        if !resumesDocument { resumesDocument = pauseDocument() }
        phase = .loading(voiceID: voice.id)
        let key = Self.cacheKey(engineID: synthesizer.engineID, voiceID: voice.id, language: voice.language)
        if let wav = memory[key] ?? readFromDisk(key) {
            memory[key] = wav
            play(wav, voiceID: voice.id)
            return
        }
        let request = SynthesisRequest(text: Self.samples[voice.language] ?? "", voice: voice, speed: 1.0)
        task = Task { [weak self] in
            do {
                let result = try await synthesizer.synthesize(request)
                guard !Task.isCancelled, let self else { return }
                self.memory[key] = result.wav
                self.writeToDisk(result.wav, key: key)
                self.play(result.wav, voiceID: voice.id)
            } catch {
                guard !Task.isCancelled else { return }
                self?.failed(error)
            }
        }
    }

    /// Stop the preview; the document goes on if it was playing before.
    func stop() {
        cancelCurrent()
        endPreview()
    }

    // MARK: - Internals

    private func play(_ wav: Data, voiceID: String) {
        task = nil
        output.userSpeed = 1.0
        do {
            try output.play(AudioItem(id: Self.itemID, wav: wav, synthSpeed: 1.0, pause: 0))
        } catch {
            failed(error)
            return
        }
        phase = .playing(voiceID: voiceID)
    }

    private func cancelCurrent() {
        task?.cancel()
        task = nil
        if case .playing = phase { output.stop() }
    }

    private func finished() {
        guard case .playing = phase else { return }
        endPreview()
    }

    private func failed(_ error: any Error) {
        output.stop()
        endPreview()
        onError(error)
    }

    private func endPreview() {
        phase = .idle
        task = nil
        if resumesDocument {
            resumesDocument = false
            resumeDocument()
        }
    }

    // MARK: - Cache

    /// The engine, the voice and the sample's text (a new sample text never plays an old file).
    static func cacheKey(engineID: String, voiceID: String, language: SpeechLanguage) -> String {
        let sample = samples[language] ?? ""
        let digest = SHA256.hash(data: Data(sample.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(engineID)-\(voiceID)-\(digest)"
    }

    private func fileURL(_ key: String) -> URL? {
        cacheDirectory?.appending(path: key + ".wav")
    }

    private func readFromDisk(_ key: String) -> Data? {
        guard let url = fileURL(key), let data = try? Data(contentsOf: url) else { return nil }
        guard (try? WAVDecoder.decode(data)) != nil else {
            try? FileManager.default.removeItem(at: url)  // truncated or not a WAV
            return nil
        }
        return data
    }

    private func writeToDisk(_ wav: Data, key: String) {
        guard let url = fileURL(key) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? wav.write(to: url, options: .atomic)
    }
}
