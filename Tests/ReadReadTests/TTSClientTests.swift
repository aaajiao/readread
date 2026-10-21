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

    /// The body's `lang` is the voice's language: a Chinese voice sends "zh" (an English one "en", above).
    func testChineseVoiceSendsZh() async throws {
        let fake = FakeTransport()
        _ = try await TTSClient(endpoint: endpoint, transport: fake.transport).synthesize(try request("zm_055"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(fake.requests.first?.httpBody)) as? [String: Any])
        XCTAssertEqual(body["voice"] as? String, "zm_055")
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
        let result = try TTSClient.decodeSynthesis(Data(synthesisJSON(requestID: "rr-abc").utf8), requestedSpeed: 1.0)
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

    func testSynthSpeedIsTheServersWhenItSendsOne() throws {
        // Qwen always synthesizes at 1.0 and says so; the player time-stretches.
        let reported = try TTSClient.decodeSynthesis(Data(synthesisJSON(synthSpeed: 1.0).utf8), requestedSpeed: 1.4)
        XCTAssertEqual(reported.synthSpeed, 1.0)
        let kokoro = try TTSClient.decodeSynthesis(Data(synthesisJSON(synthSpeed: 1.4).utf8), requestedSpeed: 1.4)
        XCTAssertEqual(kokoro.synthSpeed, 1.4)
    }

    func testSynthSpeedFallsBackToTheRequestedSpeed() throws {
        // A v0.2.0 server has no synth_speed field: it honoured the requested speed.
        let result = try TTSClient.decodeSynthesis(Data(synthesisJSON().utf8), requestedSpeed: 1.3)
        XCTAssertEqual(result.synthSpeed, 1.3)
        let nonsense = try TTSClient.decodeSynthesis(Data(synthesisJSON(synthSpeed: 0).utf8), requestedSpeed: 0.8)
        XCTAssertEqual(nonsense.synthSpeed, 0.8, "a speed of 0 is not a speed")
    }

    func testSynthesizeReportsTheSpeedTheAudioWasMadeAt() async throws {
        let withField = FakeTransport(fallback: .json(status: 200, body: synthesisJSON(synthSpeed: 1.0)))
        let qwen = try await TTSClient(endpoint: endpoint, transport: withField.transport).synthesize(try request(speed: 1.5))
        XCTAssertEqual(qwen.synthSpeed, 1.0)
        let without = FakeTransport()
        let old = try await TTSClient(endpoint: endpoint, transport: without.transport).synthesize(try request(speed: 1.5))
        XCTAssertEqual(old.synthSpeed, 1.5)
    }

    func testHealthKeepsTheEngineAndModel() async throws {
        let body = #"{"status":"ok","api":2,"pid":7,"loaded":["zh"],"versions":{},"engine":"qwen","model":"1.7b"}"#
        let fake = FakeTransport(fallback: .json(status: 200, body: body))
        let health = try await TTSClient(endpoint: endpoint, transport: fake.transport).health()
        XCTAssertEqual(health.engine, "qwen")
        XCTAssertEqual(health.model, "1.7b")
    }

    func testSilentFlagIsKept() throws {
        XCTAssertTrue(try TTSClient.decodeSynthesis(Data(synthesisJSON(silent: true).utf8), requestedSpeed: 1.0).silent)
    }

    func testAudioThatIsNotWAVIsRejected() {
        let notWAV = Data("hello world, not a wav".utf8).base64EncodedString()
        let json = #"{"sample_rate":24000,"duration":1,"audio":"\#(notWAV)"}"#
        XCTAssertThrowsError(try TTSClient.decodeSynthesis(Data(json.utf8), requestedSpeed: 1.0)) { error in
            guard case .badResponse? = error as? TTSError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try TTSClient.decodeSynthesis(Data(#"{"sample_rate":24000,"duration":1,"audio":"%%%"}"#.utf8), requestedSpeed: 1.0))
    }

    func testMissingFieldsAreABadResponse() {
        XCTAssertThrowsError(try TTSClient.decodeSynthesis(Data(#"{"audio":"UklGRg=="}"#.utf8), requestedSpeed: 1.0)) { error in
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
            XCTAssertTrue(error.errorDescription?.contains("voice bf_emma is English, lang was zh") == true, "the banner shows it")
            XCTAssertFalse(error.isServerFailure)
        }
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
