import XCTest

@testable import ReadRead

/// PCM16 WAV → samples (H5): a bad header is an error, never a hang.
final class WAVDecoderTests: XCTestCase {
    /// A RIFF/WAVE file with the given chunks, in order.
    private func riff(_ chunks: [(String, Data)]) -> Data {
        var body = Data("WAVE".utf8)
        for (id, payload) in chunks {
            body.append(Data(id.utf8))
            body.append(le32(UInt32(payload.count)))
            body.append(payload)
            if payload.count % 2 == 1 { body.append(0) }
        }
        return Data("RIFF".utf8) + le32(UInt32(body.count)) + body
    }

    private func fmt(tag: UInt16 = 1, channels: UInt16 = 1, rate: UInt32 = 24_000, bits: UInt16 = 16) -> Data {
        le16(tag) + le16(channels) + le32(rate) + le32(rate * UInt32(channels) * UInt32(bits / 8))
            + le16(channels * bits / 8) + le16(bits)
    }

    private func pcm(_ values: [Int16]) -> Data {
        values.reduce(into: Data()) { $0.append(le16(UInt16(bitPattern: $1))) }
    }

    private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    func testSamplesAndRate() throws {
        let audio = try WAVDecoder.decode(riff([("fmt ", fmt()), ("data", pcm([0, 16_384, -32_768, 32_767]))]))
        XCTAssertEqual(audio.sampleRate, 24_000)
        XCTAssertEqual(audio.samples, [0, 0.5, -1, 32_767 / 32_768])
        XCTAssertEqual(try WAVDecoder.decode(minimalWAV).samples, [], "header only")
    }

    func testOtherChunksAreSkippedIncludingOddSizedOnes() throws {
        let audio = try WAVDecoder.decode(riff([("fmt ", fmt()), ("LIST", Data("odd".utf8)), ("data", pcm([1_000]))]))
        XCTAssertEqual(audio.samples.count, 1)
    }

    func testOnlyTheFirstChannelOfStereo() throws {
        let audio = try WAVDecoder.decode(riff([("fmt ", fmt(channels: 2, rate: 22_050)), ("data", pcm([100, -100, 200, -200]))]))
        XCTAssertEqual(audio.samples, [100 / 32_768, 200 / 32_768])
        XCTAssertEqual(audio.sampleRate, 22_050)
    }

    func testAStreamingSizeUsesWhatIsThere() throws {
        var data = riff([("fmt ", fmt()), ("data", pcm([1, 2, 3]))])
        data.replaceSubrange(data.count - 10..<data.count - 6, with: le32(0xFFFF_FFFF))
        XCTAssertEqual(try WAVDecoder.decode(data).samples.count, 3)
    }

    func testBadFilesAreErrors() {
        let cases: [(Data, String)] = [
            (Data(), "no RIFF/WAVE header"),
            (Data("RIFF\u{0}\u{0}\u{0}\u{0}AVI ".utf8), "no RIFF/WAVE header"),
            (riff([("fmt ", fmt(tag: 3, bits: 32)), ("data", Data(count: 8))]), "format 3 is not PCM"),
            (riff([("fmt ", fmt(bits: 24)), ("data", Data(count: 6))]), "24-bit samples, expected 16"),
            (riff([("fmt ", fmt(rate: 4_000)), ("data", pcm([1]))]), "sample rate 4000"),
            (riff([("data", pcm([1]))]), "data before fmt"),
            (riff([("fmt ", fmt())]), "no data chunk"),
            (riff([("LIST", Data(count: 4))]), "no fmt chunk"),
            (riff([("fmt ", Data(count: 8))]), "short fmt chunk"),
        ]
        for (data, reason) in cases {
            XCTAssertThrowsError(try WAVDecoder.decode(data), reason) { error in
                XCTAssertEqual(error as? WAVDecoder.Failure, .invalid(reason))
            }
        }
    }

    func testAChunkSizePastTheEndDoesNotHang() {
        var data = riff([("fmt ", fmt()), ("JUNK", Data(count: 2))])
        data.replaceSubrange(data.count - 6..<data.count - 2, with: le32(0x7FFF_FFF0))
        XCTAssertThrowsError(try WAVDecoder.decode(data))
    }

    func testBuffersAppendThePauseAndResample() throws {
        let audio = WAVDecoder.Audio(samples: [0.5, -0.5], sampleRate: 24_000)
        let buffer = try WAVDecoder.buffer(audio, appendingSilence: 0.25, sampleRate: 24_000)
        XCTAssertEqual(buffer.frameLength, 2 + 6_000)
        XCTAssertEqual(buffer.floatChannelData?[0][1], -0.5)
        XCTAssertEqual(buffer.floatChannelData?[0][2], 0)
        XCTAssertEqual(buffer.format.sampleRate, 24_000)

        let resampled = WAVDecoder.resample([0, 1, 0, -1], from: 12_000, to: 24_000)
        XCTAssertEqual(resampled.count, 8)
        XCTAssertEqual(resampled[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(WAVDecoder.resample([], from: 22_050, to: 24_000), [])
        let empty = try WAVDecoder.buffer(WAVDecoder.Audio(samples: [], sampleRate: 22_050), appendingSilence: 0, sampleRate: 24_000)
        XCTAssertEqual(empty.frameLength, 0)
    }

    func testTheAppleFallbacksWAVRoundTrips() throws {
        let wav = AppleSpeechSynthesizer.wav([0, 0.5, -1, 1.5], sampleRate: 24_000)
        XCTAssertEqual(wav.count, 44 + 8)
        let audio = try WAVDecoder.decode(wav)
        XCTAssertEqual(audio.sampleRate, 24_000)
        XCTAssertEqual(audio.samples[1], 0.5, accuracy: 0.001)
        XCTAssertEqual(audio.samples[2], -1, accuracy: 0.001)
        XCTAssertEqual(audio.samples[3], 1, accuracy: 0.001, "clipped")
    }
}
