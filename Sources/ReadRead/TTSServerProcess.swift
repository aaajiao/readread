import Foundation
import Observation

/// Everything the server lifecycle (and `HQInstaller`'s runs) touch outside themselves,
/// injectable so the whole lifecycle (start, READY/FATAL, crashes, backoff, idle shutdown,
/// stop) is unit-tested without Python. Same seam style as `WebExtractor.fetchWithRetry`.
@MainActor
struct ServerEnvironment {
    var launcher: any ProcessLauncher
    var fileSystem: any FileSystem
    var pathContext: TTSServerPaths.Context
    var directories: RuntimeDirectories
    /// Monotonic seconds.
    var now: @MainActor () -> TimeInterval
    var sleep: @Sendable (Duration) async throws -> Void
    var makeToken: @MainActor () -> String

    static func live() -> ServerEnvironment {
        let context = TTSServerPaths.Context.live()
        let reference = ContinuousClock.now
        return ServerEnvironment(
            launcher: FoundationProcessLauncher(),
            fileSystem: LocalFileSystem(),
            pathContext: context,
            directories: RuntimeDirectories(environment: context.environment, homeDirectory: context.homeDirectory),
            now: { (ContinuousClock.now - reference).timeInterval },
            sleep: { try await Task.sleep(for: $0) },
            makeToken: { ServerToken.make() }
        )
    }
}

struct ServerPolicy: Sendable {
    var startTimeout: Duration = .seconds(90)
    /// SIGTERM → wait this long → SIGKILL.
    var stopGracePeriod: Duration = .seconds(2)
    var idleTimeout: TimeInterval = 15 * 60
    var idleCheckInterval: Duration = .seconds(60)
    var crashWindow: TimeInterval = 120
    var maxCrashesInWindow = 3
    /// After an unexpected exit, the next launch waits until the last crash is at
    /// least this old: 1 s after one recent crash, 2 s after two.
    func backoff(afterCrashes count: Int) -> TimeInterval {
        count <= 0 ? 0 : pow(2, Double(count - 1))
    }

    /// The Qwen server: a cold start reads 3 GB of model and compiles Metal shaders, and it holds
    /// 3–4 GB of memory while it runs, so it gets longer to start and goes 5 minutes after the
    /// last synthesis. Crashes and backoff as for Kokoro.
    static let qwen = ServerPolicy(startTimeout: .seconds(180), idleTimeout: 5 * 60, idleCheckInterval: .seconds(30))
}

/// Which server a `TTSServerProcess` runs. Each flavor has its own lifecycle object: the two
/// servers never share a process, a log or a policy.
enum ServerFlavor: Equatable, Sendable {
    /// The bundled Kokoro server (today's launch, the default).
    case kokoro
    /// Qwen3-TTS from the high-quality install: its venv's python, `--engine qwen --model 1.7b`.
    case qwen(HQInstallation)

    var engine: EngineKind {
        switch self {
        case .kokoro: .kokoro
        case .qwen: .qwen
        }
    }

    /// `SpeechSynthesizer.engineID` of its synthesizer.
    var engineID: String {
        switch self {
        case .kokoro: "kokoro"
        case .qwen: QwenModel.engineID
        }
    }

    /// Kokoro synthesizes at the requested speed; Qwen always at 1.0 (the player time-stretches).
    var honoursSpeed: Bool { self == .kokoro }

    /// A FATAL line before READY. Kokoro's is the server's message; the Qwen server's means the
    /// high-quality install cannot run it (a package or a model file missing or damaged, which
    /// installing again repairs), so it is `.hqUnavailable`, naming Settings, with the message as it is.
    func startupFatal(_ message: String) -> TTSError {
        switch self {
        case .kokoro: .serverFatal(message)
        case .qwen: .hqUnavailable(message)
        }
    }

    /// Why `info` is not this flavor's READY line, naming both sides; nil when it is. Kokoro
    /// accepts a server that names no engine (older than the field).
    func readyMismatch(_ info: ReadyInfo) -> String? {
        switch self {
        case .kokoro:
            guard let engine = info.engine, engine != EngineKind.kokoro.rawValue else { return nil }
            return "READY reports engine \(engine), model \(info.model ?? "none"); ReadRead started engine kokoro"
        case .qwen:
            guard info.engine != EngineKind.qwen.rawValue || info.model != QwenModel.id else { return nil }
            return "READY reports engine \(info.engine ?? "none"), model \(info.model ?? "none"); "
                + "ReadRead started engine qwen, model \(QwenModel.id)"
        }
    }
}

/// A ready server: where it listens and the token it requires.
struct ServerEndpoint: Equatable, Sendable {
    let port: Int
    let token: String
    let pid: Int32
    let loaded: [String]
    let generation: Int
    /// What its READY line named (nil from a server older than the fields).
    var engine: String? = nil
    var model: String? = nil

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
}

enum ServerToken {
    /// 32 random bytes as 64 lowercase hex chars (SystemRandomNumberGenerator is
    /// cryptographically secure on Apple platforms).
    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// One launched server process and its handshake state.
@MainActor
final class ServerLaunch {
    let generation: Int
    let token: String
    let log: FileHandle?
    var handle: (any ServerProcessHandle)?
    var pid: Int32 = 0
    var lines = LineBuffer()
    var outcome: Result<ServerEndpoint, any Error>?
    var fatalMessage: String?
    var exit: ProcessExit?
    /// Set when we stop it ourselves: its exit is not a crash.
    var expectedExit = false
    var readyWaiter: CheckedContinuation<ServerEndpoint, any Error>?
    var startTimeoutTask: Task<Void, Never>?
    var exitWaiters: [UUID: (continuation: CheckedContinuation<Bool, Never>, timeout: Task<Void, Never>)] = [:]

    init(generation: Int, token: String, log: FileHandle?) {
        self.generation = generation
        self.token = token
        self.log = log
    }
}

/// Owns the Python TTS server process (main actor): lazy start, READY/FATAL
/// handshake, crash detection with lazy restart and backoff, giving up after
/// repeated crashes, idle shutdown, and SIGTERM → SIGKILL stop. One instance per
/// `ServerFlavor`: Kokoro's, and Qwen's when the high-quality engine is in use.
@MainActor
@Observable
final class TTSServerProcess {
    enum Phase: Equatable {
        /// Not running; starts on demand.
        case stopped
        case starting
        case ready
        /// Exited unexpectedly; restarts lazily (with backoff) on the next request.
        case crashed
        /// Won't start again until `restart()`: FATAL, missing files, protocol
        /// mismatch, or too many crashes.
        case failed
    }

    private(set) var phase: Phase = .stopped
    private(set) var lastError: TTSError?
    private(set) var endpoint: ServerEndpoint?

    @ObservationIgnored let policy: ServerPolicy
    @ObservationIgnored let flavor: ServerFlavor
    @ObservationIgnored private let env: ServerEnvironment
    @ObservationIgnored private var current: ServerLaunch?
    /// Launches detached from `current` while still alive (start timeout, FATAL,
    /// invalid READY, an unreachable server, a stop() still waiting), until their exit
    /// is recorded: stop() and stopSynchronously() end them too, and they count as running.
    @ObservationIgnored private var terminating: [ObjectIdentifier: ServerLaunch] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var crashTimes: [TimeInterval] = []
    @ObservationIgnored private var startWaiters: [UUID: CheckedContinuation<ServerEndpoint, any Error>] = [:]
    /// Bumped by every start and every stop, so a start superseded while it
    /// waited out its backoff never launches a second (orphaned) process.
    @ObservationIgnored private var startAttempt = 0
    @ObservationIgnored private var activeRequests = 0
    @ObservationIgnored private var lastActivity: TimeInterval = 0
    @ObservationIgnored private var playbackActive = false
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    /// Paths used by the most recent launch (self-test report).
    @ObservationIgnored private(set) var resolvedPaths: TTSServerPaths?
    /// The most recent process exit (self-test report).
    @ObservationIgnored private(set) var lastExit: (pid: Int32, exit: ProcessExit)?
    /// Every process launched, in order (self-test: each one must be gone).
    @ObservationIgnored private(set) var launchedPIDs: [Int32] = []

    /// `policy` defaults to the flavor's: `ServerPolicy()` for Kokoro, `.qwen` for Qwen.
    init(environment: ServerEnvironment, flavor: ServerFlavor = .kokoro, policy: ServerPolicy? = nil) {
        self.env = environment
        self.flavor = flavor
        self.policy = policy ?? (flavor == .kokoro ? ServerPolicy() : .qwen)
    }

    /// `tts-server.log` for Kokoro, `tts-server-qwen.log` for Qwen.
    var logPath: String {
        flavor == .kokoro ? env.directories.logFile : env.directories.qwenLogFile
    }
    var directories: RuntimeDirectories { env.directories }
    /// The current server or one still being terminated is alive.
    var isProcessRunning: Bool {
        (current?.handle?.isRunning ?? false) || terminating.values.contains { $0.handle?.isRunning ?? false }
    }

    func recentCrashCount() -> Int {
        pruneCrashes()
        return crashTimes.count
    }

    // MARK: - Start

    /// A ready server, started if needed. Concurrent callers share one start. A
    /// caller whose task is cancelled stops waiting; the start itself continues.
    func ensureRunning(preload: [SpeechLanguage] = []) async throws -> ServerEndpoint {
        switch phase {
        case .ready:
            if let endpoint { return endpoint }
            beginStart(preload: preload)
        case .starting:
            break
        case .failed:
            throw lastError ?? TTSError.launchFailed("unknown error")
        case .stopped, .crashed:
            beginStart(preload: preload)
        }
        return try await waitForStart()
    }

    /// Start in the background if not running; errors surface on the next request.
    func prewarm(preload: [SpeechLanguage]) {
        guard phase == .stopped || phase == .crashed else { return }
        beginStart(preload: preload)
    }

    /// Explicit retry: forget past crashes and failures, stop, start fresh. A
    /// start that begins while the old server exits (Play, Next, ...) is joined,
    /// never duplicated.
    @discardableResult
    func restart(preload: [SpeechLanguage] = []) async throws -> ServerEndpoint {
        resetFailure()
        await stop()
        return try await ensureRunning(preload: preload)
    }

    /// The user chose this engine again: past crashes and a failure that keeps it from starting
    /// (FATAL, too many crashes) are forgotten, so the next request starts a fresh server. A server
    /// running or starting is left as it is.
    func resetFailure() {
        crashTimes.removeAll()
        lastError = nil
        if phase == .failed { phase = .stopped }
    }

    private func beginStart(preload: [SpeechLanguage]) {
        phase = .starting
        startAttempt += 1
        let attempt = startAttempt
        Task { await self.runStart(preload: preload, attempt: attempt) }
    }

    private func runStart(preload: [SpeechLanguage], attempt: Int) async {
        let result: Result<ServerEndpoint, any Error>
        do {
            result = .success(try await launchAndWaitForReady(preload: preload, attempt: attempt))
        } catch {
            result = .failure(error)
        }
        // Superseded by stop() (which already answered the waiters) or by a
        // newer start (which will).
        guard attempt == startAttempt else { return }
        resumeStartWaiters(with: result)
    }

    private func resumeStartWaiters(with result: Result<ServerEndpoint, any Error>) {
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(with: result) }
    }

    private func waitForStart() async throws -> ServerEndpoint {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    startWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.startWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    private func launchAndWaitForReady(preload: [SpeechLanguage], attempt: Int) async throws -> ServerEndpoint {
        // A restart after a crash first waits out the backoff.
        pruneCrashes()
        if let lastCrash = crashTimes.last {
            let wait = policy.backoff(afterCrashes: crashTimes.count) - (env.now() - lastCrash)
            if wait > 0 { try? await env.sleep(.seconds(wait)) }
        }
        // Superseded since beginStart (a stop, or a newer start): never launch. Nothing
        // below suspends before the launch, so this holds until `current` is set.
        guard phase == .starting, attempt == startAttempt else { throw CancellationError() }

        let paths: TTSServerPaths
        do {
            paths = try resolvePaths()
        } catch {
            throw registerFailure(error, countsAsCrash: false)
        }
        resolvedPaths = paths

        let logHandle = (try? ServerLog(path: logPath, fileSystem: env.fileSystem).prepareForLaunch())
            ?? FileHandle.nullDevice
        generation += 1
        let launch = ServerLaunch(generation: generation, token: env.makeToken(), log: logHandle)
        if let previous = current {
            // Cannot happen through the phases above; if it ever does, never leave a server untracked.
            ServerLog.note("replacing server pid \(previous.pid) that was still current", to: logHandle)
            detachAndTerminate(previous)
        }
        current = launch
        let configuration = launchConfiguration(paths: paths, token: launch.token, preload: preload)
        ServerLog.note("launching \(flavor == .kokoro ? "TTS" : "Qwen TTS") server (\(paths.source.rawValue)): "
            + "\(configuration.executable) " + configuration.arguments.joined(separator: " "), to: logHandle)

        let handle: any ServerProcessHandle
        do {
            handle = try env.launcher.launch(
                configuration,
                stderr: logHandle,
                onStdout: { [weak self] data in self?.handleStdout(data, from: launch) },
                onExit: { [weak self] exit in self?.handleExit(exit, of: launch) }
            )
        } catch {
            if current === launch { current = nil }
            ServerLog.note("launch failed: \(error.localizedDescription)", to: logHandle)
            throw registerFailure(.launchFailed(error.localizedDescription), countsAsCrash: false)
        }
        launch.pid = handle.pid
        launchedPIDs.append(handle.pid)
        if launch.exit == nil { launch.handle = handle }
        return try await waitForReady(launch)
    }

    private func resolvePaths() throws(TTSError) -> TTSServerPaths {
        switch flavor {
        case .kokoro:
            try TTSServerPaths.resolve(env.pathContext, fileSystem: env.fileSystem)
        case .qwen(let installation):
            try TTSServerPaths.resolveQwen(env.pathContext, installation: installation, fileSystem: env.fileSystem)
        }
    }

    /// Kokoro: `-I -B <server>/tts_server.py --models-dir <models> [--preload …]`; Qwen adds
    /// `--engine qwen --model 1.7b` before `--models-dir <hq>/models`. Both get the same clean
    /// environment.
    func launchConfiguration(paths: TTSServerPaths, token: String, preload: [SpeechLanguage]) -> LaunchConfiguration {
        var arguments = ["-I", "-B", paths.serverScript]
        if case .qwen = flavor { arguments += ["--engine", EngineKind.qwen.rawValue, "--model", QwenModel.id] }
        arguments += ["--models-dir", paths.modelsDirectory]
        let routes = SpeechLanguage.allCases.filter(preload.contains)
        if !routes.isEmpty {
            arguments += ["--preload", routes.map(\.rawValue).joined(separator: ",")]
        }
        let parent = env.pathContext.environment
        // A clean environment: only what the server needs, nothing from a dev shell.
        var environment: [String: String] = [
            "READREAD_TOKEN": token,
            "ORT_DISABLE_TELEMETRY": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONIOENCODING": "utf-8",
            "READREAD_CACHE_DIR": env.directories.cacheDirectory,
            "READREAD_USER_LEXICON": env.directories.userLexicon,
            "HOME": parent["HOME"] ?? env.pathContext.homeDirectory,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
        ]
        if let tmp = parent["TMPDIR"], !tmp.isEmpty { environment["TMPDIR"] = tmp }
        return LaunchConfiguration(
            executable: paths.python, arguments: arguments, environment: environment, currentDirectory: nil)
    }

    private func waitForReady(_ launch: ServerLaunch) async throws -> ServerEndpoint {
        if let outcome = launch.outcome { return try outcome.get() }
        let sleep = env.sleep
        let timeout = policy.startTimeout
        return try await withCheckedThrowingContinuation { continuation in
            launch.readyWaiter = continuation
            launch.startTimeoutTask = Task { [weak self] in
                do { try await sleep(timeout) } catch { return }
                self?.handleStartTimeout(launch)
            }
        }
    }

    // MARK: - Process events

    private func handleStdout(_ data: Data, from launch: ServerLaunch) {
        for line in launch.lines.append(data) {
            handleLine(line, from: launch)
        }
    }

    private func handleLine(_ line: String, from launch: ServerLaunch) {
        switch ServerHandshake.parse(line: line) {
        case .ready(let info):
            guard launch.outcome == nil else {
                ServerLog.note("ignoring extra READY line: \(line.prefix(300))", to: launch.log)
                return
            }
            if let mismatch = flavor.readyMismatch(info) {
                rejectStartup(launch, protocolError: mismatch)
                return
            }
            ServerLog.note("server ready on port \(info.port) (pid \(info.pid), loaded \(info.loaded))", to: launch.log)
            let endpoint = ServerEndpoint(
                port: info.port, token: launch.token, pid: Int32(clamping: info.pid),
                loaded: info.loaded, generation: launch.generation, engine: info.engine, model: info.model)
            resolveStartup(launch, .success(endpoint))
        case .fatal(let message):
            launch.fatalMessage = message
            ServerLog.note("server reported FATAL: \(message)", to: launch.log)
            guard launch.outcome == nil else { return }
            let failure = flavor.startupFatal(message)
            let error = launch === current ? registerFailure(failure, countsAsCrash: false) : failure
            detachAndTerminate(launch)
            resolveStartup(launch, .failure(error))
        case .invalidReady(let message):
            rejectStartup(launch, protocolError: message)
        case .junk(let text):
            if !text.isEmpty {
                ServerLog.note("unexpected stdout line: \(text.prefix(300))", to: launch.log)
            }
        }
    }

    /// A READY line this app cannot use (malformed, another API, another engine or model): the
    /// start fails without retries and the process is stopped.
    private func rejectStartup(_ launch: ServerLaunch, protocolError message: String) {
        ServerLog.note(message, to: launch.log)
        guard launch.outcome == nil else { return }
        let error = launch === current
            ? registerFailure(.protocolError(message), countsAsCrash: false)
            : TTSError.protocolError(message)
        detachAndTerminate(launch)
        resolveStartup(launch, .failure(error))
    }

    private func handleExit(_ exit: ProcessExit, of launch: ServerLaunch) {
        if let tail = launch.lines.finish() { handleLine(tail, from: launch) }
        guard launch.exit == nil else { return }
        launch.exit = exit
        lastExit = (launch.pid, exit)
        launch.handle = nil
        terminating.removeValue(forKey: ObjectIdentifier(launch))
        ServerLog.note("server pid \(launch.pid) exited (\(TTSError.describe(status: exit.encodedStatus)))", to: launch.log)
        for waiter in launch.exitWaiters.values {
            waiter.timeout.cancel()
            waiter.continuation.resume(returning: true)
        }
        launch.exitWaiters.removeAll()

        // Stopped, replaced or already failed: nothing more to report.
        guard launch === current, !launch.expectedExit else { return }
        current = nil
        endpoint = nil
        idleTask?.cancel()
        idleTask = nil

        switch launch.outcome {
        case nil:
            // Died before READY without a FATAL line.
            let error = registerFailure(
                .exitedDuringStartup(status: exit.encodedStatus, detail: logTailForMessages()),
                countsAsCrash: true)
            resolveStartup(launch, .failure(error))
        case .success?:
            // Died while serving: restart lazily on the next request.
            registerFailure(.crashed(status: exit.encodedStatus, detail: logTailForMessages()), countsAsCrash: true)
        case .failure?:
            break
        }
    }

    private func handleStartTimeout(_ launch: ServerLaunch) {
        guard launch.outcome == nil, launch === current else { return }
        let seconds = Int(policy.startTimeout.timeInterval.rounded())
        ServerLog.note("server not ready after \(seconds) s; stopping it", to: launch.log)
        let error = registerFailure(.startTimeout(seconds: seconds), countsAsCrash: true)
        detachAndTerminate(launch)
        resolveStartup(launch, .failure(error))
    }

    private func resolveStartup(_ launch: ServerLaunch, _ result: Result<ServerEndpoint, any Error>) {
        guard launch.outcome == nil else { return }
        launch.outcome = result
        launch.startTimeoutTask?.cancel()
        launch.startTimeoutTask = nil
        if case .success(let ready) = result, launch === current {
            endpoint = ready
            phase = .ready
            lastError = nil
            lastActivity = env.now()
            startIdleMonitor()
        }
        launch.readyWaiter?.resume(with: result)
        launch.readyWaiter = nil
    }

    /// Records a failure and moves to .crashed or .failed. Returns the error to
    /// surface: a crash that reaches the limit becomes `.gaveUp` with the log path.
    @discardableResult
    private func registerFailure(_ error: TTSError, countsAsCrash: Bool) -> TTSError {
        var surfaced = error
        if countsAsCrash {
            crashTimes.append(env.now())
            pruneCrashes()
            if crashTimes.count >= policy.maxCrashesInWindow {
                surfaced = .gaveUp(lastError: error.errorDescription ?? "\(error)", logPath: logPath)
                phase = .failed
            } else {
                phase = .crashed
            }
        } else {
            phase = .failed
        }
        lastError = surfaced
        return surfaced
    }

    private func pruneCrashes() {
        let cutoff = env.now() - policy.crashWindow
        crashTimes.removeAll { $0 < cutoff }
    }

    private func logTailForMessages() -> String {
        ServerLog(path: logPath, fileSystem: env.fileSystem)
            .tail(lines: 20)
            .filter { !$0.contains("] [app] ") }
            .suffix(6)
            .joined(separator: "\n")
    }

    // MARK: - Stop

    /// Stop the server, and any server still being terminated, and wait until
    /// they have exited: close stdin, SIGTERM, then SIGKILL after the grace
    /// period. Not counted as a crash. Until its exit the server stays tracked:
    /// it counts as running, and a second stop() meanwhile waits for it too.
    func stop() async {
        idleTask?.cancel()
        idleTask = nil
        let launch = current
        current = nil
        endpoint = nil
        if phase != .failed { phase = .stopped }
        cancelPendingStart()
        let detached = Array(terminating.values)
        if let launch {
            launch.expectedExit = true
            resolveStartup(launch, .failure(CancellationError()))
            trackUntilExit(launch)
            await terminateAndWait(launch)
        }
        for other in detached { await terminateAndWait(other) }
    }

    /// For app termination, where nothing can be awaited: signal the server and
    /// any server still being terminated, wait up to the grace period, then SIGKILL.
    func stopSynchronously() {
        idleTask?.cancel()
        idleTask = nil
        let launch = current
        current = nil
        endpoint = nil
        if phase != .failed { phase = .stopped }
        cancelPendingStart()
        let detached = Array(terminating.values)
        if let launch {
            launch.expectedExit = true
            resolveStartup(launch, .failure(CancellationError()))
            trackUntilExit(launch)
        }
        let handles = ([launch].compactMap { $0 } + detached).compactMap { item in
            item.exit == nil ? item.handle : nil
        }
        guard !handles.isEmpty else { return }
        for handle in handles {
            handle.closeStdin()
            handle.terminate()
        }
        let deadline = Date.now.addingTimeInterval(policy.stopGracePeriod.timeInterval)
        while handles.contains(where: \.isRunning) && Date.now < deadline { usleep(20_000) }
        for handle in handles where handle.isRunning { handle.kill() }
    }

    /// Supersede a start in progress (even one still in its backoff sleep) and
    /// release everyone waiting for it.
    private func cancelPendingStart() {
        startAttempt += 1
        resumeStartWaiters(with: .failure(CancellationError()))
    }

    private func detachAndTerminate(_ launch: ServerLaunch) {
        launch.expectedExit = true
        if current === launch {
            current = nil
            endpoint = nil
            idleTask?.cancel()
            idleTask = nil
        }
        trackUntilExit(launch)
        Task { await self.terminateAndWait(launch) }
    }

    /// A launch no longer `current` that has not exited yet: in `terminating` until handleExit
    /// records its exit.
    private func trackUntilExit(_ launch: ServerLaunch) {
        if launch.exit == nil, launch.handle != nil {
            terminating[ObjectIdentifier(launch)] = launch
        }
    }

    private func terminateAndWait(_ launch: ServerLaunch) async {
        guard launch.exit == nil, let handle = launch.handle else { return }
        ServerLog.note("stopping server pid \(handle.pid) (SIGTERM)", to: launch.log)
        handle.closeStdin()
        handle.terminate()
        if await waitForExit(launch, timeout: policy.stopGracePeriod) { return }
        ServerLog.note("server pid \(handle.pid) ignored SIGTERM; sending SIGKILL", to: launch.log)
        handle.kill()
        _ = await waitForExit(launch, timeout: policy.stopGracePeriod)
    }

    private func waitForExit(_ launch: ServerLaunch, timeout: Duration) async -> Bool {
        if launch.exit != nil { return true }
        let id = UUID()
        let sleep = env.sleep
        return await withCheckedContinuation { continuation in
            let timer = Task { @MainActor in
                do { try await sleep(timeout) } catch { return }
                launch.exitWaiters.removeValue(forKey: id)?.continuation.resume(returning: false)
            }
            launch.exitWaiters[id] = (continuation, timer)
        }
    }

    // MARK: - Recovery

    /// A request to `endpoint` could not connect. If that process died, its exit
    /// is (or is about to be) recorded as a crash; if it is alive but not
    /// answering, it is replaced. The next ensureRunning() restarts lazily.
    func recoverFromConnectionFailure(_ endpoint: ServerEndpoint, error: TTSError) async {
        guard let launch = current, launch.generation == endpoint.generation, phase == .ready else { return }
        if await waitForExit(launch, timeout: .milliseconds(1500)) { return }
        guard launch === current, phase == .ready else { return }
        ServerLog.note("server pid \(launch.pid) unreachable (\(error.errorDescription ?? "")); replacing it", to: launch.log)
        registerFailure(error, countsAsCrash: true)
        detachAndTerminate(launch)
    }

    // MARK: - Idle shutdown

    func beginRequest() {
        activeRequests += 1
        lastActivity = env.now()
    }

    func endRequest() {
        activeRequests = max(0, activeRequests - 1)
        lastActivity = env.now()
    }

    func setPlaybackActive(_ active: Bool) {
        // Idle time only counts while nothing plays.
        if playbackActive && !active { lastActivity = env.now() }
        playbackActive = active
    }

    /// Shut down after `idleTimeout` without synthesis while nothing plays.
    func checkIdle() async {
        guard phase == .ready, activeRequests == 0, !playbackActive else { return }
        let idle = env.now() - lastActivity
        guard idle >= policy.idleTimeout else { return }
        ServerLog.note("idle for \(Int(idle)) s; shutting the server down", to: current?.log)
        await stop()
    }

    private func startIdleMonitor() {
        idleTask?.cancel()
        let sleep = env.sleep
        let interval = policy.idleCheckInterval
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                await self?.checkIdle()
            }
        }
    }
}
