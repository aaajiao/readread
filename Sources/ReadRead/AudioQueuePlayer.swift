import AVFoundation
import Foundation

/// The production `AudioOutput` (R1-11): AVAudioEngine → AVAudioPlayerNode →
/// AVAudioUnitTimePitch → main mixer. One unit is scheduled at a time, its pause appended
/// as silence; the controller schedules the next one when `onFinished` fires (on
/// `.dataPlayedBack`, so the pause hides the scheduling latency). The time-pitch rate is
/// userSpeed / the buffer's synthSpeed, so a speed change is heard at once (R1-06).
///
/// `.offline` mode renders through manual rendering instead of the audio device (tests and
/// `--self-test`): `render(_:into:)` advances the graph and reports a unit finished while its
/// last `offlineLookahead` frames are still scheduled, so the next unit (played from
/// `onFinished`) is scheduled right behind it and follows sample-exactly. (The time-pitch unit
/// pulls the player node ahead of the output in blocks, and a buffer scheduled after the node
/// has run dry starts late.) While paused nothing is rendered: silence, as with the engine paused.
@MainActor
final class AudioQueuePlayer: AudioOutput {
    enum Mode: Equatable, Sendable {
        case realtime
        case offline
    }

    static let sampleRate = 24_000.0
    /// Offline mode: player frames before a unit's end at which it is reported finished.
    static let offlineLookahead: AVAudioFramePosition = 4_096

    let mode: Mode
    var onFinished: ((Int) -> Void)?
    var onFailure: ((any Error) -> Void)?
    var userSpeed: Double = 1.0 {
        didSet { applyRate() }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format: AVAudioFormat

    private struct Loaded {
        let item: AudioItem
        let buffer: AVAudioPCMBuffer
        let generation: Int
        /// The player-node sample time the buffer starts at.
        var startSample: AVAudioFramePosition
    }

    private var loaded: Loaded?
    /// The player-node sample where the scheduled audio ends (the finished unit's tail, offline).
    private var scheduledEnd: AVAudioFramePosition?
    private var generation = 0
    private(set) var isPaused = false
    /// `currentTime` when paused (a paused player node reports no time).
    private var pausedTime: Double?
    /// Offline mode: output frames rendered so far.
    private(set) var renderedFrames: AVAudioFramePosition = 0
    private var scratch: AVAudioPCMBuffer?
    private let maximumFrameCount: AVAudioFrameCount
    nonisolated(unsafe) private var configurationObserver: (any NSObjectProtocol)?

    /// The real player on the default output device.
    init() {
        mode = .realtime
        maximumFrameCount = 0
        format = Self.makeFormat()
        connectGraph()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
    }

    /// Manual offline rendering: no audio device; drive it with `render(_:into:)`.
    init(offlineMaximumFrameCount: AVAudioFrameCount) throws {
        mode = .offline
        maximumFrameCount = offlineMaximumFrameCount
        format = Self.makeFormat()
        connectGraph()
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: offlineMaximumFrameCount)
            try engine.start()
        } catch {
            throw AudioOutputError.engine("offline rendering: \(error.localizedDescription)")
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    private static func makeFormat() -> AVAudioFormat {
        // 24 kHz mono float32 is always a valid format.
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    private func connectGraph() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    }

    // MARK: - AudioOutput

    func play(_ item: AudioItem) throws {
        let audio = try WAVDecoder.decode(item.wav)
        let buffer = try WAVDecoder.buffer(audio, appendingSilence: item.pause, sampleRate: Self.sampleRate)
        try startEngine()
        generation += 1
        // Right after the previous unit finished the node is still running: keep its timeline
        // (no stop/restart latency between units) and start behind what is still scheduled.
        let continuing = loaded == nil && !isPaused && player.isPlaying
        var start: AVAudioFramePosition = 0
        if continuing {
            let now = sampleTime() ?? 0
            start = max(now, scheduledEnd ?? now)
        } else {
            player.stop()
        }
        loaded = Loaded(item: item, buffer: buffer, generation: generation, startSample: start)
        scheduledEnd = start + AVAudioFramePosition(buffer.frameLength)
        isPaused = false
        pausedTime = nil
        applyRate()
        schedule()
        if !player.isPlaying { player.play() }
    }

    func pause() {
        guard !isPaused else { return }
        pausedTime = currentTime
        isPaused = true
        // Offline, `render` renders nothing while paused, which freezes the graph as it is.
        guard mode == .realtime else { return }
        player.pause()
        engine.pause()
    }

    func resume() throws {
        guard isPaused else { return }
        guard loaded != nil else {
            isPaused = false
            pausedTime = nil
            return
        }
        try startEngine()
        isPaused = false
        pausedTime = nil
        if !player.isPlaying { player.play() }
    }

    func stop() {
        generation += 1
        loaded = nil
        scheduledEnd = nil
        isPaused = false
        pausedTime = nil
        player.stop()
        if mode == .realtime { engine.stop() }
    }

    var currentTime: Double {
        if let pausedTime { return pausedTime }
        guard let loaded, let now = sampleTime() else { return 0 }
        let seconds = Double(now - loaded.startSample) / Self.sampleRate
        return min(max(0, seconds), Double(loaded.buffer.frameLength) / Self.sampleRate)
    }

    /// The time-pitch rate in effect (for tests).
    var rate: Double { Double(timePitch.rate) }
    var isRateBypassed: Bool { timePitch.bypass }
    /// The loaded unit's id, if any.
    var loadedItemID: Int? { loaded?.item.id }
    /// Whether the engine runs (realtime: the output device is in use; for tests).
    var isEngineRunning: Bool { engine.isRunning }

    // MARK: - Offline rendering

    /// Render `frames` output frames (appended to `destination` when given). A step never takes
    /// the player past the point where the loaded unit is reported finished, `offlineLookahead`
    /// frames before its end.
    @discardableResult
    func render(_ frames: AVAudioFrameCount, into destination: AVAudioPCMBuffer? = nil) throws -> AVAudioFrameCount {
        guard mode == .offline else { throw AudioOutputError.engine("render(_:into:) needs offline mode") }
        var done: AVAudioFrameCount = 0
        while done < frames {
            var chunk = min(frames - done, maximumFrameCount)
            if isPaused {
                // The engine is "paused": silence, and the graph keeps its state.
                if let destination { appendSilence(chunk, to: destination) }
                done += chunk
                renderedFrames += AVAudioFramePosition(chunk)
                continue
            }
            if let loaded, let now = sampleTime() {
                let remaining = finishSample(of: loaded) - now
                if remaining <= 0 {
                    finishLoaded(generation: loaded.generation)
                    continue
                }
                let atRate = (Double(remaining) / max(rate, 0.01)).rounded(.up)
                chunk = max(1, min(chunk, AVAudioFrameCount(min(atRate, Double(chunk)))))
            }
            let buffer = try scratchBuffer()
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(chunk, to: buffer)
            } catch {
                throw AudioOutputError.engine("offline render: \(error.localizedDescription)")
            }
            guard status == .success else { throw AudioOutputError.engine("offline render status \(status.rawValue)") }
            if let destination { try append(buffer, to: destination) }
            done += buffer.frameLength
            renderedFrames += AVAudioFramePosition(buffer.frameLength)
            if let loaded, !isPaused, let now = sampleTime(), now >= finishSample(of: loaded) {
                finishLoaded(generation: loaded.generation)
            }
        }
        return done
    }

    /// The player-node sample at which offline rendering reports `loaded` finished.
    private func finishSample(of loaded: Loaded) -> AVAudioFramePosition {
        let end = loaded.startSample + AVAudioFramePosition(loaded.buffer.frameLength)
        return max(loaded.startSample + 1, end - Self.offlineLookahead)
    }

    private func appendSilence(_ frames: AVAudioFrameCount, to destination: AVAudioPCMBuffer) {
        let count = min(frames, destination.frameCapacity - destination.frameLength)
        guard count > 0, let channels = destination.floatChannelData else { return }
        for channel in 0..<Int(destination.format.channelCount) {
            (channels[channel] + Int(destination.frameLength)).update(repeating: 0, count: Int(count))
        }
        destination.frameLength += count
    }

    private func scratchBuffer() throws -> AVAudioPCMBuffer {
        if let scratch { return scratch }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maximumFrameCount) else {
            throw AudioOutputError.engine("could not allocate the render buffer")
        }
        scratch = buffer
        return buffer
    }

    private func append(_ source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) throws {
        let free = destination.frameCapacity - destination.frameLength
        let count = min(free, source.frameLength)
        guard count > 0, let from = source.floatChannelData, let to = destination.floatChannelData else { return }
        let channels = min(Int(source.format.channelCount), Int(destination.format.channelCount))
        for channel in 0..<channels {
            (to[channel] + Int(destination.frameLength)).update(from: from[channel], count: Int(count))
        }
        destination.frameLength += count
    }

    // MARK: - Internals

    private func startEngine() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioOutputError.engine(error.localizedDescription)
        }
    }

    private func schedule() {
        guard let loaded else { return }
        let generation = loaded.generation
        switch mode {
        case .realtime:
            player.scheduleBuffer(loaded.buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) {
                [weak self] _ in
                Task { @MainActor in self?.finishLoaded(generation: generation) }
            }
        case .offline:
            // .dataPlayedBack never fires in manual rendering; `render` tracks the end itself.
            player.scheduleBuffer(loaded.buffer, at: nil, options: [], completionHandler: nil)
        }
    }

    private func finishLoaded(generation: Int) {
        guard let loaded, loaded.generation == generation else { return }  // stopped or replaced
        self.loaded = nil
        onFinished?(loaded.item.id)
    }

    private func applyRate() {
        let synthSpeed = loaded?.item.synthSpeed ?? 1
        let value = min(4, max(0.25, userSpeed / max(synthSpeed, 0.1)))
        timePitch.rate = Float(value)
        timePitch.bypass = abs(value - 1) < 0.001
    }

    private func sampleTime() -> AVAudioFramePosition? {
        guard let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return playerTime.sampleTime
    }

    /// The output device changed (headphones, AirPlay): the engine stopped itself. Restart it
    /// and play the current unit again from its start.
    private func engineConfigurationChanged() {
        guard let current = loaded else { return }
        generation += 1
        player.stop()
        loaded = Loaded(item: current.item, buffer: current.buffer, generation: generation, startSample: 0)
        scheduledEnd = AVAudioFramePosition(current.buffer.frameLength)
        if isPaused { pausedTime = 0 }
        schedule()  // a paused unit plays from its start on resume()
        guard !isPaused else { return }
        do {
            try startEngine()
            player.play()
        } catch {
            loaded = nil
            onFailure?(error)
        }
    }
}
