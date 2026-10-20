import XCTest

@testable import ReadRead

@MainActor
final class TTSServerProcessTests: XCTestCase {

    // MARK: - Lazy start and launch contract

    func testNothingLaunchesUntilNeeded() {
        let h = ServerHarness()
        XCTAssertEqual(h.server.phase, .stopped)
        XCTAssertTrue(h.launcher.processes.isEmpty)
    }

    func testLaunchUsesContractArgumentsAndCleanEnvironment() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady(port: 50_123, loaded: ["zh"]) }

        let endpoint = try await h.server.ensureRunning(preload: [.zh])

        let process = try XCTUnwrap(h.launcher.last)
        XCTAssertEqual(process.configuration.executable, "/rr/env/bin/python3")
        XCTAssertEqual(process.configuration.arguments, [
            "-I", "-B", "/rr/tts_server/tts_server.py", "--models-dir", "/rr/models", "--preload", "zh",
        ])
        let env = process.configuration.environment
        let token = try XCTUnwrap(env["READREAD_TOKEN"])
        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(token.allSatisfy(\.isHexDigit))
        XCTAssertEqual(env["ORT_DISABLE_TELEMETRY"], "1")
        XCTAssertEqual(env["PYTHONDONTWRITEBYTECODE"], "1")
        XCTAssertEqual(env["PYTHONIOENCODING"], "utf-8")
        XCTAssertEqual(env["READREAD_CACHE_DIR"], "/cache")
        XCTAssertEqual(env["READREAD_USER_LEXICON"], "/lexicon.json")
        XCTAssertEqual(env["HOME"], "/Users/test")
        XCTAssertEqual(env["TMPDIR"], "/tmp/test")
        XCTAssertNil(env["READREAD_HOME"], "the dev shell's environment must not leak into the server")

        XCTAssertEqual(endpoint.port, 50_123)
        XCTAssertEqual(endpoint.token, token)
        XCTAssertEqual(endpoint.pid, process.pid)
        XCTAssertEqual(endpoint.loaded, ["zh"])
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://127.0.0.1:50123")
        XCTAssertEqual(h.server.phase, .ready)
        XCTAssertEqual(h.fs.opened, ["/logs/tts-server.log"], "stderr goes to the log file")
    }

    func testPreloadListIsCanonicalAndOptional() {
        let h = ServerHarness()
        let paths = TTSServerPaths(python: "/p", serverDirectory: "/s", modelsDirectory: "/m", source: .dev)
        let both = h.server.launchConfiguration(paths: paths, token: "t", preload: [.en, .zh, .en])
        XCTAssertEqual(Array(both.arguments.suffix(2)), ["--preload", "zh,en"])
        let none = h.server.launchConfiguration(paths: paths, token: "t", preload: [])
        XCTAssertFalse(none.arguments.contains("--preload"))
    }

    func testEveryLaunchGetsAFreshToken() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        _ = try await h.server.ensureRunning()
        try await h.server.restart()
        XCTAssertEqual(h.launcher.processes.count, 2)
        XCTAssertNotEqual(h.launcher.processes[0].token, h.launcher.processes[1].token)
    }

    func testConcurrentCallersShareOneLaunch() async throws {
        let h = ServerHarness()
        h.launcher.script = { process in Task { @MainActor in process.emitReady() } }
        async let first = h.server.ensureRunning()
        async let second = h.server.ensureRunning()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(h.launcher.processes.count, 1)
    }

    func testReadyAcrossPartialWritesAfterJunk() async throws {
        let h = ServerHarness()
        h.launcher.script = { process in
            process.emit("Loading voices…\nwarming up\nREA")
            Task { @MainActor in process.emit("DY {\"port\":40000,\"pid\":\(process.pid),\"api\":2,\"loaded\":[\"en\"]}\n") }
        }
        let endpoint = try await h.server.ensureRunning()
        XCTAssertEqual(endpoint.port, 40000)
        XCTAssertEqual(endpoint.loaded, ["en"])
    }

    func testPrewarmStartsInTheBackground() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady(loaded: ["en"]) }
        h.server.prewarm(preload: [.en])
        await waitUntil { h.server.phase == .ready }
        XCTAssertEqual(Array(h.launcher.processes[0].configuration.arguments.suffix(2)), ["--preload", "en"])
        h.server.prewarm(preload: [.zh])
        XCTAssertEqual(h.launcher.processes.count, 1, "prewarm is a no-op while running")
    }

    func testCancelledCallerStopsWaitingButTheStartContinues() async throws {
        let h = ServerHarness()
        let waiting = Task { try await h.server.ensureRunning() }
        await waitUntil { h.launcher.processes.count == 1 }
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        h.launcher.last?.emitReady()
        XCTAssertEqual(h.server.phase, .ready)
    }

    // MARK: - Startup failures

    func testFatalBeforeReadySurfacesTheServerMessageAndIsSticky() async throws {
        let h = ServerHarness()
        h.launcher.script = { process in
            process.emit("FATAL {\"message\":\"model file missing: kokoro-v1.0.fp16.onnx\"}\n")
            process.exit(code: 3)
        }
        do {
            _ = try await h.server.ensureRunning()
            XCTFail("expected FATAL")
        } catch let error as TTSError {
            XCTAssertEqual(error, .serverFatal("model file missing: kokoro-v1.0.fp16.onnx"))
            XCTAssertTrue(error.errorDescription?.contains("model file missing") == true)
        }
        XCTAssertEqual(h.server.phase, .failed)
        XCTAssertEqual(h.server.recentCrashCount(), 0, "a reported FATAL is not a crash")

        _ = try? await h.server.ensureRunning()
        XCTAssertEqual(h.launcher.processes.count, 1, "no automatic relaunch after FATAL")
    }

    func testFatalWithoutTrailingNewlineIsReadAtExit() async {
        let h = ServerHarness()
        h.launcher.script = { process in
            process.emit("FATAL {\"message\":\"READREAD_TOKEN not set\"}")
            process.exit(code: 3)
        }
        do {
            _ = try await h.server.ensureRunning()
            XCTFail("expected FATAL")
        } catch {
            XCTAssertEqual(error as? TTSError, .serverFatal("READREAD_TOKEN not set"))
        }
    }

    func testExitBeforeReadyReportsStatusAndLogTail() async {
        let h = ServerHarness()
        h.launcher.script = { $0.exit(code: 1) }
        do {
            _ = try await h.server.ensureRunning()
            XCTFail("expected an error")
        } catch {
            guard case .exitedDuringStartup(let status, let detail)? = error as? TTSError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(status, 1)
            XCTAssertTrue(detail.contains("ValueError: boom"), detail)
        }
        XCTAssertEqual(h.server.phase, .crashed)
        XCTAssertEqual(h.server.recentCrashCount(), 1)
    }

    func testStartTimeoutStopsTheProcess() async {
        let h = ServerHarness()
        h.sleeper.set(.immediate, for: .seconds(90))
        do {
            _ = try await h.server.ensureRunning()
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? TTSError, .startTimeout(seconds: 90))
        }
        let process = h.launcher.last
        await waitUntil { process?.terminateCount == 1 }
        XCTAssertEqual(process?.stdinClosed, true)
        XCTAssertEqual(h.server.phase, .crashed)
    }

    func testInvalidReadyIsAProtocolErrorAndTheProcessIsStopped() async {
        let h = ServerHarness()
        h.launcher.script = { $0.emit("READY {\"port\":1,\"pid\":2,\"api\":1}\n") }
        do {
            _ = try await h.server.ensureRunning()
            XCTFail("expected a protocol error")
        } catch {
            guard case .protocolError? = error as? TTSError else { return XCTFail("\(error)") }
        }
        let process = h.launcher.last
        await waitUntil { process?.terminateCount == 1 }
        XCTAssertEqual(h.server.phase, .failed)
    }

    func testLaunchFailureIsReported() async {
        let h = ServerHarness()
        h.launcher.launchError = CocoaError(.fileReadNoPermission)
        do {
            _ = try await h.server.ensureRunning()
            XCTFail("expected launchFailed")
        } catch {
            guard case .launchFailed? = error as? TTSError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(h.server.phase, .failed)
    }

    func testMissingResourcesFailWithoutLaunching() async {
        let h = ServerHarness(installDev: false)
        do {
            _ = try await h.server.ensureRunning()
            XCTFail("expected resourcesMissing")
        } catch {
            XCTAssertEqual((error as? TTSError)?.isResourcesMissing, true)
        }
        XCTAssertTrue(h.launcher.processes.isEmpty)
    }

    // MARK: - Crashes, backoff, giving up

    func testUnexpectedExitRestartsLazilyWithBackoff() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        h.sleeper.set(.immediate, for: .seconds(1))
        _ = try await h.server.ensureRunning()

        h.launcher.last?.exit(code: 11, signal: true)
        XCTAssertEqual(h.server.phase, .crashed)
        XCTAssertEqual(h.server.lastError, .crashed(status: -11, detail: "Traceback (most recent call last):\nValueError: boom"))
        XCTAssertEqual(h.launcher.processes.count, 1, "restart waits for the next request")

        _ = try await h.server.ensureRunning()
        XCTAssertEqual(h.launcher.processes.count, 2)
        XCTAssertTrue(h.sleeper.calls.contains(.seconds(1)), "backoff before relaunch: \(h.sleeper.calls)")
        XCTAssertEqual(h.server.phase, .ready)
        XCTAssertNil(h.server.lastError)
    }

    func testBackoffIsSkippedWhenTheCrashIsOldEnough() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        _ = try await h.server.ensureRunning()
        h.launcher.last?.exit(code: 1)
        h.clock.advance(5)
        _ = try await h.server.ensureRunning()
        XCTAssertFalse(h.sleeper.calls.contains(.seconds(1)))
    }

    func testGivesUpAfterThreeCrashesWithinTwoMinutes() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        for _ in 0..<3 {
            _ = try await h.server.ensureRunning()
            h.launcher.last?.exit(code: 1)
            h.clock.advance(10)
        }
        XCTAssertEqual(h.server.phase, .failed)
        guard case .gaveUp(_, let logPath)? = h.server.lastError else {
            return XCTFail("expected gaveUp, got \(String(describing: h.server.lastError))")
        }
        XCTAssertEqual(logPath, "/logs/tts-server.log")
        XCTAssertTrue(h.server.lastError?.errorDescription?.contains("/logs/tts-server.log") == true)

        do {
            _ = try await h.server.ensureRunning()
            XCTFail("expected gaveUp")
        } catch {
            guard case .gaveUp? = error as? TTSError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(h.launcher.processes.count, 3, "no automatic restart after giving up")

        try await h.server.restart()
        XCTAssertEqual(h.launcher.processes.count, 4, "an explicit Retry starts again")
        XCTAssertEqual(h.server.phase, .ready)
        XCTAssertEqual(h.server.recentCrashCount(), 0)
    }

    func testCrashesOutsideTheWindowDoNotAccumulate() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        for _ in 0..<3 {
            _ = try await h.server.ensureRunning()
            h.launcher.last?.exit(code: 1)
            h.clock.advance(70)
        }
        XCTAssertEqual(h.server.phase, .crashed)
        XCTAssertEqual(h.server.recentCrashCount(), 1)
    }

    func testStartSupersededDuringItsBackoffNeverLaunches() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        h.sleeper.set(.gated, for: .seconds(1))
        h.sleeper.set(.immediate, for: .seconds(0.5))
        _ = try await h.server.ensureRunning()
        h.launcher.last?.exit(code: 1)  // crash: the next start backs off 1 s
        h.launcher.script = { _ in }    // later launches print READY only when told

        let stale = Task { try await h.server.ensureRunning() }
        await waitUntil { h.sleeper.waiting(for: .seconds(1)) == 1 }
        await h.server.stop()  // e.g. Retry pressed while it waits
        do {
            _ = try await stale.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}

        h.clock.advance(0.5)
        let fresh = Task { try await h.server.ensureRunning() }
        await waitUntil { h.launcher.processes.count == 2 }  // backed off 0.5 s, now waiting for READY
        h.sleeper.release(.seconds(1))                     // the superseded start wakes up
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.launcher.processes.count, 2, "a superseded start must not launch an orphan")

        h.launcher.processes[1].emitReady()
        let endpoint = try await fresh.value
        XCTAssertEqual(endpoint.pid, h.launcher.processes[1].pid)
        XCTAssertEqual(h.server.phase, .ready)
    }

    func testStartupCrashesCountTowardsGivingUp() async {
        let h = ServerHarness()
        h.launcher.script = { $0.exit(code: 1) }
        h.sleeper.set(.immediate, for: .seconds(1))
        h.sleeper.set(.immediate, for: .seconds(2))
        for _ in 0..<3 { _ = try? await h.server.ensureRunning() }
        XCTAssertEqual(h.server.phase, .failed)
        guard case .gaveUp? = h.server.lastError else { return XCTFail("\(String(describing: h.server.lastError))") }
    }

    // MARK: - Stop

    func testStopClosesStdinSendsSigtermAndIsNotACrash() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        _ = try await h.server.ensureRunning()
        let process = try XCTUnwrap(h.launcher.last)

        await h.server.stop()

        XCTAssertTrue(process.stdinClosed)
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 0)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(h.server.phase, .stopped)
        XCTAssertEqual(h.server.recentCrashCount(), 0)
        XCTAssertNil(h.server.lastError)
        XCTAssertEqual(h.server.lastExit?.pid, process.pid)
    }

    func testStopEscalatesToSigkillAfterTheGracePeriod() async throws {
        let h = ServerHarness()
        h.launcher.script = { process in
            process.exitsOnTerminate = false
            process.emitReady()
        }
        h.sleeper.set(.immediate, for: .seconds(2))
        _ = try await h.server.ensureRunning()
        let process = try XCTUnwrap(h.launcher.last)

        await h.server.stop()

        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 1)
        XCTAssertFalse(process.isRunning)
        XCTAssertTrue(h.sleeper.calls.contains(.seconds(2)))
        XCTAssertEqual(h.server.lastExit?.exit, ProcessExit(reason: .signal, code: 9))
        XCTAssertEqual(h.server.phase, .stopped)
    }

    func testStopDuringStartupCancelsWaiters() async {
        let h = ServerHarness()
        let waiting = Task { try await h.server.ensureRunning() }
        await waitUntil { h.launcher.processes.count == 1 }
        await h.server.stop()
        do {
            _ = try await waiting.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(h.launcher.last?.terminateCount, 1)
        XCTAssertEqual(h.server.phase, .stopped)
    }

    func testStopSynchronouslyKillsAProcessThatIgnoresSigterm() async throws {
        var policy = ServerPolicy()
        policy.stopGracePeriod = .milliseconds(30)
        let h = ServerHarness(policy: policy)
        h.launcher.script = { process in
            process.exitsOnTerminate = false
            process.emitReady()
        }
        _ = try await h.server.ensureRunning()
        let process = try XCTUnwrap(h.launcher.last)
        h.server.stopSynchronously()
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 1)
        XCTAssertTrue(process.stdinClosed)
        XCTAssertEqual(h.server.phase, .stopped)
    }

    func testAStartDuringRestartsStopIsJoinedNotDuplicated() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        _ = try await h.server.ensureRunning()
        let old = try XCTUnwrap(h.launcher.last)
        old.exitsOnTerminate = false  // takes a while to exit after SIGTERM
        h.sleeper.set(.gated, for: .seconds(2))

        let restart = Task { try await h.server.restart() }
        await waitUntil { old.terminateCount == 1 }  // restart() waits in stop()
        let other = Task { try await h.server.ensureRunning() }  // Play/Next meanwhile
        await waitUntil { h.launcher.processes.count == 2 }
        old.exit(code: 0)

        let restarted = try await restart.value
        let joined = try await other.value
        XCTAssertEqual(restarted, joined)
        XCTAssertEqual(h.launcher.processes.count, 2, "one new server, not two")
        XCTAssertEqual(h.launcher.processes.filter(\.isRunning).map(\.pid), [restarted.pid])
        XCTAssertEqual(h.server.launchedPIDs, h.launcher.processes.map(\.pid))
        h.sleeper.release(.seconds(2))
        await h.server.stop()
        XCTAssertTrue(h.launcher.processes.allSatisfy { !$0.isRunning })
    }

    func testAStartStoppedBeforeItRunsNeverLaunches() async {
        let h = ServerHarness()
        h.server.prewarm(preload: [.zh])  // its launch task has not run yet
        await h.server.stop()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(h.launcher.processes.isEmpty)
        XCTAssertEqual(h.server.phase, .stopped)
    }

    func testStopEndsAServerStillBeingTerminatedAfterAStartTimeout() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.exitsOnTerminate = false }  // never READY, ignores SIGTERM
        h.sleeper.set(.immediate, for: .seconds(90))
        h.sleeper.set(.gated, for: .seconds(2))
        do {
            _ = try await h.server.ensureRunning()
            XCTFail("expected a timeout")
        } catch {}
        let process = try XCTUnwrap(h.launcher.last)
        await waitUntil { process.terminateCount == 1 && h.sleeper.waiting(for: .seconds(2)) == 1 }
        XCTAssertTrue(h.server.isProcessRunning, "a server being terminated still counts as running")

        let stopping = Task { await h.server.stop() }
        await waitUntil { process.terminateCount == 2 && h.sleeper.waiting(for: .seconds(2)) == 2 }
        h.sleeper.release(.seconds(2))  // both grace periods end: SIGKILL
        await stopping.value

        XCTAssertFalse(process.isRunning)
        XCTAssertGreaterThanOrEqual(process.killCount, 1)
        XCTAssertFalse(h.server.isProcessRunning)
    }

    func testStopSynchronouslyAlsoKillsAServerStillBeingTerminated() async throws {
        var policy = ServerPolicy()
        policy.stopGracePeriod = .milliseconds(30)
        let h = ServerHarness(policy: policy)
        h.launcher.script = { $0.exitsOnTerminate = false }
        h.sleeper.set(.immediate, for: .seconds(90))  // the 30 ms grace sleep stays .forever
        do {
            _ = try await h.server.ensureRunning()
            XCTFail("expected a timeout")
        } catch {}
        let process = try XCTUnwrap(h.launcher.last)
        await waitUntil { process.terminateCount == 1 }

        h.server.stopSynchronously()

        XCTAssertEqual(process.killCount, 1)
        XCTAssertFalse(process.isRunning)
        XCTAssertFalse(h.server.isProcessRunning)
    }

    // MARK: - Idle shutdown

    func testIdleShutdownAfterFifteenMinutesWhileNotPlaying() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        _ = try await h.server.ensureRunning()
        let process = try XCTUnwrap(h.launcher.last)

        h.clock.advance(14 * 60)
        await h.server.checkIdle()
        XCTAssertEqual(h.server.phase, .ready)

        h.server.setPlaybackActive(true)
        h.clock.advance(60 * 60)
        await h.server.checkIdle()
        XCTAssertEqual(h.server.phase, .ready, "never while audio plays")

        h.server.setPlaybackActive(false)  // idle time starts counting now
        h.clock.advance(14 * 60)
        await h.server.checkIdle()
        XCTAssertEqual(h.server.phase, .ready)

        h.clock.advance(61)
        await h.server.checkIdle()
        XCTAssertEqual(h.server.phase, .stopped)
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(h.server.recentCrashCount(), 0)

        _ = try await h.server.ensureRunning()
        XCTAssertEqual(h.launcher.processes.count, 2, "the next request starts it again")
    }

    func testIdleShutdownWaitsForInFlightRequests() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        _ = try await h.server.ensureRunning()

        h.server.beginRequest()
        h.clock.advance(20 * 60)
        await h.server.checkIdle()
        XCTAssertEqual(h.server.phase, .ready)

        h.server.endRequest()
        h.clock.advance(15 * 60)
        await h.server.checkIdle()
        XCTAssertEqual(h.server.phase, .stopped)
    }

    func testIdleMonitorPollsAtTheCheckInterval() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        _ = try await h.server.ensureRunning()
        await waitUntil { h.sleeper.calls.contains(.seconds(60)) }
    }

    // MARK: - Connection failures

    func testUnreachableLiveServerIsReplacedAndCountedAsACrash() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        h.sleeper.set(.immediate, for: .milliseconds(1500))
        let endpoint = try await h.server.ensureRunning()
        let process = try XCTUnwrap(h.launcher.last)

        await h.server.recoverFromConnectionFailure(endpoint, error: .connectionFailed("refused"))

        XCTAssertEqual(h.server.phase, .crashed)
        XCTAssertEqual(h.server.recentCrashCount(), 1)
        await waitUntil { process.terminateCount == 1 }
    }

    func testRecoveryAfterAnAlreadyRecordedExitDoesNotDoubleCount() async throws {
        let h = ServerHarness()
        h.launcher.script = { $0.emitReady() }
        let endpoint = try await h.server.ensureRunning()
        h.launcher.last?.exit(code: 1)
        await h.server.recoverFromConnectionFailure(endpoint, error: .connectionFailed("refused"))
        XCTAssertEqual(h.server.recentCrashCount(), 1)
    }
}
