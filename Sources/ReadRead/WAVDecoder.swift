import AVFoundation
import Foundation

/// PCM16 WAV (what every engine returns) → float32 mono samples. The header is validated:
/// a bad WAV is an error, never a hang (H5).
enum WAVDecoder {
    struct Audio: Equatable, Sendable {
        let samples: [Float]
        let sampleRate: Double
    }

    enum Failure: LocalizedError, Equatable {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let reason): return String(localized: "The synthesized audio is not a usable WAV file (\(reason)).")
            }
        }
    }

    static func decode(_ data: Data) throws -> Audio {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45] else {
            throw Failure.invalid("no RIFF/WAVE header")
        }
        var offset = 12
        var format: (channels: Int, sampleRate: Int, bits: Int)?
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = Int(le32(bytes, offset + 4))
            let body = offset + 8
            switch id {
            case "fmt ":
                guard size >= 16, body + 16 <= bytes.count else { throw Failure.invalid("short fmt chunk") }
                let tag = Int(le16(bytes, body))
                var isPCM = tag == 1
                if tag == 0xFFFE, size >= 40, body + 26 <= bytes.count {
                    isPCM = le16(bytes, body + 24) == 1  // WAVE_FORMAT_EXTENSIBLE with the PCM subformat
                }
                guard isPCM else { throw Failure.invalid("format \(tag) is not PCM") }
                format = (Int(le16(bytes, body + 2)), Int(le32(bytes, body + 4)), Int(le16(bytes, body + 14)))
            case "data":
                guard let format else { throw Failure.invalid("data before fmt") }
                guard format.bits == 16 else { throw Failure.invalid("\(format.bits)-bit samples, expected 16") }
                guard (1...8).contains(format.channels) else { throw Failure.invalid("\(format.channels) channels") }
                guard (8_000...192_000).contains(format.sampleRate) else {
                    throw Failure.invalid("sample rate \(format.sampleRate)")
                }
                // Streaming writers leave the size at 0xFFFFFFFF; use what is there.
                let available = min(size, bytes.count - body)
                let frameBytes = 2 * format.channels
                let frames = available / frameBytes
                var samples = [Float](repeating: 0, count: frames)
                for frame in 0..<frames {
                    // The first channel only: every engine ReadRead uses is mono.
                    let value = Int16(bitPattern: le16(bytes, body + frame * frameBytes))
                    samples[frame] = Float(value) / 32_768
                }
                return Audio(samples: samples, sampleRate: Double(format.sampleRate))
            default:
                break
            }
            guard size >= 0, body + size + (size & 1) > offset else { break }
            offset = body + size + (size & 1)
        }
        throw Failure.invalid(format == nil ? "no fmt chunk" : "no data chunk")
    }

    /// A float32 mono buffer at `sampleRate` holding `audio` followed by `silence` seconds of
    /// silence (the unit's pause). Audio at another rate is resampled.
    static func buffer(_ audio: Audio, appendingSilence silence: Double, sampleRate: Double) throws -> AVAudioPCMBuffer {
        let samples = audio.sampleRate == sampleRate ? audio.samples : resample(audio.samples, from: audio.sampleRate, to: sampleRate)
        let silenceFrames = max(0, Int((silence * sampleRate).rounded()))
        let total = samples.count + silenceFrames
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(total, 1))),
              let channel = buffer.floatChannelData?[0] else {
            throw Failure.invalid("could not allocate \(total) frames")
        }
        buffer.frameLength = AVAudioFrameCount(total)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        (channel + samples.count).update(repeating: 0, count: silenceFrames)
        return buffer
    }

    /// Linear interpolation; only used for audio that is not already 24 kHz.
    static func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float] {
        guard !samples.isEmpty, source > 0, target > 0 else { return [] }
        let count = Int((Double(samples.count) * target / source).rounded())
        var result = [Float](repeating: 0, count: count)
        let step = source / target
        for index in 0..<count {
            let position = Double(index) * step
            let lower = Int(position)
            let fraction = Float(position - Double(lower))
            let a = samples[min(lower, samples.count - 1)]
            let b = samples[min(lower + 1, samples.count - 1)]
            result[index] = a + (b - a) * fraction
        }
        return result
    }

    private static func le16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
