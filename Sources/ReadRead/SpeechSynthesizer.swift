import Foundation

/// The two languages ReadRead reads. UK vs US English is a property of the
/// voice (see `Voice.accent`), not of the language.
enum SpeechLanguage: String, CaseIterable, Sendable, Codable {
    case zh
    case en
}

/// One synthesis call: a piece of text, the voice to read it with, and the speed.
/// The language always comes from the voice, so a British voice gets British
/// phonemes and a Chinese voice never receives the English pipeline.
struct SynthesisRequest: Sendable, Equatable {
    static let speedRange: ClosedRange<Double> = 0.5...2.0

    let text: String
    let voiceID: String
    let language: SpeechLanguage
    let speed: Double
    let requestID: String

    init(text: String, voice: Voice, speed: Double, requestID: String = SynthesisRequest.makeRequestID()) {
        self.text = text
        self.voiceID = voice.id
        self.language = voice.language
        self.speed = SynthesisRequest.normalizedSpeed(speed)
        self.requestID = requestID
    }

    /// Clamp to the server's accepted range and round to the slider's 0.1 step,
    /// so floating-point drift (e.g. 2.0000000000000004) never reaches the server.
    static func normalizedSpeed(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1.0 }
        let rounded = (speed * 10).rounded() / 10
        return min(speedRange.upperBound, max(speedRange.lowerBound, rounded))
    }

    static func makeRequestID() -> String {
        "rr-" + UUID().uuidString.prefix(8).lowercased()
    }
}

/// A timed span of the returned audio (a sentence or a word), in seconds.
struct TimedSpan: Sendable, Equatable, Codable {
    let text: String
    let start: Double
    let end: Double
}

struct SynthesisResult: Sendable, Equatable {
    /// PCM16 mono WAV, ready for AVAudioPlayer.
    let wav: Data
    let duration: Double
    let sampleRate: Int
    let silent: Bool
    let sentences: [TimedSpan]
    let tokens: [TimedSpan]
    let requestID: String?
}

/// What the UI shows about the voice engine.
enum SpeechEngineStatus: Equatable {
    case idle        // not running; starts on demand
    case starting    // launching / loading models
    case ready
    case failed(String)
}

/// The speech back end AppState talks to. The real one (`TTSService`) drives the
/// Python server; tests inject fakes.
@MainActor
protocol SpeechSynthesizer: AnyObject {
    /// Synthesize one request. Cancelling the calling task cancels the request.
    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisResult

    /// Start the engine in the background (and load `language`'s model) so the
    /// model load overlaps a network fetch. Never throws; errors surface on the
    /// next `synthesize`.
    func prewarm(for language: SpeechLanguage)

    /// Explicit user retry: forget past crashes, restart the engine, wait until ready.
    func restart() async throws

    /// Tell the engine whether audio is playing (no idle shutdown while it is).
    func setPlaybackActive(_ active: Bool)

    /// Stop the engine now (app termination).
    func shutdown()

    var status: SpeechEngineStatus { get }

    /// The engine's log file, for "Show Log".
    var logFileURL: URL? { get }
}
