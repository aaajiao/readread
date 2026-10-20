import Foundation
import AVFoundation

/// Audio output used by AppState's playback loop; tests inject a fake.
@MainActor
protocol AudioPlaying: AnyObject {
    /// Play WAV data and return when it has finished (or was stopped).
    func playAndWait(data: Data) async throws
    func stop()
    func pause()
    func resume()
}

enum AudioPlaybackError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart: return "Audio playback could not start."
        }
    }
}

@MainActor
final class AudioPlayerService: NSObject, AVAudioPlayerDelegate, AudioPlaying {
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?

    func playAndWait(data: Data) async throws {
        stop()

        let player = try AVAudioPlayer(data: data)
        self.player = player
        player.delegate = self
        // play() returns false when playback can't start (no output device, bad
        // file); waiting for a didFinish that never comes would hang the reader.
        guard player.play() else {
            self.player = nil
            throw AudioPlaybackError.couldNotStart
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
        }
    }

    func stop() {
        player?.stop()
        player = nil
        let cont = continuation
        continuation = nil
        cont?.resume()
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        player?.play()
    }

    private func finish(playerID: ObjectIdentifier) {
        // Ignore late callbacks from a player that was already replaced.
        guard let player, ObjectIdentifier(player) == playerID else { return }
        let cont = continuation
        continuation = nil
        cont?.resume()
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.finish(playerID: id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.finish(playerID: id) }
    }
}
