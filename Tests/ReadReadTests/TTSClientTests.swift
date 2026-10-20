import XCTest

@testable import ReadRead

final class TTSClientTests: XCTestCase {
    private let token = String(repeating: "ab", count: 32)
    private var endpoint: ServerEndpoint {
        ServerEndpoint(port: 50_123, token: token, pid: 4321, loaded: ["zh"], generation: 1)
    }

    private func request(_ voiceID: String = "bf_emma", speed: Double = 1.1) throws -> SynthesisRequest {
        SynthesisRequest(text: "Hello there.", voice: try XCTUnwrap(Voice.voice(id: voiceID)), speed: speed, requestID: "rr-12345678")
    }

    // MARK: - Request shape

    func testSynthesizeRequestCarriesTokenJSONAndTheVoiceLanguage() async throws {
        let fake = FakeTransport()
        _ = try await TTSClient(endpoint: endpoint, transport: fake.transport).synthesize(try request())

        let sent = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "http://127.0.0.1:50123/synthesize")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(sent.timeoutInterval, TTSClient.requestTimeout)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "Hello there.")
        XCTAssertEqual(body["voice"] as? String, "bf_emma")
        XCTAssertEqual(body["lang"] as? String, "en")
        XCTAssertEqual(body["speed"] as? Double, 1.1)
        XCTAssertEqual(body["request_id"] as? String, "rr-12345678")
        XCTAssertEqual(body["format"] as? String, "json")
        XCTAssertEqual(body.count, 6)
    }

    func testChineseVoiceSendsZh() async throws {
        let fake = FakeTransport()
        _ = try await TTSClient(endpoint: endpoint, transport: fake.transport).synthesize(try request("zm_055"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(fake.requests.first?.httpBody)) as? [String: Any])
        XCTAssertEqual(body["lang"] as? String, "zh")
    }

    func testHealthIsAnAuthenticatedGET() async throws {
        let fake = FakeTransport(fallback: .json(status: 200, body: #"{"status":"ok","api":2,"pid":4321,"loaded":["zh"],"versions":{"kokoro_onnx":"0.6.1"}}"#))
        let health = try await TTSClient(endpoint: endpoint, transport: fake.transport).health()
        XCTAssertEqual(health, HealthInfo(status: "ok", api: 2, pid: 4321, loaded: ["zh"], versions: ["kokoro_onnx": "0.6.1"]))
        let sent = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(sent.url?.path, "/health")
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    func testVoicesIsAnAuthenticatedGET() async throws {
        let fake = FakeTransport(fallback: .json(status: 200, body: #"{"zh":["zf_001","zm_009"],"en":["af_heart","bf_emma"]}"#))
        let voices = try await TTSClient(endpoint: endpoint, transport: fake.transport).voices()
        XCTAssertEqual(voices, ["zh": ["zf_001", "zm_009"], "en": ["af_heart", "bf_emma"]])
        let sent = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(sent.url?.path, "/voices")
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    func testMalformedVoicesAreABadResponse() async throws {
        let fake = FakeTransport(fallback: .json(status: 200, body: #"{"zh":"zf_001"}"#))
        do {
            _ = try await TTSClient(endpoint: endpoint, transport: fake.transport).voices()
            XCTFail("expected an error")
        } catch {
            guard case .badResponse(let message)? = error as? TTSError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.hasPrefix("voices:"), message)
        }
    }

    // MARK: - Decoding

    func testDecodesAudioSentencesAndTokens() throws {
        let result = try TTSClient.decodeSynthesis(Data(synthesisJSON(requestID: "rr-abc").utf8))
        XCTAssertEqual(result.wav, minimalWAV)
        XCTAssertEqual(result.sampleRate, 24_000)
        XCTAssertEqual(result.duration, 1.25)
        XCTAssertFalse(result.silent)
        XCTAssertEqual(result.requestID, "rr-abc")
        XCTAssertEqual(result.sentences, [
            TimedSpan(text: "你好。", start: 0, end: 0.6), TimedSpan(text: "再见。", start: 0.6, end: 1.25),
        ])
        XCTAssertEqual(result.tokens, [TimedSpan(text: "你好", start: 0.05, end: 0.5)], "incomplete spans are dropped")
    }

    func testSilentFlagIsKept() throws {
        XCTAssertTrue(try TTSClient.decodeSynthesis(Data(synthesisJSON(silent: true).utf8)).silent)
    }

    func testAudioThatIsNotWAVIsRejected() {
        let notWAV = Data("hello world, not a wav".utf8).base64EncodedString()
        let json = #"{"sample_rate":24000,"duration":1,"audio":"\#(notWAV)"}"#
        XCTAssertThrowsError(try TTSClient.decodeSynthesis(Data(json.utf8))) { error in
            guard case .badResponse? = error as? TTSError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try TTSClient.decodeSynthesis(Data(#"{"sample_rate":24000,"duration":1,"audio":"%%%"}"#.utf8)))
    }

    func testMissingFieldsAreABadResponse() {
        XCTAssertThrowsError(try TTSClient.decodeSynthesis(Data(#"{"audio":"UklGRg=="}"#.utf8))) { error in
            guard case .badResponse(let message)? = error as? TTSError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.hasPrefix("synthesize:"))
        }
    }

    // MARK: - Errors

    func testServerErrorJSONBecomesTheServersMessage() async throws {
        let body = #"{"error":{"code":"voice_language_mismatch","message":"voice bf_emma is English, lang was zh"}}"#
        let fake = FakeTransport([.json(status: 400, body: body)])
        do {
            _ = try await TTSClient(endpoint: endpoint, transport: fake.transport).synthesize(try request())
            XCTFail("expected an error")
        } catch let error as TTSError {
            XCTAssertEqual(error, .server(status: 400, code: "voice_language_mismatch",
                                          message: "voice bf_emma is English, lang was zh"))
            XCTAssertEqual(error.errorDescription, "TTS error (voice_language_mismatch): voice bf_emma is English, lang was zh")
            XCTAssertFalse(error.isServerFailure)
        }
    }

    func testUnauthorizedIsReportedWithItsCode() {
        let error = TTSClient.error(status: 401, body: Data(#"{"error":{"code":"unauthorized","message":"bad token"}}"#.utf8))
        XCTAssertEqual(error, .server(status: 401, code: "unauthorized", message: "bad token"))
    }

    func testNonJSONErrorKeepsTheStartOfTheBody() {
        let error = TTSClient.error(status: 502, body: Data("  Bad Gateway\n".utf8))
        XCTAssertEqual(error, .http(status: 502, body: "Bad Gateway"))
        let long = TTSClient.error(status: 500, body: Data(String(repeating: "x", count: 2_000).utf8))
        guard case .http(_, let snippet) = long else { return XCTFail("\(long)") }
        XCTAssertEqual(snippet.count, 500)
    }

    func testEnvelopeWithoutAMessageFallsBackToTheCode() {
        XCTAssertEqual(TTSClient.error(status: 413, body: Data(#"{"error":{"code":"too_large"}}"#.utf8)),
                       .server(status: 413, code: "too_large", message: "too_large"))
    }

    func testTransportErrorsAreMapped() async throws {
        let refused = FakeTransport([.failure(.cannotConnectToHost)])
        do {
            _ = try await TTSClient(endpoint: endpoint, transport: refused.transport).synthesize(try request())
            XCTFail("expected an error")
        } catch {
            guard case .connectionFailed(let message)? = error as? TTSError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("URLError \(URLError.Code.cannotConnectToHost.rawValue)"), message)
        }

        let slow = FakeTransport([.failure(.timedOut)])
        do {
            _ = try await TTSClient(endpoint: endpoint, transport: slow.transport).synthesize(try request())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TTSError, .requestTimedOut(seconds: 120))
        }
    }

    func testCancellingTheCallerCancelsTheHTTPRequest() async throws {
        let fake = FakeTransport([.hang])
        let client = TTSClient(endpoint: endpoint, transport: fake.transport)
        let synthesis = try request()
        let task = Task { try await client.synthesize(synthesis) }
        while fake.requests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(fake.cancellations, 1)
    }

    func testIsWAV() {
        XCTAssertTrue(TTSClient.isWAV(minimalWAV))
        XCTAssertFalse(TTSClient.isWAV(Data("RIFF".utf8)))
        XCTAssertFalse(TTSClient.isWAV(Data("RIFF\0\0\0\0AVI LIST".utf8)))
    }
}
