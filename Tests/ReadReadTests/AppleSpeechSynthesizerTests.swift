import XCTest

@testable import ReadRead

/// The system-voice fallback: which voice it picks, and (opt-in, it uses the real speech
/// engine) that it returns usable audio.
@MainActor
final class AppleSpeechSynthesizerTests: XCTestCase {
    private typealias Info = AppleSpeechSynthesizer.VoiceInfo

    private func voice(_ name: String, _ language: String, _ quality: Info.Quality = .standard) -> Info {
        Info(identifier: "com.apple.voice.\(quality).\(language).\(name)", name: name, language: language, quality: quality)
    }

    func testChinesePrefersADownloadedVoiceThenTingting() {
        let tingting = voice("Tingting", "zh-CN")
        let lili = voice("Lili", "zh-CN", .premium)
        let yu = voice("Yu-shu", "zh-CN", .enhanced)
        let meijia = voice("Meijia", "zh-TW", .premium)
        XCTAssertEqual(AppleSpeechSynthesizer.pickVoice(for: .zh, from: [tingting, yu, lili, meijia]), lili)
        XCTAssertEqual(AppleSpeechSynthesizer.pickVoice(for: .zh, from: [tingting, yu]), yu)
        XCTAssertEqual(AppleSpeechSynthesizer.pickVoice(for: .zh, from: [voice("Other", "zh-CN"), tingting]), tingting)
        XCTAssertEqual(AppleSpeechSynthesizer.pickVoice(for: .zh, from: [voice("Other", "zh-CN")])?.name, "Other")
        XCTAssertNil(AppleSpeechSynthesizer.pickVoice(for: .zh, from: [meijia]), "Taiwanese Mandarin is not zh-CN")
    }

    func testEnglishPrefersAvaThenSamantha() {
        let samantha = voice("Samantha", "en-US")
        let avaEnhanced = voice("Ava", "en-US", .enhanced)
        let avaPremium = voice("Ava", "en-US", .premium)
        let zoe = voice("Zoe", "en-US", .premium)
        let daniel = voice("Daniel", "en-GB", .enhanced)
        XCTAssertEqual(AppleSpeechSynthesizer.pickVoice(for: .en, from: [samantha, avaEnhanced, avaPremium, zoe]), avaPremium)
        XCTAssertEqual(AppleSpeechSynthesizer.pickVoice(for: .en, from: [samantha, avaEnhanced]), avaEnhanced)
        XCTAssertEqual(AppleSpeechSynthesizer.pickVoice(for: .en, from: [zoe, samantha]), samantha, "Samantha before others")
        XCTAssertEqual(AppleSpeechSynthesizer.pickVoice(for: .en, from: [voice("Fred", "en-US"), zoe]), zoe)
        XCTAssertNil(AppleSpeechSynthesizer.pickVoice(for: .en, from: [daniel]))
    }

    func testNoVoiceIsAClearError() async throws {
        let synthesizer = AppleSpeechSynthesizer(installedVoices: { [] })
        XCTAssertEqual(synthesizer.engineID, "apple")
        XCTAssertFalse(synthesizer.honoursSpeed)
        let request = SynthesisRequest(text: "你好。", voice: try XCTUnwrap(Voice.voice(id: "zf_001")), speed: 1.5)
        do {
            _ = try await synthesizer.synthesize(request)
            XCTFail("expected noVoice")
        } catch {
            XCTAssertEqual(error as? AppleSpeechError, .noVoice(.zh))
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("Spoken Content") ?? false)
        }
    }

    func testTimeoutsGrowWithTheText() {
        XCTAssertEqual(AppleSpeechSynthesizer.timeout(for: "short"), .seconds(30))
        XCTAssertEqual(AppleSpeechSynthesizer.timeout(for: String(repeating: "长", count: 3_000)), .seconds(1_500))
    }

    func testTheCollectorResumesOnce() async {
        let collector = SpeechBufferCollector()
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpeechBufferCollector.PCM, any Error>) in
                collector.start(continuation)
                collector.fail(AppleSpeechError.timedOut)
                collector.cancel()  // a second outcome is ignored
            }
            XCTFail("expected the timeout")
        } catch {
            XCTAssertEqual(error as? AppleSpeechError, .timedOut)
        }
        // Cancelled before it started: start resumes at once.
        let early = SpeechBufferCollector()
        early.cancel()
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpeechBufferCollector.PCM, any Error>) in
                early.start(continuation)
            }
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// Real AVSpeechSynthesizer.write: opt in with READREAD_TEST_APPLE_SPEECH=1.
    func testRealSystemSpeech() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["READREAD_TEST_APPLE_SPEECH"] == "1",
                          "set READREAD_TEST_APPLE_SPEECH=1 to synthesize with the system voices")
        let synthesizer = AppleSpeechSynthesizer()
        for (text, id) in [("Hello from the system voice.", "af_heart"), ("你好，这是系统语音。", "zf_001")] {
            let request = SynthesisRequest(text: text, voice: try XCTUnwrap(Voice.voice(id: id)), speed: 1.0)
            let result = try await synthesizer.synthesize(request)
            let audio = try WAVDecoder.decode(result.wav)
            XCTAssertEqual(audio.sampleRate, 24_000)
            XCTAssertGreaterThan(result.duration, 0.5, text)
            XCTAssertLessThan(result.duration, 10, text)
            XCTAssertEqual(result.synthSpeed, 1.0)
            XCTAssertGreaterThan(audio.samples.map(abs).max() ?? 0, 0.01, "audible")
        }
    }
}
