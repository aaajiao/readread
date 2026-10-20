import XCTest

@testable import ReadRead

/// Real child processes (/bin/sh), so the pipes, the stdin heartbeat, signal
/// handling and callback ordering of the Foundation launcher are exercised for
/// real. No Python, no models, no network.
@MainActor
final class FoundationProcessLauncherTests: XCTestCase {
    private var directory: URL!
    private var launched: [any ServerProcessHandle] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadReadTests-proc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var servers: [TTSServerProcess] = []

    override func tearDown() async throws {
        for handle in launched where handle.isRunning { handle.kill() }
        launched.removeAll()
        for server in servers { server.stopSynchronously() }
        servers.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    final class Events {
        var stdout = Data()
        var exit: ProcessExit?
        var stdoutAfterExit = false
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    private func launch(_ script: String, stderr: FileHandle = .nullDevice, events: Events) throws -> any ServerProcessHandle {
        let handle = try FoundationProcessLauncher().launch(
            LaunchConfiguration(executable: "/bin/sh", arguments: ["-c", script],
                                environment: ["PATH": "/usr/bin:/bin"], currentDirectory: nil),
            stderr: stderr,
            onStdout: { data in
                if events.exit != nil { events.stdoutAfterExit = true }
                events.stdout.append(data)
            },
            onExit: { events.exit = $0 })
        launched.append(handle)
        return handle
    }

    // MARK: - Launcher

    func testClosingStdinEndsAChildThatWaitsForEOF() async throws {
        let events = Events()
        let handle = try launch(#"echo 'READY {"port":1}'; cat >/dev/null; echo done"#, events: events)
        await waitUntil { events.text.contains("READY") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(handle.isRunning, "the child waits for stdin EOF")
        XCTAssertNil(events.exit)

        handle.closeStdin()

        await waitUntil { events.exit != nil }
        XCTAssertEqual(events.exit, ProcessExit(reason: .exit, code: 0))
        XCTAssertEqual(events.text, "READY {\"port\":1}\ndone\n")
        XCTAssertFalse(events.stdoutAfterExit)
    }

    func testFatalLineArrivesBeforeTheExitItExplains() async throws {
        let events = Events()
        _ = try launch(#"printf 'FATAL {"message":"boom"}'; exit 3"#, events: events)
        await waitUntil { events.exit != nil }
        XCTAssertEqual(events.exit, ProcessExit(reason: .exit, code: 3))
        XCTAssertEqual(events.text, #"FATAL {"message":"boom"}"#)
        XCTAssertFalse(events.stdoutAfterExit)
    }

    func testStderrIsAppendedToTheLogFile() async throws {
        let path = directory.appendingPathComponent("tts-server.log").path
        let log = try LocalFileSystem().openForAppending(atPath: path)
        ServerLog.note("before", to: log)
        let events = Events()
        _ = try launch("echo 'Traceback: oops' >&2; exit 1", stderr: log, events: events)
        await waitUntil { events.exit != nil }
        ServerLog.note("after", to: log)
        try log.close()

        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "\(lines)")
        XCTAssertTrue(lines[0].hasSuffix("[app] before"))
        XCTAssertEqual(lines[1], "Traceback: oops")
        XCTAssertTrue(lines[2].hasSuffix("[app] after"))
        XCTAssertEqual(events.exit, ProcessExit(reason: .exit, code: 1))
    }

    func testKillEndsAChildThatIgnoresSigterm() async throws {
        let events = Events()
        let handle = try launch("trap '' TERM; echo up; read line", events: events)
        await waitUntil { events.text == "up\n" }

        handle.terminate()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(handle.isRunning, "SIGTERM is ignored")

        handle.kill()
        await waitUntil { events.exit != nil }
        XCTAssertEqual(events.exit, ProcessExit(reason: .signal, code: SIGKILL))
        XCTAssertFalse(handle.isRunning)
    }

    func testLaunchingAMissingExecutableThrows() {
        XCTAssertThrowsError(try FoundationProcessLauncher().launch(
            LaunchConfiguration(executable: directory.appendingPathComponent("nope").path, arguments: [],
                                environment: [:], currentDirectory: nil),
            stderr: .nullDevice, onStdout: { _ in }, onExit: { _ in }))
    }

    // MARK: - The whole lifecycle against a fake server script

    /// A READREAD_HOME whose `env/bin/python3` is a shell script, with sparse
    /// model files of the exact contract sizes (no real disk use).
    private func makeServerHome(python script: String) throws -> String {
        let home = directory.appendingPathComponent("rrhome", isDirectory: true)
        let fm = FileManager.default
        for sub in ["env/bin", "tts_server", "models"] {
            try fm.createDirectory(at: home.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let python = home.appendingPathComponent("env/bin/python3")
        try script.write(to: python, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try "# placeholder\n".write(to: home.appendingPathComponent("tts_server/tts_server.py"), atomically: true, encoding: .utf8)
        for model in ModelFile.all {
            let path = home.appendingPathComponent("models/\(model.name)").path
            let handle = try LocalFileSystem().openForAppending(atPath: path)
            try handle.truncate(atOffset: model.bytes)
            try handle.close()
        }
        return home.path
    }

    private func makeServer(home: String) -> TTSServerProcess {
        let environment = ServerEnvironment(
            launcher: FoundationProcessLauncher(),
            fileSystem: LocalFileSystem(),
            pathContext: TTSServerPaths.Context(
                bundleResources: nil, environment: ["READREAD_HOME": home],
                homeDirectory: directory.path, currentDirectory: directory.path),
            directories: RuntimeDirectories(
                logDirectory: directory.appendingPathComponent("logs").path,
                cacheDirectory: directory.appendingPathComponent("cache").path,
                userLexicon: directory.appendingPathComponent("lexicon_zh.json").path),
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { try await Task.sleep(for: $0) },
            makeToken: { ServerToken.make() })
        var policy = ServerPolicy()
        policy.startTimeout = .seconds(15)
        let server = TTSServerProcess(environment: environment, policy: policy)
        servers.append(server)
        return server
    }

    private var logText: String {
        (try? String(contentsOfFile: directory.appendingPathComponent("logs/tts-server.log").path, encoding: .utf8)) ?? ""
    }

    func testRealLifecycleStartsHandshakesAndStops() async throws {
        let home = try makeServerHome(python: """
            #!/bin/sh
            echo "args: $*" >&2
            echo "token-length: ${#READREAD_TOKEN} telemetry: $ORT_DISABLE_TELEMETRY home-leak: ${READREAD_HOME:-none}" >&2
            echo "warming up"
            printf 'READY {"port":45678,"pid":%s,"api":2,"loaded":["zh"]}\\n' $$
            cat >/dev/null
            echo "stdin closed" >&2
            """)
        let server = makeServer(home: home)

        let endpoint = try await server.ensureRunning(preload: [.zh])

        XCTAssertEqual(endpoint.port, 45678)
        XCTAssertEqual(endpoint.loaded, ["zh"])
        XCTAssertEqual(server.phase, .ready)
        XCTAssertTrue(server.isProcessRunning)
        XCTAssertEqual(kill(endpoint.pid, 0), 0, "the child is alive")

        await server.stop()

        XCTAssertEqual(server.phase, .stopped)
        XCTAssertFalse(server.isProcessRunning)
        XCTAssertEqual(server.lastExit?.pid, endpoint.pid)
        XCTAssertEqual(kill(endpoint.pid, 0), -1, "the child is gone")
        let log = logText
        XCTAssertTrue(log.contains("args: -I -B \(home)/tts_server/tts_server.py --models-dir \(home)/models --preload zh"), log)
        XCTAssertTrue(log.contains("token-length: 64 telemetry: 1 home-leak: none"), log)
        XCTAssertTrue(log.contains("unexpected stdout line: warming up"), log)
    }

    func testRealStartupCrashCarriesTheServersStderr() async throws {
        let home = try makeServerHome(python: """
            #!/bin/sh
            echo 'Traceback (most recent call last):' >&2
            echo "ModuleNotFoundError: No module named 'kokoro_onnx'" >&2
            exit 1
            """)
        let server = makeServer(home: home)
        do {
            _ = try await server.ensureRunning()
            XCTFail("expected a startup failure")
        } catch {
            guard case .exitedDuringStartup(let status, let detail)? = error as? TTSError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(status, 1)
            XCTAssertTrue(detail.contains("ModuleNotFoundError: No module named 'kokoro_onnx'"), detail)
            XCTAssertFalse(detail.contains("[app]"), "only the server's own lines: \(detail)")
        }
        XCTAssertEqual(server.phase, .crashed)
    }

    func testRealFatalIsSurfacedVerbatim() async throws {
        let home = try makeServerHome(python: """
            #!/bin/sh
            printf 'FATAL {"message":"model file missing: kokoro-v1.0.fp16.onnx"}\\n'
            exit 3
            """)
        let server = makeServer(home: home)
        do {
            _ = try await server.ensureRunning()
            XCTFail("expected FATAL")
        } catch {
            XCTAssertEqual(error as? TTSError, .serverFatal("model file missing: kokoro-v1.0.fp16.onnx"))
        }
        XCTAssertEqual(server.phase, .failed)
        await waitUntil { server.lastExit != nil }
        // Normally its own `exit 3`; our follow-up SIGTERM may in theory win the race.
        let exit = try XCTUnwrap(server.lastExit?.exit)
        XCTAssertTrue(exit == ProcessExit(reason: .exit, code: 3) || exit == ProcessExit(reason: .signal, code: SIGTERM), "\(exit)")
        XCTAssertFalse(server.isProcessRunning)
    }

    func testRealUnexpectedExitAfterReadyIsACrash() async throws {
        let home = try makeServerHome(python: """
            #!/bin/sh
            printf 'READY {"port":45679,"pid":%s,"api":2,"loaded":[]}\\n' $$
            read line
            """)
        let server = makeServer(home: home)
        let endpoint = try await server.ensureRunning()
        // Die from a signal the way a crash would (SIGUSR1: no crash report).
        kill(endpoint.pid, SIGUSR1)
        await waitUntil { server.phase == .crashed }
        guard case .crashed(let status, _)? = server.lastError else {
            return XCTFail("\(String(describing: server.lastError))")
        }
        XCTAssertEqual(status, -SIGUSR1)
        XCTAssertEqual(server.recentCrashCount(), 1)
        XCTAssertNil(server.endpoint)
    }
}
