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
}
