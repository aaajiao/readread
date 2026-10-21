import AVFoundation
import XCTest

@testable import ReadRead

/// The real AVAudioEngine graph in offline manual rendering: no audio device needed.
@MainActor
final class AudioQueuePlayerTests: XCTestCase {
    private let rate = AudioQueuePlayer.sampleRate

    /// A PCM16 mono 24 kHz WAV of `seconds` of a 440 Hz tone at half scale.
    private func tone(_ seconds: Double, amplitude: Float = 0.5) -> Data {
        let count = Int((seconds * rate).rounded())
        let samples = (0..<count).map { amplitude * Float(sin(2 * Double.pi * 440 * Double($0) / rate)) }
        return AppleSpeechSynthesizer.wav(samples, sampleRate: Int(rate))
    }

    private func makePlayer() throws -> AudioQueuePlayer {
        try AudioQueuePlayer(offlineMaximumFrameCount: 4_096)
    }

    private func outputBuffer(seconds: Double) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        return try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate)))
    }

    /// Index of the first sample at or after `from` louder than `threshold`.
    private func firstAudible(_ buffer: AVAudioPCMBuffer, from: Int = 0, threshold: Float = 0.01) -> Int? {
        guard let samples = buffer.floatChannelData?[0] else { return nil }
        for index in from..<Int(buffer.frameLength) where abs(samples[index]) > threshold { return index }
        return nil
    }

    private func isSilent(_ buffer: AVAudioPCMBuffer, _ range: Range<Int>, threshold: Float = 0.001) -> Bool {
        guard let samples = buffer.floatChannelData?[0] else { return false }
        return range.clamped(to: 0..<Int(buffer.frameLength)).allSatisfy { abs(samples[$0]) <= threshold }
    }

    /// The samples a unit's WAV decodes to.
    private func samples(_ wav: Data) throws -> [Float] {
        try WAVDecoder.decode(wav).samples
    }

    func testUnitsPlayInOrderBackToBackWithTheirPauses() throws {
        let player = try makePlayer()
        let items = [
            AudioItem(id: 7, wav: tone(0.30), synthSpeed: 1, pause: 0.25),
            AudioItem(id: 8, wav: tone(0.20, amplitude: 0.3), synthSpeed: 1, pause: 0.5),
            AudioItem(id: 9, wav: tone(0.10, amplitude: 0.7), synthSpeed: 1, pause: 0.25),
        ]
        var finished: [Int] = []
        player.onFinished = { [unowned player] id in
            finished.append(id)
            guard let index = items.firstIndex(where: { $0.id == id }), index + 1 < items.count else { return }
            do {
                try player.play(items[index + 1])
            } catch {
                XCTFail("\(error)")
            }
        }
        try player.play(items[0])
        let output = try outputBuffer(seconds: 3)
        while finished.count < items.count, output.frameLength + 1_000 <= output.frameCapacity {
            try player.render(1_000, into: output)
        }
        XCTAssertEqual(finished, [7, 8, 9])
        XCTAssertNil(player.loadedItemID)
        try player.render(AVAudioFrameCount(0.5 * rate), into: output)  // the last unit's tail

        // The output is exactly the units' audio, each followed by its pause: no gap, nothing cut.
        var expected: [Float] = []
        for item in items {
            expected += try samples(item.wav)
            expected += [Float](repeating: 0, count: Int((item.pause * rate).rounded()))
        }
        XCTAssertEqual(expected.count, 38_400)
        let channel = try XCTUnwrap(output.floatChannelData?[0])
        XCTAssertGreaterThanOrEqual(Int(output.frameLength), expected.count)
        let worst = expected.indices.map { abs(channel[$0] - expected[$0]) }.max() ?? 1
        XCTAssertLessThan(worst, 0.001, "the output differs from the units played back to back")
        XCTAssertTrue(isSilent(output, expected.count..<Int(output.frameLength)), "nothing after the last pause")
        XCTAssertEqual(firstAudible(output, from: 7_300), 13_201, "the second unit starts right after the first pause")
        XCTAssertEqual(firstAudible(output, from: 18_100), 30_001)
    }

    func testTheRateIsUserSpeedOverSynthSpeed() throws {
        let player = try makePlayer()
        player.userSpeed = 1.5
        try player.play(AudioItem(id: 0, wav: tone(0.2), synthSpeed: 1.0, pause: 0))
        XCTAssertEqual(player.rate, 1.5, accuracy: 0.001)
        XCTAssertFalse(player.isRateBypassed)
        // Audio already made at 1.5 (Kokoro honoured the speed) plays at rate 1.
        try player.play(AudioItem(id: 1, wav: tone(0.2), synthSpeed: 1.5, pause: 0))
        XCTAssertEqual(player.rate, 1, accuracy: 0.001)
        XCTAssertTrue(player.isRateBypassed)
        // The slider changes the rate of the unit that is playing at once.
        player.userSpeed = 0.75
        XCTAssertEqual(player.rate, 0.5, accuracy: 0.001)
        player.userSpeed = 100
        XCTAssertEqual(player.rate, 4, accuracy: 0.001, "clamped")
    }

    func testAFasterRatePlaysTheUnitInLessTime() throws {
        let player = try makePlayer()
        player.userSpeed = 2
        var finished = false
        player.onFinished = { _ in finished = true }
        try player.play(AudioItem(id: 0, wav: tone(1.0), synthSpeed: 1, pause: 0))
        let output = try outputBuffer(seconds: 2)
        while !finished, output.frameLength + 512 <= output.frameCapacity {
            try player.render(512, into: output)
        }
        try player.render(AVAudioFrameCount(0.5 * rate), into: output)
        let channel = try XCTUnwrap(output.floatChannelData?[0])
        let last = try XCTUnwrap((0..<Int(output.frameLength)).last { abs(channel[$0]) > 0.01 })
        XCTAssertEqual(Double(last) / rate, 0.5, accuracy: 0.1, "1 s of audio at rate 2")
    }

    func testPauseIsImmediateAndResumeContinuesWhereItPaused() throws {
        let player = try makePlayer()
        var finished: [Int] = []
        player.onFinished = { finished.append($0) }
        let item = AudioItem(id: 3, wav: tone(0.5), synthSpeed: 1, pause: 0)
        try player.play(item)
        let output = try outputBuffer(seconds: 3)
        try player.render(AVAudioFrameCount(0.2 * rate), into: output)
        // The player node runs a little ahead of the output (the time-pitch unit's look-ahead).
        let atPause = player.currentTime
        XCTAssertGreaterThanOrEqual(atPause, 0.2 - 0.001)
        XCTAssertLessThan(atPause, 0.3)

        player.pause()
        let pausedFrom = Int(output.frameLength)
        try player.render(AVAudioFrameCount(0.5 * rate), into: output)
        XCTAssertTrue(isSilent(output, pausedFrom..<Int(output.frameLength)), "nothing plays while paused")
        XCTAssertEqual(player.currentTime, atPause, "the position holds while paused")
        XCTAssertEqual(finished, [])

        try player.resume()
        let resumedFrom = Int(output.frameLength)
        try player.render(AVAudioFrameCount(0.6 * rate), into: output)
        XCTAssertEqual(finished, [3])
        // Resumed where it stopped: the rest of the tone, nothing repeated or skipped.
        let tone = try samples(item.wav)
        let channel = try XCTUnwrap(output.floatChannelData?[0])
        let worst = (0..<(tone.count - pausedFrom)).map { abs(channel[resumedFrom + $0] - tone[pausedFrom + $0]) }.max() ?? 1
        XCTAssertLessThan(worst, 0.001)
    }

    func testStopDropsTheUnitWithoutFinishing() throws {
        let player = try makePlayer()
        var finished: [Int] = []
        player.onFinished = { finished.append($0) }
        try player.play(AudioItem(id: 1, wav: tone(1.0), synthSpeed: 1, pause: 0))
        try player.render(1_000)
        player.stop()
        try player.render(AVAudioFrameCount(0.5 * rate))
        XCTAssertEqual(finished, [])
        XCTAssertNil(player.loadedItemID)
        XCTAssertEqual(player.currentTime, 0)
    }

    func testPlayReplacesTheLoadedUnit() throws {
        let player = try makePlayer()
        var finished: [Int] = []
        player.onFinished = { finished.append($0) }
        try player.play(AudioItem(id: 1, wav: tone(1.0), synthSpeed: 1, pause: 0))
        try player.render(1_000)
        try player.play(AudioItem(id: 2, wav: tone(0.2), synthSpeed: 1, pause: 0.25))
        try player.render(AVAudioFrameCount(0.6 * rate))
        XCTAssertEqual(finished, [2], "the replaced unit never reports finished")
    }

    /// The audio device, through the controller (opt in with READREAD_TEST_REALTIME_AUDIO=1;
    /// the audio is silence): units end on `.dataPlayedBack`, Pause while buffering pauses the
    /// engine, and the end stops it (a running engine keeps the Mac from idle sleep).
    func testRealtimeTheEngineIsStoppedAtTheEndAndPausedWhileBufferingPaused() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["READREAD_TEST_REALTIME_AUDIO"] == "1",
                          "set READREAD_TEST_REALTIME_AUDIO=1 to play (silence) on the audio device")
        let output = AudioQueuePlayer()
        let synth = FakeSynthesizer()
        synth.holding = true
        let player = PlaybackController(synthesizer: synth, output: output)
        let units = (0..<2).map { SpeechUnit(id: $0, block: $0, range: 0..<4, speakText: "第\($0)句。", language: .zh,
                                             kind: .sentence, endsBlock: true) }
        let blocks = (0..<2).map { ReadingBlock(kind: .paragraph, text: "第\($0)句。", units: $0..<$0 + 1) }
        player.open(ReadingDocument(title: "t", source: .text, sourceLabel: "", blocks: blocks, units: units, detectedLanguage: .zh),
                    settings: PlaybackSettings(), autoplay: true)
        synth.release()
        await waitUntil { player.state == .playing }
        XCTAssertTrue(output.isEngineRunning)
        // Unit 1 is held: after unit 0 (its 0.5 s pause) the player buffers, the engine still running.
        await waitUntil(timeout: .seconds(5)) { player.state == .buffering && player.currentUnit == 1 }
        player.pause()
        XCTAssertFalse(output.isEngineRunning, "paused while buffering")
        synth.holding = false
        synth.release()
        await waitUntil { synth.held == 0 && synth.requests.count == 2 }
        player.play()
        XCTAssertEqual(player.state, .playing)
        XCTAssertTrue(output.isEngineRunning)
        await waitUntil(timeout: .seconds(5)) { player.state == .finished }
        XCTAssertFalse(output.isEngineRunning, "stopped at the end")
    }

    func testABadWAVIsAnErrorNotAHang() throws {
        let player = try makePlayer()
        XCTAssertThrowsError(try player.play(AudioItem(id: 0, wav: Data("not a wav".utf8), synthSpeed: 1, pause: 0)))
        XCTAssertNil(player.loadedItemID)
    }
}
