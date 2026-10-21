import AVFoundation
import Foundation

enum AppleSpeechError: LocalizedError, Equatable {
    case noVoice(SpeechLanguage)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noVoice(let language):
            let name = language == .zh ? String(localized: "Chinese (zh-CN)") : String(localized: "English (en-US)")
            return String(localized: "No \(name) system voice is installed. Add one in System Settings → Accessibility → Spoken Content.")
        case .timedOut:
            return String(localized: "The system voice did not finish speaking in time.")
        }
    }
}

/// The system-voice fallback for when the Kokoro server cannot run: AVSpeechSynthesizer.write
/// to PCM buffers, returned as a 24 kHz mono PCM16 WAV at speed 1.0 (the player time-stretches
/// it), without timings.
@MainActor
final class AppleSpeechSynthesizer: SpeechSynthesizer {
    struct VoiceInfo: Equatable, Sendable {
        enum Quality: Int, Sendable {
            case standard = 1
            case enhanced = 2
            case premium = 3
        }

        let identifier: String
        let name: String
        /// BCP 47, as AVSpeechSynthesisVoice reports it ("zh-CN", "en-US").
        let language: String
        let quality: Quality
    }

    static let outputSampleRate = 24_000

    /// Longer than any real utterance of `text` takes to render (a few times real time).
    static func timeout(for text: String) -> Duration {
        .seconds(max(30, text.count / 2))
    }

    var engineID: String { "apple" }
    var honoursSpeed: Bool { false }
    let status: SpeechEngineStatus = .ready
    let logFileURL: URL? = nil

    private let installedVoices: @MainActor () -> [VoiceInfo]

    init(installedVoices: @escaping @MainActor () -> [VoiceInfo] = AppleSpeechSynthesizer.systemVoices) {
        self.installedVoices = installedVoices
    }

    static func systemVoices() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            let quality: VoiceInfo.Quality = switch voice.quality {
            case .premium: .premium
            case .enhanced: .enhanced
            default: .standard
            }
            return VoiceInfo(identifier: voice.identifier, name: voice.name, language: voice.language, quality: quality)
        }
    }

    /// zh: the best installed premium or enhanced zh-CN voice, else Tingting; en: Ava (premium,
    /// then enhanced), else Samantha. Then any voice of the language.
    static func pickVoice(for language: SpeechLanguage, from voices: [VoiceInfo]) -> VoiceInfo? {
        func best(_ candidates: [VoiceInfo]) -> VoiceInfo? {
            candidates.filter { $0.quality != .standard }.max { $0.quality.rawValue < $1.quality.rawValue }
        }
        func named(_ name: String, in candidates: [VoiceInfo]) -> [VoiceInfo] {
            candidates.filter { $0.name.hasPrefix(name) || $0.identifier.hasSuffix(".\(name)") }
        }
        switch language {
        case .zh:
            let chinese = voices.filter { $0.language == "zh-CN" }
            return best(chinese) ?? named("Tingting", in: chinese).first ?? chinese.first
        case .en:
            let english = voices.filter { $0.language == "en-US" }
            return best(named("Ava", in: english)) ?? named("Samantha", in: english).max { $0.quality.rawValue < $1.quality.rawValue }
                ?? best(english) ?? english.first
        }
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisResult {
        guard let info = Self.pickVoice(for: request.language, from: installedVoices()),
              let voice = AVSpeechSynthesisVoice(identifier: info.identifier) else {
            throw AppleSpeechError.noVoice(request.language)
        }
        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.prefersAssistiveTechnologySettings = false
        // One synthesizer per request: cancelling one can never stop the next.
        let synthesizer = AVSpeechSynthesizer()
        let collector = SpeechBufferCollector()
        let timeout = Self.timeout(for: request.text)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            collector.fail(AppleSpeechError.timedOut)
        }
        defer { watchdog.cancel() }
        let pcm: SpeechBufferCollector.PCM
        do {
            pcm = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    collector.start(continuation)
                    synthesizer.write(utterance) { buffer in collector.receive(buffer) }
                }
            } onCancel: {
                collector.cancel()
            }
        } catch {
            synthesizer.stopSpeaking(at: .immediate)
            throw error
        }
        withExtendedLifetime(synthesizer) {}  // alive until the last buffer
        let samples = pcm.sampleRate == Double(Self.outputSampleRate)
            ? pcm.samples : WAVDecoder.resample(pcm.samples, from: pcm.sampleRate, to: Double(Self.outputSampleRate))
        return SynthesisResult(
            wav: Self.wav(samples, sampleRate: Self.outputSampleRate),
            duration: Double(samples.count) / Double(Self.outputSampleRate),
            sampleRate: Self.outputSampleRate,
            silent: samples.isEmpty,
            sentences: [],
            tokens: [],
            requestID: request.requestID,
            synthSpeed: 1.0
        )
    }

    func prewarm(for language: SpeechLanguage) {}
    func restart() async throws {}
    func setPlaybackActive(_ active: Bool) {}
    func shutdown() {}

    /// PCM16 mono WAV.
    nonisolated static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func le32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        le32(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        le32(16); le16(1); le16(1); le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2)); le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8))
        le32(UInt32(samples.count * 2))
        for sample in samples {
            le16(UInt16(bitPattern: Int16((max(-1, min(1, sample)) * 32_767).rounded())))
        }
        return data
    }
}

/// Collects the buffers AVSpeechSynthesizer.write delivers (on its own queue) until the empty
/// one that ends the utterance, then resumes the waiting task exactly once.
final class SpeechBufferCollector: @unchecked Sendable {
    struct PCM: Sendable {
        let samples: [Float]
        let sampleRate: Double
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<PCM, any Error>?
    private var samples: [Float] = []
    private var sampleRate = 22_050.0
    private var finished = false

    func start(_ continuation: CheckedContinuation<PCM, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        if finished {
            continuation.resume(throwing: CancellationError())
        } else {
            self.continuation = continuation
        }
    }

    func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        let count = Int(pcm.frameLength)
        if count == 0 {
            lock.lock()
            let result = PCM(samples: samples, sampleRate: sampleRate)
            lock.unlock()
            finish(.success(result))
            return
        }
        var chunk = [Float](repeating: 0, count: count)
        switch pcm.format.commonFormat {
        case .pcmFormatFloat32:
            if let channel = pcm.floatChannelData?[0] { for i in 0..<count { chunk[i] = channel[i] } }
        case .pcmFormatInt16:
            if let channel = pcm.int16ChannelData?[0] { for i in 0..<count { chunk[i] = Float(channel[i]) / 32_768 } }
        case .pcmFormatInt32:
            if let channel = pcm.int32ChannelData?[0] { for i in 0..<count { chunk[i] = Float(channel[i]) / 2_147_483_648 } }
        default:
            return
        }
        lock.lock()
        sampleRate = pcm.format.sampleRate
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    /// No-op once the utterance has finished.
    func fail(_ error: any Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<PCM, any Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
