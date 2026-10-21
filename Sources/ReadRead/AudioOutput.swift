import Foundation

/// One unit's audio for the player.
struct AudioItem: Sendable, Equatable {
    /// The unit's id; `AudioOutput.onFinished` reports it back.
    let id: Int
    let wav: Data
    /// The speed the audio was made at; the player plays it at userSpeed / synthSpeed.
    let synthSpeed: Double
    /// Seconds of silence after the audio.
    let pause: Double
}

enum AudioOutputError: LocalizedError, Equatable {
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .engine(let message): return String(localized: "Audio playback could not start: \(message)")
        }
    }
}

/// Where the controller sends audio, one unit at a time (`AudioQueuePlayer`; tests use a fake).
@MainActor
protocol AudioOutput: AnyObject {
    /// Called once when the current item (audio and pause) has played to its end.
    var onFinished: ((Int) -> Void)? { get set }

    /// Called when playback stopped by itself and cannot go on (the output device went away
    /// and the engine does not restart).
    var onFailure: ((any Error) -> Void)? { get set }

    /// Play `item` now, replacing whatever is loaded. Throws for a bad WAV or an audio engine
    /// that cannot start.
    func play(_ item: AudioItem) throws

    func pause()

    /// Continue the paused item.
    func resume() throws

    /// Drop the loaded item; no `onFinished` for it.
    func stop()

    /// The user's speed: the rate changes at once (rate = userSpeed / item.synthSpeed).
    var userSpeed: Double { get set }

    /// Seconds into the current item, in its own (synthesized) time.
    var currentTime: Double { get }
}
