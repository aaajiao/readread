import Synchronization
import XCTest

@testable import ReadRead

@MainActor
final class TTSServiceTests: XCTestCase {

    private func request(_ voiceID: String) throws -> SynthesisRequest {
        SynthesisRequest(text: "Hello.", voice: try XCTUnwrap(Voice.voice(id: voiceID)), speed: 1)
    }

    func testFirstRequestStartsTheServerWithItsLanguageAndUsesItsToken() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady(port: 41_000, loaded: ["en"]) }
        let fake = FakeTransport()
        let service = TTSService(server: h.server, transport: fake.transport)

        let result = try await service.synthesize(try request("bf_emma"))

        XCTAssertEqual(result.wav, minimalWAV)
        let process = try XCTUnwrap(h.launcher.last)
        XCTAssertEqual(Array(process.configuration.arguments.suffix(2)), ["--preload", "en"])
        let sent = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "http://127.0.0.1:41000/synthesize")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(process.token ?? "-")")
        XCTAssertEqual(service.status, .ready)
    }

    func testRetriesOnceOnAFreshServerAfterAConnectionFailure() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        h.sleeper.set(.immediate, for: .milliseconds(1500))  // the old process does not exit
        h.sleeper.set(.immediate, for: .seconds(1))          // backoff before the relaunch
        let fake = FakeTransport([.failure(.networkConnectionLost)])
        let service = TTSService(server: h.server, transport: fake.transport)

        _ = try await service.synthesize(try request("zf_001"))

        XCTAssertEqual(h.launcher.processes.count, 2)
        XCTAssertEqual(fake.requests.count, 2)
        let tokens = fake.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(tokens, h.launcher.processes.map { "Bearer \($0.token ?? "-")" })
        await waitUntil { h.launcher.processes[0].terminateCount == 1 }
        XCTAssertEqual(h.server.recentCrashCount(), 1)
    }

    func testGivesUpAfterTheSingleRetry() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        h.sleeper.set(.immediate, for: .milliseconds(1500))
        h.sleeper.set(.immediate, for: .seconds(1))
        let fake = FakeTransport(fallback: .failure(.cannotConnectToHost))
        let service = TTSService(server: h.server, transport: fake.transport)

        do {
            _ = try await service.synthesize(try request("zf_001"))
            XCTFail("expected an error")
        } catch {
            guard case .connectionFailed? = error as? TTSError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(fake.requests.count, 2)
    }

    func testServerErrorsAreNotRetried() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        let fake = FakeTransport([.json(status: 400, body: #"{"error":{"code":"unknown_voice","message":"no such voice"}}"#)])
        let service = TTSService(server: h.server, transport: fake.transport)

        do {
            _ = try await service.synthesize(try request("zf_001"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TTSError, .server(status: 400, code: "unknown_voice", message: "no such voice"))
        }
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(h.launcher.processes.count, 1)
        XCTAssertEqual(h.server.phase, .ready)
    }

    func testAWedgedServerIsReplacedAfterATimeout() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        h.sleeper.set(.immediate, for: .milliseconds(1500))
        let fake = FakeTransport([.failure(.timedOut)])
        let service = TTSService(server: h.server, transport: fake.transport)

        do {
            _ = try await service.synthesize(try request("af_heart"))
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? TTSError, .requestTimedOut(seconds: 120))
        }
        XCTAssertEqual(h.server.phase, .crashed)
        await waitUntil { h.launcher.processes[0].terminateCount == 1 }
    }

    func testStartupFailureReachesTheCallerWithTheServerMessage() async throws {
        let h = ServerHarness()
        h.launcher.script = { process in
            process.emit("FATAL {\"message\":\"espeak-ng data not found\"}\n")
            process.exit(code: 3)
        }
        let service = TTSService(server: h.server, transport: FakeTransport().transport)
        do {
            _ = try await service.synthesize(try request("af_heart"))
            XCTFail("expected FATAL")
        } catch {
            XCTAssertEqual(error as? TTSError, .serverFatal("espeak-ng data not found"))
        }
        XCTAssertEqual(service.status, .failed("TTS server failed to start: espeak-ng data not found"))
    }

    func testCancellationPropagatesToTheHTTPRequest() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        let fake = FakeTransport([.hang])
        let service = TTSService(server: h.server, transport: fake.transport)
        let synthesis = try request("zf_001")
        let task = Task { try await service.synthesize(synthesis) }
        await waitUntil { !fake.requests.isEmpty }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        XCTAssertEqual(fake.cancellations, 1)
        XCTAssertEqual(h.server.phase, .ready, "a cancelled request is not a server failure")
    }

    func testPrewarmStatusRestartAndShutdown() async throws {
        let h = ServerHarness()
        let service = TTSService(server: h.server, transport: FakeTransport().transport)
        XCTAssertEqual(service.status, .idle)

        service.prewarm(for: .en)
        XCTAssertEqual(service.status, .starting)
        await waitUntil { h.launcher.processes.count == 1 }
        h.launcher.last?.emitReady()
        XCTAssertEqual(service.status, .ready)
        XCTAssertEqual(Array(h.launcher.processes[0].configuration.arguments.suffix(2)), ["--preload", "en"])

        h.launcher.script = { $0.emitReady() }
        try await service.restart()
        XCTAssertEqual(h.launcher.processes.count, 2)
        XCTAssertEqual(h.launcher.processes[0].terminateCount, 1)

        service.shutdown()
        XCTAssertEqual(h.launcher.processes[1].terminateCount, 1)
        XCTAssertEqual(service.status, .idle)
        XCTAssertEqual(service.logFileURL?.path, "/logs/tts-server.log")
    }

    func testRequestsKeepTheServerFromIdling() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        let fake = FakeTransport([.hang])
        let service = TTSService(server: h.server, transport: fake.transport)
        let synthesis = try request("zf_001")
        let task = Task { try await service.synthesize(synthesis) }
        await waitUntil { !fake.requests.isEmpty }

        h.clock.advance(60 * 60)
        await h.server.checkIdle()
        XCTAssertEqual(h.server.phase, .ready, "in-flight synthesis counts as activity")

        task.cancel()
        _ = try? await task.value
        h.clock.advance(15 * 60)
        await h.server.checkIdle()
        XCTAssertEqual(h.server.phase, .stopped)
    }

    // MARK: - Flavors, stop()

    func testKokoroAndQwenNameTheirEngineAndWhetherTheyHonourTheSpeed() {
        let kokoro = TTSService(server: ServerHarness().server, transport: FakeTransport().transport)
        XCTAssertEqual(kokoro.engineID, "kokoro")
        XCTAssertTrue(kokoro.honoursSpeed)
        let q = QwenHarness()
        let qwen = TTSService.qwen(installation: q.installation, environment: q.environment)
        XCTAssertEqual(qwen.engineID, QwenModel.engineID)
        XCTAssertEqual(qwen.engineID, "qwen-1.7b")
        XCTAssertFalse(qwen.honoursSpeed)
        XCTAssertEqual(qwen.server.flavor, .qwen(q.installation))
        XCTAssertEqual(qwen.logFileURL?.path, "/logs/tts-server-qwen.log")
        // Through the protocol, as the player sees them.
        let engines: [any SpeechSynthesizer] = [kokoro, qwen]
        XCTAssertEqual(engines.map(\.engineID), ["kokoro", "qwen-1.7b"])
        XCTAssertEqual(engines.map(\.honoursSpeed), [true, false])
    }

    /// `TTSService.qwen(installation:)` is the app's `QwenEngineFactory` as it is.
    func testQwenIsTheEngineFactory() throws {
        let factory: QwenEngineFactory = TTSService.qwen(installation:)
        let installation = HQInstallation(home: "/nonexistent/hq", installedAt: nil, modelBytes: 0)
        let engine = try XCTUnwrap(factory(installation) as? TTSService)
        XCTAssertEqual(engine.server.flavor, .qwen(installation))
        XCTAssertEqual(engine.server.phase, .stopped, "made, not started")
        XCTAssertEqual(engine.server.policy.idleTimeout, 5 * 60)
    }

    func testQwenSynthesizesThroughItsServerAndKeepsSynthSpeedOne() async throws {
        let q = QwenHarness()
        q.launcher.script = { QwenHarness.emitReady($0, port: 41_500) }
        let fake = FakeTransport([.json(status: 200, body: synthesisJSON(synthSpeed: 1.0))])
        let service = TTSService(server: q.server, transport: fake.transport)
        let serena = try XCTUnwrap(Voice.qwen.first { $0.id == "serena" })

        let result = try await service.synthesize(SynthesisRequest(text: "你好。", voice: serena, speed: 1.25))

        XCTAssertEqual(result.synthSpeed, 1.0, "made at 1.0; the player time-stretches")
        let sent = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "http://127.0.0.1:41500/synthesize")
        let body = try XCTUnwrap(sent.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["voice"] as? String, "serena")
        XCTAssertEqual(Array(try XCTUnwrap(q.launcher.last).configuration.arguments.suffix(2)), ["--preload", "zh"])
    }

    func testStopEndsTheServerWithoutBlockingAndTheNextRequestStartsItAgain() async throws {
        let q = QwenHarness()
        q.launcher.script = { QwenHarness.emitReady($0) }
        let service = TTSService(server: q.server, transport: FakeTransport().transport)
        let aiden = try XCTUnwrap(Voice.qwen.first { $0.id == "aiden" })
        _ = try await service.synthesize(SynthesisRequest(text: "Hello.", voice: aiden, speed: 1))
        let first = try XCTUnwrap(q.launcher.last)

        await service.stop()

        XCTAssertEqual(first.terminateCount, 1)
        XCTAssertTrue(first.stdinClosed)
        XCTAssertFalse(first.isRunning)
        XCTAssertEqual(q.server.phase, .stopped)
        XCTAssertEqual(service.status, .idle)
        XCTAssertEqual(q.server.recentCrashCount(), 0, "a stop is not a crash")

        _ = try await service.synthesize(SynthesisRequest(text: "Hello again.", voice: aiden, speed: 1))
        XCTAssertEqual(q.launcher.processes.count, 2)
        XCTAssertEqual(service.status, .ready)
    }

    /// stop() under a request its caller did not cancel: the request fails once its server is gone,
    /// and no new server is started for it; the next request starts one.
    func testAStopUnderARequestInFlightNeverStartsAnotherServer() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        let gate = TransportGate()
        let service = TTSService(server: h.server, transport: gate.transport)
        let synthesis = try request("zf_001")
        let task = Task { try await service.synthesize(synthesis) }
        await waitUntil { gate.requests == 1 }

        await service.stop()
        gate.fail(.networkConnectionLost)  // what the request sees once its server is gone
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        XCTAssertEqual(h.launcher.processes.count, 1, "no new server for it")
        XCTAssertEqual(gate.requests, 1)
        XCTAssertEqual(h.server.phase, .stopped)
        XCTAssertEqual(h.server.recentCrashCount(), 0, "a stop is not a crash")

        _ = try await service.synthesize(try request("zf_001"))
        XCTAssertEqual(h.launcher.processes.count, 2, "the next request starts it again")
    }

    func testStopOfAServerThatIgnoresSigtermEscalatesWithoutBlockingTheMainActor() async throws {
        let h = ServerHarness()
        h.launcher.script = { process in
            process.exitsOnTerminate = false
            process.emitReady()
        }
        h.sleeper.set(.gated, for: .seconds(2))  // the grace period, released by the test
        let service = TTSService(server: h.server, transport: FakeTransport().transport)
        _ = try await h.server.ensureRunning()
        let process = try XCTUnwrap(h.launcher.last)

        let stopping = Task { await service.stop() }
        await waitUntil { h.sleeper.waiting(for: .seconds(2)) == 1 }
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 0, "the main actor is free while stop() waits")
        h.sleeper.release(.seconds(2))
        await stopping.value
        XCTAssertEqual(process.killCount, 1)
        XCTAssertFalse(process.isRunning)
    }
}

/// The first request waits until `fail(_:)`, then fails as a request whose server went away; later
/// requests succeed.
private final class TransportGate: Sendable {
    private struct State {
        var requests = 0
        var failure: URLError.Code?
    }

    private let state = Mutex(State())

    var requests: Int { state.withLock { $0.requests } }
    var transport: HTTPTransport { { [self] request in try await self.send(request) } }

    func fail(_ code: URLError.Code) { state.withLock { $0.failure = code } }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let number = state.withLock { state -> Int in
            state.requests += 1
            return state.requests
        }
        if number == 1 {
            while true {
                if let code = state.withLock({ $0.failure }) { throw URLError(code) }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (Data(synthesisJSON().utf8), response)
    }
}
