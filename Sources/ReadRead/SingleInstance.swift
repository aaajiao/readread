import AppKit

/// One ReadRead at a time: a second launch activates the first and exits, so two
/// apps never run two ~2 GB TTS servers.
enum SingleInstance {
    struct RunningApp: Equatable {
        let pid: pid_t
        let bundleID: String?
    }

    /// The pid of another instance to hand over to, or nil to keep running.
    /// Skipped without a bundle id (`swift run`) and in --self-test.
    static func otherInstance(
        bundleID: String?, ownPID: pid_t, isSelfTest: Bool, running: [RunningApp]
    ) -> pid_t? {
        guard !isSelfTest, let bundleID, !bundleID.isEmpty else { return nil }
        return running.first { $0.bundleID == bundleID && $0.pid != ownPID }?.pid
    }

    /// If another instance is running, activate it and return true (the caller exits).
    @MainActor
    static func handOffToRunningInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let running = apps.map { RunningApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier) }
        guard let pid = otherInstance(bundleID: bundleID, ownPID: getpid(), isSelfTest: false, running: running),
              let other = apps.first(where: { $0.processIdentifier == pid })
        else { return false }
        other.activate(options: [.activateAllWindows])
        return true
    }
}
