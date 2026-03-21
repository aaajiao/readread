import Foundation
import AVFoundation

@MainActor
final class AudioPlayerService: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?

    func playAndWait(data: Data) async throws {
        stop()

        let player = try AVAudioPlayer(data: data)
        self.player = player
        player.delegate = self
        player.play()

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

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            let cont = self.continuation
            self.continuation = nil
            cont?.resume()
        }
    }
}
