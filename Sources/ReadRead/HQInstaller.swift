import Foundation
import Observation

extension InstallerEvent {
    /// One stdout line of `install-hq.sh --json-progress` → its event; nil for anything else (a
    /// blank or stray line, malformed JSON, an unknown event, a field missing or of the wrong type).
    static func parse(_ line: String) -> InstallerEvent? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{"), let raw = try? JSONDecoder().decode(RawEvent.self, from: Data(text.utf8)) else {
            return nil
        }
        switch raw.event {
        case "step":
            guard let name = raw.name, let index = raw.index, let count = raw.count else { return nil }
            return .step(name: name, index: index, count: count)
        case "download":
            guard let file = raw.file, let done = raw.done, let total = raw.total else { return nil }
            return .download(file: file, done: done, total: total)
        case "done":
            return .done(models: raw.models ?? [], removed: raw.removed)
        case "error":
            guard let message = raw.message else { return nil }
            return .error(message: message)
        default:
            return nil
        }
    }

    private struct RawEvent: Decodable {
        let event: String
        let name: String?
        let index: Int?
        let count: Int?
        let file: String?
        let done: Int64?
        let total: Int64?
        let models: [String]?
        let removed: Bool?
        let message: String?
    }
}

extension InstallerOperation {
    /// install-hq.sh's mode arguments: none for an install, `--check`, `--uninstall`.
    var scriptArguments: [String] {
        switch self {
        case .install: []
        case .check: ["--check"]
        case .uninstall: ["--uninstall"]
        }
    }

    /// For the installer log.
    var label: String {
        switch self {
        case .install: "install"
        case .check: "check"
        case .uninstall: "uninstall"
        }
    }
}

/// The live `HQInstalling`: runs install-hq.sh as `/bin/bash <script> <mode> --json-progress`
/// through the `ProcessLauncher`, in a clean environment (HOME, a fixed PATH, LANG, TMPDIR
/// `<cache>/installer-tmp`, `READREAD_HQ_HOME`, `READREAD_BUILD_CACHE` `<cache>/hq-build`: never
/// inside the bundle, and `READREAD_TTS_SERVER_DIR`, the server code the app runs). Its stdout
/// events become `state`; its stderr is appended to `hq-install.log` (rotated at 5 MB like the
/// server log), after a header line per run. How it ended decides the outcome: exit 0 after a
/// `done` event finished; a `cancel()` cancelled; an `error` event failed with the script's
/// message; anything else failed with the status and the log's path. Then `installState` is read
/// again and `onFinish` called. Cancel and shutdown signal the script's process group (bash leads
/// one of its own); installer-tmp, its private TMPDIR, is emptied before a run and removed after.
@Observable
@MainActor
final class HQInstaller: HQInstalling {
    private(set) var state: InstallerState = .idle
    private(set) var installState: HQInstallState = .notInstalled
    private(set) var hasLeftoverFiles = false
    @ObservationIgnored var onFinish: (@MainActor (InstallerOperation, InstallerState) -> Void)?
    /// What the last `done` event listed: the installed or checked model (`["1.7b"]`).
    @ObservationIgnored private(set) var reportedModels: [String] = []

    @ObservationIgnored private let env: ServerEnvironment
    @ObservationIgnored private let explicitScript: String?
    @ObservationIgnored private let shutdownGracePeriod: Duration
    @ObservationIgnored private var current: Run?

    /// One run of the script.
    @MainActor
    private final class Run {
        let operation: InstallerOperation
        let log: FileHandle
        var handle: (any ServerProcessHandle)?
        var lines = LineBuffer()
        var progress = InstallerProgress()
        var models: [String]?
        var errorMessage: String?
        var cancelRequested = false
        var exited = false

        init(operation: InstallerOperation, log: FileHandle) {
            self.operation = operation
            self.log = log
        }
    }

    /// `scriptPath` replaces the search for the script (tests). `environment` gives the launcher,
    /// the file system, the context (`$READREAD_HQ_HOME`, the bundle, `$READREAD_HOME`, the working
    /// directory) and the log and cache directories.
    init(scriptPath: String? = nil, environment: ServerEnvironment = .live(),
         shutdownGracePeriod: Duration = .seconds(2)) {
        explicitScript = scriptPath
        env = environment
        self.shutdownGracePeriod = shutdownGracePeriod
        refresh()
    }

    /// `$READREAD_HQ_HOME`, else the default; nil when the variable is set but empty.
    var home: String? {
        HQInstallation.home(environment: env.pathContext.environment, homeDirectory: env.pathContext.homeDirectory)
    }

    var logFileURL: URL { URL(fileURLWithPath: env.directories.installerLogFile) }

    func refresh() {
        let fresh = HQInstallation.state(
            environment: env.pathContext.environment, homeDirectory: env.pathContext.homeDirectory,
            fileSystem: env.fileSystem)
        if fresh != installState { installState = fresh }
        let leftovers = fresh == .notInstalled
            && home.map { HQInstallation.hasLeftovers(home: $0, fileSystem: env.fileSystem) } == true
        if leftovers != hasLeftoverFiles { hasLeftoverFiles = leftovers }
    }

    // MARK: - The script

    /// Where the script is looked for, in order: the explicit path alone, else the bundle's
    /// `Contents/Resources/installer/scripts/install-hq.sh`, the checkout's next to the dev server
    /// code (`$READREAD_HOME/tts_server` is a symlink into the checkout) and
    /// `<cwd>/scripts/install-hq.sh`.
    func scriptCandidates() -> [String] {
        if let explicitScript { return [explicitScript] }
        let context = env.pathContext
        func join(_ base: String, _ path: String) -> String { (base as NSString).appendingPathComponent(path) }
        var candidates: [String] = []
        if let resources = context.bundleResources { candidates.append(join(resources, "installer/scripts/install-hq.sh")) }
        if let home = context.readreadHome {
            let server = env.fileSystem.resolvingSymlinks(atPath: join(home, "tts_server"))
            candidates.append(join((server as NSString).deletingLastPathComponent, "scripts/install-hq.sh"))
        }
        candidates.append(join(context.currentDirectory, "scripts/install-hq.sh"))
        return candidates
    }

    /// The first of `scriptCandidates` that exists.
    func resolveScript() -> String? {
        scriptCandidates().first { env.fileSystem.fileExists(atPath: $0) }
    }

    func launchConfiguration(_ operation: InstallerOperation, script: String, home: String) -> LaunchConfiguration {
        let directories = env.directories
        var environment = [
            "HOME": env.pathContext.environment["HOME"] ?? env.pathContext.homeDirectory,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "TMPDIR": directories.installerTemporaryDirectory,
            "READREAD_HQ_HOME": home,
            "READREAD_BUILD_CACHE": directories.installerBuildCache,
        ]
        // Without it install-hq.sh looks next to itself, which in the bundle has no server code:
        // an install then fails with the script's own message.
        if let server = TTSServerPaths.serverDirectory(env.pathContext, fileSystem: env.fileSystem) {
            environment["READREAD_TTS_SERVER_DIR"] = server
        }
        return LaunchConfiguration(
            executable: "/bin/bash", arguments: [script] + operation.scriptArguments + ["--json-progress"],
            environment: environment, currentDirectory: directories.installerTemporaryDirectory)
    }

    // MARK: - Operations

    /// Start `operation`; ignored while one runs. When it cannot even start (no HQ home, no
    /// script, no temporary directory, the launch failed), `state` is `.failed` at once and
    /// `onFinish` follows on the next turn of the main actor, never inside this call.
    func start(_ operation: InstallerOperation) {
        guard current == nil else { return }
        reportedModels = []
        guard let home else { return failAtOnce(operation, HQInstallation.emptyHomeMessage) }
        guard let script = resolveScript() else {
            let looked = scriptCandidates().joined(separator: ", ")
            return failAtOnce(operation, String(localized: "No install-hq.sh found (looked for \(looked)).", table: "Engine"))
        }
        let directories = env.directories
        let temporary = directories.installerTemporaryDirectory
        // What an earlier run left there goes first (pip's build and unpack directories, after a cancel).
        removeTemporaryDirectory()
        do {
            try env.fileSystem.createDirectory(atPath: temporary)
        } catch {
            let reason = error.localizedDescription
            return failAtOnce(operation, String(localized: "Cannot create \(temporary): \(reason)", table: "Engine"))
        }
        let log = (try? ServerLog(path: directories.installerLogFile, fileSystem: env.fileSystem).prepareForLaunch())
            ?? FileHandle.nullDevice
        let configuration = launchConfiguration(operation, script: script, home: home)
        ServerLog.note("=== install-hq.sh \(operation.label): \(configuration.executable) "
            + configuration.arguments.joined(separator: " ") + " (READREAD_HQ_HOME=\(home)) ===", to: log)

        let run = Run(operation: operation, log: log)
        current = run
        state = .running(operation, run.progress)
        do {
            // A fake launcher may report events and even the exit from inside launch().
            let handle = try env.launcher.launch(
                configuration,
                stderr: log,
                onStdout: { [weak self] data in self?.handleStdout(data, of: run) },
                onExit: { [weak self] exit in self?.handleExit(exit, of: run) })
            if !run.exited { run.handle = handle }
        } catch {
            current = nil
            ServerLog.note("launch failed: \(error.localizedDescription)", to: log)
            failAtOnce(operation, String(localized: "Could not start install-hq.sh: \(error.localizedDescription)",
                                         table: "Engine"))
        }
    }

    /// SIGTERM to the script's process group: what it runs in the foreground (a venv check, the
    /// import check, an extraction) stops too, so its trap runs at once; it stops its downloads and
    /// pip, releases its lock and exits. The state becomes `.cancelled` when it has (`.finished`
    /// when an uninstall's removal had begun: the script lets that finish).
    func cancel() {
        guard let run = current, !run.exited, let handle = run.handle else { return }
        run.cancelRequested = true
        ServerLog.note("cancelled: SIGTERM to process group \(handle.pid)", to: run.log)
        handle.terminateGroup()
    }

    /// App termination: SIGTERM, wait up to the grace period (2 s), then SIGKILL, each to the
    /// script's process group (nothing it started is left behind, holding its lock).
    func shutdown() {
        guard let run = current, !run.exited, let handle = run.handle else { return }
        run.cancelRequested = true
        ServerLog.note("the app is quitting: SIGTERM to process group \(handle.pid)", to: run.log)
        handle.terminateGroup()
        let deadline = Date.now.addingTimeInterval(shutdownGracePeriod.timeInterval)
        while handle.isRunning && Date.now < deadline { usleep(20_000) }
        if handle.isRunning {
            ServerLog.note("pid \(handle.pid) still running; SIGKILL to its process group", to: run.log)
            handle.killGroup()
        }
    }

    /// installer-tmp is the script's own TMPDIR: nothing in it outlives a run.
    private func removeTemporaryDirectory() {
        let temporary = env.directories.installerTemporaryDirectory
        if env.fileSystem.directoryExists(atPath: temporary) { try? env.fileSystem.removeItem(atPath: temporary) }
    }

    // MARK: - Process events

    private func handleStdout(_ data: Data, of run: Run) {
        for line in run.lines.append(data) { handleLine(line, of: run) }
    }

    private func handleLine(_ line: String, of run: Run) {
        guard let event = InstallerEvent.parse(line) else {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                ServerLog.note("unexpected stdout line: \(line.prefix(300))", to: run.log)
            }
            return
        }
        switch event {
        case .step(let name, let index, let count):
            run.progress = InstallerProgress(stepName: name, stepIndex: index, stepCount: count)
        case .download(let file, let done, let total):
            run.progress.file = file
            run.progress.bytesDone = done
            run.progress.bytesTotal = total
        case .done(let models, _):
            run.models = models
        case .error(let message):
            run.errorMessage = message
        }
        if current === run, !run.exited { state = .running(run.operation, run.progress) }
    }

    private func handleExit(_ exit: ProcessExit, of run: Run) {
        if let tail = run.lines.finish() { handleLine(tail, of: run) }
        guard !run.exited else { return }
        run.exited = true
        run.handle = nil
        let status = TTSError.describe(status: exit.encodedStatus)
        let outcome: InstallerState
        let summary: String
        if exit == ProcessExit(reason: .exit, code: 0), run.models != nil, run.errorMessage == nil {
            outcome = .finished(run.operation)
            summary = "finished"
        } else if run.cancelRequested {
            outcome = .cancelled(run.operation)
            summary = "cancelled"
        } else if let message = run.errorMessage {
            outcome = .failed(run.operation, message: message)
            summary = "failed: \(message)"
        } else {
            let log = logFileURL.path
            let message = String(localized: "install-hq.sh stopped (\(status)) before it finished; see the log: \(log)",
                                 table: "Engine")
            outcome = .failed(run.operation, message: message)
            summary = "failed: no done event"
        }
        ServerLog.note("=== install-hq.sh \(run.operation.label) ended (\(status)): \(summary) ===", to: run.log)
        if current === run {
            current = nil
            removeTemporaryDirectory()
        }
        if let models = run.models { reportedModels = models }
        state = outcome
        refresh()
        onFinish?(run.operation, outcome)
    }

    private func failAtOnce(_ operation: InstallerOperation, _ message: String) {
        let outcome = InstallerState.failed(operation, message: message)
        state = outcome
        refresh()
        Task { @MainActor [weak self] in self?.onFinish?(operation, outcome) }
    }
}
