import Foundation
import MediaPlayer

/// What the system's Now Playing widget shows.
struct NowPlayingInfo: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case playing
        case paused
        case stopped
    }

    let title: String
    /// The source label (domain or file name), shown as the artist.
    let artist: String
    let elapsed: Double
    let duration: Double
    let rate: Double
    let state: State
}

/// Media keys, AirPods and the Control Center widget (R4-12).
enum NowPlayingCommand: Equatable, Sendable {
    case play
    case pause
    case toggle
    case next
    case previous
}

@MainActor
protocol NowPlayingPublishing: AnyObject {
    var onCommand: ((NowPlayingCommand) -> Void)? { get set }
    func update(_ info: NowPlayingInfo)
    func clear()
}

/// MPNowPlayingInfoCenter + MPRemoteCommandCenter; next/previous track = next/previous sentence.
@MainActor
final class NowPlayingController: NowPlayingPublishing {
    var onCommand: ((NowPlayingCommand) -> Void)?
    private var targets: [(MPRemoteCommand, Any)] = []

    init() {
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand, .play)
        register(center.pauseCommand, .pause)
        register(center.togglePlayPauseCommand, .toggle)
        register(center.nextTrackCommand, .next)
        register(center.previousTrackCommand, .previous)
    }

    private func register(_ command: MPRemoteCommand, _ value: NowPlayingCommand) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor in self?.onCommand?(value) }
            return .success
        }
        targets.append((command, target))
    }

    func update(_ info: NowPlayingInfo) {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPNowPlayingInfoPropertyPlaybackRate: info.state == .playing ? info.rate : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        center.playbackState = switch info.state {
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        }
    }

    func clear() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}
