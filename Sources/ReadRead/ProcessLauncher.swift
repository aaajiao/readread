import Foundation

/// Everything needed to start the TTS server process.
struct LaunchConfiguration: Sendable, Equatable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var currentDirectory: String?
}

/// How a child process ended.
struct ProcessExit: Sendable, Equatable {
    enum Reason: Sendable, Equatable { case exit, signal }
    let reason: Reason
    /// Exit code, or the signal number when `reason == .signal`.
    let code: Int32

    /// One Int32 for messages: exit codes as-is, signals as negative numbers.
    var encodedStatus: Int32 { reason == .signal ? -code : code }
}

/// A running child. Only the lifecycle object talks to it, on the main actor.
@MainActor
protocol ServerProcessHandle: AnyObject {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    /// SIGTERM.
    func terminate()
    /// SIGKILL.
    func kill()
    /// SIGTERM to the child's process group, so what it runs in the foreground gets it too (bash runs
    /// its trap only once a foreground command has ended); the child alone when it leads no group.
    func terminateGroup()
    /// SIGKILL to the child's process group (nothing it started is left running), as `terminateGroup`.
    func killGroup()
    /// Close our end of the child's stdin; the server treats EOF as "parent gone".
    func closeStdin()
}

extension ServerProcessHandle {
    func terminateGroup() { terminate() }
    func killGroup() { kill() }
}

/// Starts child processes. Callbacks are delivered on the main actor, in order:
/// all stdout data first, then exactly one exit.
@MainActor
protocol ProcessLauncher {
    func launch(
        _ configuration: LaunchConfiguration,
        stderr: FileHandle,
        onStdout: @escaping @MainActor (Data) -> Void,
        onExit: @escaping @MainActor (ProcessExit) -> Void
    ) throws -> any ServerProcessHandle
}

// MARK: - Foundation implementation

struct FoundationProcessLauncher: ProcessLauncher {
    func launch(
        _ configuration: LaunchConfiguration,
        stderr: FileHandle,
        onStdout: @escaping @MainActor (Data) -> Void,
        onExit: @escaping @MainActor (ProcessExit) -> Void
    ) throws -> any ServerProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        if let cwd = configuration.currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }

        // stdin: the write end stays open in the parent for the child's lifetime
        // (heartbeat). stdout: READY/FATAL handshake. stderr: the log file, never
        // an unread pipe that could fill up and block the server.
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        // Parent-side ends must not leak into any child, or EOF would never arrive.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stdoutPipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderr

        let relay = ProcessEventRelay(onStdout: onStdout, onExit: onExit)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            relay.stdout(data)
        }
        process.terminationHandler = { finished in
            let reason: ProcessExit.Reason = finished.terminationReason == .uncaughtSignal ? .signal : .exit
            relay.terminated(ProcessExit(reason: reason, code: finished.terminationStatus))
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        // run() itself closes the parent's copies of the child's ends (stdin read,
        // stdout write; verified: EBADF right after run()), so stdout reaches EOF
        // when the child exits. Closing them again here could close an unrelated
        // descriptor that another thread opened under the same number.

        return FoundationServerProcess(process: process, stdin: stdinPipe.fileHandleForWriting)
    }
}

@MainActor
final class FoundationServerProcess: ServerProcessHandle {
    private let process: Process
    private var stdin: FileHandle?

    init(process: Process, stdin: FileHandle) {
        self.process = process
        self.stdin = stdin
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGTERM)
    }

    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    func terminateGroup() { signalGroup(SIGTERM) }
    func killGroup() { signalGroup(SIGKILL) }

    /// `Process` starts the child as the leader of a process group of its own (pgid == pid), so that
    /// group is the child and what it started, never the app's; otherwise only the child is signalled.
    private func signalGroup(_ signal: Int32) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if getpgid(pid) == pid {
            _ = killpg(pid, signal)
        } else {
            Darwin.kill(pid, signal)
        }
    }

    func closeStdin() {
        try? stdin?.close()
        stdin = nil
    }
}

/// Serializes the pipe and termination callbacks (which arrive on different
/// background queues) and forwards them to the main queue in order: stdout data,
/// then the exit once stdout hit EOF (or after a grace period, in case a
/// grandchild still holds stdout open). This guarantees a FATAL line is seen
/// before the exit it explains.
final class ProcessEventRelay: @unchecked Sendable {
    static let eofGracePeriod: TimeInterval = 1.0

    private let queue = DispatchQueue(label: "readread.tts.process-events")
    private let onStdout: @MainActor (Data) -> Void
    private let onExit: @MainActor (ProcessExit) -> Void
    // Guarded by `queue`.
    private var sawEOF = false
    private var pendingExit: ProcessExit?
    private var exitDelivered = false

    init(onStdout: @escaping @MainActor (Data) -> Void, onExit: @escaping @MainActor (ProcessExit) -> Void) {
        self.onStdout = onStdout
        self.onExit = onExit
    }

    func stdout(_ data: Data) {
        queue.async { [self] in
            if data.isEmpty {
                sawEOF = true
                deliverExitIfPossible()
            } else {
                let callback = onStdout
                DispatchQueue.main.async { MainActor.assumeIsolated { callback(data) } }
            }
        }
    }

    func terminated(_ exit: ProcessExit) {
        queue.async { [self] in
            pendingExit = exit
            if sawEOF {
                deliverExitIfPossible()
            } else {
                queue.asyncAfter(deadline: .now() + Self.eofGracePeriod) { [self] in
                    sawEOF = true
                    deliverExitIfPossible()
                }
            }
        }
    }

    private func deliverExitIfPossible() {
        guard sawEOF, let exit = pendingExit, !exitDelivered else { return }
        exitDelivered = true
        let callback = onExit
        DispatchQueue.main.async { MainActor.assumeIsolated { callback(exit) } }
    }
}
