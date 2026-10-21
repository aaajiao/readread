import Foundation
import XCTest

@testable import ReadRead

/// An `HQInstaller` on a fake launcher and file tree: HQ home /hq, `$READREAD_HOME` /rr with the
/// dev server code, logs in /logs, cache in /cache, the script at `script` unless told otherwise.
@MainActor
final class InstallerHarness {
    static let script = "/checkout/scripts/install-hq.sh"

    struct Finish: Equatable {
        let operation: InstallerOperation
        let state: InstallerState
        /// `installState` when `onFinish` ran.
        let installState: HQInstallState
    }

    let fs = FakeFileSystem()
    let launcher = FakeLauncher()
    let installer: HQInstaller
    private(set) var finishes: [Finish] = []

    init(environment: [String: String] = ["READREAD_HQ_HOME": "/hq", "HOME": "/Users/test", "READREAD_HOME": "/rr"],
         bundleResources: String? = nil, scriptPath: String? = InstallerHarness.script, scriptExists: Bool = true,
         devServer: Bool = true, shutdownGracePeriod: Duration = .milliseconds(200)) {
        if let scriptPath, scriptExists { fs.addFile(scriptPath) }
        if devServer { fs.addFile("/rr/tts_server/tts_server.py") }
        let environment = ServerEnvironment(
            launcher: launcher,
            fileSystem: fs,
            pathContext: TTSServerPaths.Context(
                bundleResources: bundleResources, environment: environment,
                homeDirectory: "/Users/test", currentDirectory: "/work"),
            directories: RuntimeDirectories(logDirectory: "/logs", cacheDirectory: "/cache", userLexicon: "/lexicon.json"),
            now: { 0 },
            sleep: { _ in },
            makeToken: { "unused" })
        installer = HQInstaller(scriptPath: scriptPath, environment: environment,
                                shutdownGracePeriod: shutdownGracePeriod)
        installer.onFinish = { [unowned self] operation, state in
            finishes.append(Finish(operation: operation, state: state, installState: installer.installState))
        }
    }

    var process: FakeProcess {
        get throws { try XCTUnwrap(launcher.last, "install-hq.sh was not launched") }
    }

    /// What a finished install leaves in /hq.
    func installFiles(bytes: Int64 = 2_400_000_000) {
        let json = #"{"version":1,"models":{"1.7b":{"bytes":\#(bytes)}},"installed_at":"2026-10-20T09:30:00Z"}"#
        fs.addFile("/hq/install.json", size: UInt64(json.utf8.count))
        fs.tails["/hq/install.json"] = Data(json.utf8)
        fs.directories.insert("/hq/models/" + QwenModel.folder)
        fs.addFile("/hq/venv/bin/python3", executable: true)
        for stamp in HQInstallation.completionStamps { fs.addFile("/hq/" + stamp) }
    }

    func removeInstallFiles() {
        fs.files.removeValue(forKey: "/hq/install.json")
        fs.directories.remove("/hq/models/" + QwenModel.folder)
        fs.files.removeValue(forKey: "/hq/venv/bin/python3")
        for stamp in HQInstallation.completionStamps { fs.files.removeValue(forKey: "/hq/" + stamp) }
    }
}

@MainActor
final class HQInstallerTests: XCTestCase {

    // MARK: - Events

    func testParsesEveryEvent() {
        XCTAssertEqual(InstallerEvent.parse(#"{"event":"step","name":"Model files","index":3,"count":6}"#),
                       .step(name: "Model files", index: 3, count: 6))
        XCTAssertEqual(InstallerEvent.parse(#"  {"event":"download","file":"model.safetensors","done":1200,"total":2400}"# + "\r\n"),
                       .download(file: "model.safetensors", done: 1200, total: 2400))
        XCTAssertEqual(InstallerEvent.parse(#"{"event":"download","file":"big","done":3000000000,"total":3500000000}"#),
                       .download(file: "big", done: 3_000_000_000, total: 3_500_000_000), "past Int32")
        XCTAssertEqual(InstallerEvent.parse(#"{"event":"done","home":"/hq","models":["1.7b"]}"#),
                       .done(models: ["1.7b"], removed: nil))
        XCTAssertEqual(InstallerEvent.parse(#"{"event":"done","removed":true}"#), .done(models: [], removed: true))
        XCTAssertEqual(InstallerEvent.parse(#"{"event":"done","removed":false}"#), .done(models: [], removed: false))
        XCTAssertEqual(InstallerEvent.parse(#"{"event":"error","message":"curl: (6) Could not resolve host"}"#),
                       .error(message: "curl: (6) Could not resolve host"))
        XCTAssertEqual(InstallerEvent.parse(#"{"event":"error","message":"缺少 \"模型\""}"#),
                       .error(message: "缺少 \"模型\""))
    }

    func testJunkAndUnknownEventsAreNil() {
        let junk = [
            "", "   ", "Downloading Python…", "{", "[]", "null", "{}",
            #"{"event":"progress","value":1}"#,
            #"{"event":5}"#,
            #"{"name":"Model files","index":1,"count":6}"#,
            #"{"event":"step","name":"Model files"}"#,
            #"{"event":"step","name":"Model files","index":"1","count":6}"#,
            #"{"event":"download","file":"f","done":1.5,"total":2}"#,
            #"{"event":"download","done":1,"total":2}"#,
            #"{"event":"done","models":"1.7b"}"#,
            #"{"event":"error"}"#,
            #"{"event":"error","message":null}"#,
            #"x {"event":"error","message":"m"}"#,
        ]
        for line in junk { XCTAssertNil(InstallerEvent.parse(line), line) }
    }

    func testOperationsMapToTheScriptsModes() {
        XCTAssertEqual(InstallerOperation.install.scriptArguments, [])
        XCTAssertEqual(InstallerOperation.check.scriptArguments, ["--check"])
        XCTAssertEqual(InstallerOperation.uninstall.scriptArguments, ["--uninstall"])
    }

    // MARK: - Launch

    func testRunsTheScriptWithBashInACleanEnvironment() throws {
        let harness = InstallerHarness(environment: [
            "READREAD_HQ_HOME": "/hq", "HOME": "/Users/test", "READREAD_HOME": "/rr",
            "PATH": "/opt/homebrew/bin:/usr/bin", "PYTHONPATH": "/evil", "VIRTUAL_ENV": "/venv", "TMPDIR": "/var/tmp/x",
            "READREAD_BUILD_CACHE": "/Applications/ReadRead.app/Contents/Resources/installer/build/cache",
        ])
        harness.installer.start(.check)
        let process = try harness.process
        XCTAssertEqual(process.configuration, LaunchConfiguration(
            executable: "/bin/bash",
            arguments: [InstallerHarness.script, "--check", "--json-progress"],
            environment: [
                "HOME": "/Users/test",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8",
                "TMPDIR": "/cache/installer-tmp",
                "READREAD_HQ_HOME": "/hq",
                "READREAD_BUILD_CACHE": "/cache/hq-build",
                "READREAD_TTS_SERVER_DIR": "/rr/tts_server",
            ],
            currentDirectory: "/cache/installer-tmp"))
        XCTAssertTrue(harness.fs.directories.contains("/cache/installer-tmp"), "TMPDIR is made first")
        XCTAssertEqual(harness.installer.state, .running(.check, InstallerProgress()))
    }

    func testModeArgumentsAndTheDefaultHome() throws {
        let install = InstallerHarness(environment: ["READREAD_HOME": "/rr"])
        install.installer.start(.install)
        XCTAssertEqual(try install.process.configuration.arguments, [InstallerHarness.script, "--json-progress"])
        XCTAssertEqual(try install.process.configuration.environment["READREAD_HQ_HOME"],
                       "/Users/test/Library/Application Support/ReadRead/hq")
        XCTAssertEqual(try install.process.configuration.environment["HOME"], "/Users/test", "HOME from the account")

        let uninstall = InstallerHarness()
        uninstall.installer.start(.uninstall)
        XCTAssertEqual(try uninstall.process.configuration.arguments,
                       [InstallerHarness.script, "--uninstall", "--json-progress"])
    }

    func testTheServerDirectoryIsLeftOutWhenThereIsNone() throws {
        let harness = InstallerHarness(devServer: false)
        harness.installer.start(.install)
        XCTAssertNil(try harness.process.configuration.environment["READREAD_TTS_SERVER_DIR"])
    }

    func testTheBundlesServerCodeIsPassedFromTheBundle() throws {
        let resources = "/Applications/ReadRead.app/Contents/Resources"
        let harness = InstallerHarness(bundleResources: resources, scriptPath: nil, devServer: true)
        harness.fs.addFile(resources + "/installer/scripts/install-hq.sh")
        harness.fs.addFile(resources + "/tts_server/tts_server.py")
        harness.installer.start(.check)
        let configuration = try harness.process.configuration
        XCTAssertEqual(configuration.arguments.first, resources + "/installer/scripts/install-hq.sh")
        XCTAssertEqual(configuration.environment["READREAD_TTS_SERVER_DIR"], resources + "/tts_server")
        XCTAssertEqual(configuration.environment["READREAD_BUILD_CACHE"], "/cache/hq-build", "never in the bundle")
    }

    // MARK: - Script resolution

    func testAnExplicitScriptIsTheOnlyCandidate() {
        let harness = InstallerHarness(bundleResources: "/A.app/Contents/Resources", scriptPath: "/x/install-hq.sh")
        XCTAssertEqual(harness.installer.scriptCandidates(), ["/x/install-hq.sh"])
        XCTAssertEqual(harness.installer.resolveScript(), "/x/install-hq.sh")
    }

    func testScriptCandidatesInOrder() {
        let resources = "/A.app/Contents/Resources"
        let harness = InstallerHarness(bundleResources: resources, scriptPath: nil)
        XCTAssertEqual(harness.installer.scriptCandidates(), [
            resources + "/installer/scripts/install-hq.sh",
            "/rr/scripts/install-hq.sh",
            "/work/scripts/install-hq.sh",
        ])
        XCTAssertNil(harness.installer.resolveScript())
        harness.fs.addFile("/work/scripts/install-hq.sh")
        XCTAssertEqual(harness.installer.resolveScript(), "/work/scripts/install-hq.sh")
        harness.fs.addFile("/rr/scripts/install-hq.sh")
        XCTAssertEqual(harness.installer.resolveScript(), "/rr/scripts/install-hq.sh")
        harness.fs.addFile(resources + "/installer/scripts/install-hq.sh")
        XCTAssertEqual(harness.installer.resolveScript(), resources + "/installer/scripts/install-hq.sh")
    }

    func testAnEmptyReadreadHomeAddsNoDevCandidate() {
        let harness = InstallerHarness(environment: ["READREAD_HQ_HOME": "/hq", "READREAD_HOME": ""], scriptPath: nil)
        XCTAssertEqual(harness.installer.scriptCandidates(), ["/work/scripts/install-hq.sh"])
    }

    /// `$READREAD_HOME/tts_server` is setup.sh's symlink into the checkout: the script is the
    /// checkout's, next to that server code.
    func testTheDevScriptIsFoundThroughTheServerSymlink() throws {
        let root = try makeTemporaryDirectory()
        let fm = FileManager.default
        let checkout = root.appending(path: "checkout").path
        let rrHome = root.appending(path: "rrhome").path
        try fm.createDirectory(atPath: checkout + "/tts_server", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: checkout + "/scripts", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: rrHome, withIntermediateDirectories: true)
        try Data("print()\n".utf8).write(to: URL(fileURLWithPath: checkout + "/tts_server/tts_server.py"))
        try Data("#!/bin/bash\n".utf8).write(to: URL(fileURLWithPath: checkout + "/scripts/install-hq.sh"))
        try fm.createSymbolicLink(atPath: rrHome + "/tts_server", withDestinationPath: checkout + "/tts_server")

        let fs = LocalFileSystem()
        let installer = HQInstaller(environment: ServerEnvironment(
            launcher: FakeLauncher(), fileSystem: fs,
            pathContext: TTSServerPaths.Context(
                bundleResources: nil, environment: ["READREAD_HOME": rrHome, "READREAD_HQ_HOME": root.path + "/hq"],
                homeDirectory: "/Users/test", currentDirectory: root.path),
            directories: RuntimeDirectories(logDirectory: root.path + "/logs", cacheDirectory: root.path + "/cache",
                                            userLexicon: root.path + "/lexicon.json"),
            now: { 0 }, sleep: { _ in }, makeToken: { "unused" }))
        let expected = fs.resolvingSymlinks(atPath: checkout) + "/scripts/install-hq.sh"
        XCTAssertEqual(installer.scriptCandidates(), [expected, root.path + "/scripts/install-hq.sh"])
        XCTAssertEqual(installer.resolveScript(), expected)
    }

    // MARK: - Progress and outcomes

    func testProgressThenFinished() throws {
        let harness = InstallerHarness()
        let installer = harness.installer
        installer.start(.install)
        let process = try harness.process

        process.emit(#"{"event":"step","name":"Python","index":1,"count":6}"# + "\n")
        XCTAssertEqual(installer.state, .running(.install, InstallerProgress(stepName: "Python", stepIndex: 1, stepCount: 6)))
        process.emit(#"{"event":"step","name":"Model files","index":3,"count":6}"# + "\n"
            + #"{"event":"download","file":"model.safetensors","done":1200000000,"total":2400000000}"# + "\n")
        XCTAssertEqual(installer.state, .running(.install, InstallerProgress(
            stepName: "Model files", stepIndex: 3, stepCount: 6, file: "model.safetensors",
            bytesDone: 1_200_000_000, bytesTotal: 2_400_000_000)))
        // A step clears the file and its bytes.
        process.emit(#"{"event":"step","name":"Smoke test","index":6,"count":6}"# + "\n")
        XCTAssertEqual(installer.state, .running(.install, InstallerProgress(stepName: "Smoke test", stepIndex: 6, stepCount: 6)))
        XCTAssertEqual(harness.finishes, [])

        harness.installFiles()
        process.emit(#"{"event":"done","home":"/hq","models":["1.7b"]}"# + "\n")
        XCTAssertTrue(installer.state.isRunning, "done alone is not the end: the exit is")
        process.exit(code: 0)

        XCTAssertEqual(installer.state, .finished(.install))
        XCTAssertEqual(installer.reportedModels, ["1.7b"])
        let installation = try XCTUnwrap(installer.installState.installation)
        XCTAssertEqual(installation.modelBytes, 2_400_000_000)
        XCTAssertEqual(harness.finishes, [InstallerHarness.Finish(
            operation: .install, state: .finished(.install), installState: .installed(installation))],
            "onFinish once, after installState was read again")
    }

    func testEventsSplitAcrossReadsAndStrayLines() throws {
        let harness = InstallerHarness()
        harness.installer.start(.check)
        let process = try harness.process
        process.emit(#"{"event":"st"#)
        process.emit(#"ep","name":"Check","index":1,"#)
        XCTAssertEqual(harness.installer.state, .running(.check, InstallerProgress()))
        process.emit(#""count":2}"# + "\r\nnot an event\n\n")
        XCTAssertEqual(harness.installer.state, .running(.check, InstallerProgress(stepName: "Check", stepIndex: 1, stepCount: 2)))
        // The last line without its newline still counts.
        process.emit(#"{"event":"done","models":["1.7b"]}"#)
        process.exit(code: 0)
        XCTAssertEqual(harness.installer.state, .finished(.check))
        XCTAssertEqual(harness.installer.reportedModels, ["1.7b"])
    }

    func testAnErrorEventFailsWithTheScriptsMessage() throws {
        let harness = InstallerHarness()
        harness.installer.start(.install)
        let process = try harness.process
        process.emit(#"{"event":"step","name":"Python","index":1,"count":6}"# + "\n")
        process.emit(#"{"event":"error","message":"sha256 mismatch for python.tar.gz"}"# + "\n")
        process.exit(code: 1)
        XCTAssertEqual(harness.installer.state, .failed(.install, message: "sha256 mismatch for python.tar.gz"))
        XCTAssertEqual(harness.finishes.map(\.state), [.failed(.install, message: "sha256 mismatch for python.tar.gz")])
        XCTAssertEqual(harness.installer.installState, .notInstalled)
    }

    func testAnErrorEventWinsOverExitZero() throws {
        let harness = InstallerHarness()
        harness.installer.start(.check)
        let process = try harness.process
        process.emit(#"{"event":"done","models":["1.7b"]}"# + "\n" + #"{"event":"error","message":"late"}"# + "\n")
        process.exit(code: 0)
        XCTAssertEqual(harness.installer.state, .failed(.check, message: "late"))
    }

    func testOddExitsFailWithTheStatusAndTheLog() throws {
        let cases: [(code: Int32, signal: Bool, done: Bool, status: String)] = [
            (1, false, false, "exit status 1"),
            (0, false, false, "exit status 0"),
            (2, false, true, "exit status 2"),
            (9, true, false, "signal 9"),
        ]
        for item in cases {
            let harness = InstallerHarness()
            harness.installer.start(.check)
            let process = try harness.process
            if item.done { process.emit(#"{"event":"done","models":["1.7b"]}"# + "\n") }
            process.exit(code: item.code, signal: item.signal)
            XCTAssertEqual(harness.installer.state, .failed(.check, message:
                "install-hq.sh stopped (\(item.status)) before it finished; see the log: /logs/hq-install.log"), item.status)
            XCTAssertEqual(harness.finishes.count, 1)
        }
    }

    func testUninstallRefreshesToNotInstalled() throws {
        let harness = InstallerHarness()
        harness.installFiles()
        harness.installer.refresh()
        XCTAssertNotNil(harness.installer.installState.installation)
        harness.installer.start(.uninstall)
        harness.removeInstallFiles()
        let process = try harness.process
        process.emit(#"{"event":"done","removed":true}"# + "\n")
        process.exit(code: 0)
        XCTAssertEqual(harness.installer.state, .finished(.uninstall))
        XCTAssertEqual(harness.finishes, [InstallerHarness.Finish(
            operation: .uninstall, state: .finished(.uninstall), installState: .notInstalled)])
        XCTAssertEqual(harness.installer.reportedModels, [])
    }

    func testStartIsIgnoredWhileARunGoesOnAndANewRunReplacesAnOldOutcome() throws {
        let harness = InstallerHarness()
        harness.installer.start(.install)
        harness.installer.start(.check)
        harness.installer.start(.uninstall)
        XCTAssertEqual(harness.launcher.processes.count, 1)
        XCTAssertEqual(harness.installer.state, .running(.install, InstallerProgress()))
        try harness.process.exit(code: 1)
        XCTAssertFalse(harness.installer.state.isRunning)

        harness.installer.start(.check)
        XCTAssertEqual(harness.launcher.processes.count, 2)
        XCTAssertEqual(harness.installer.state, .running(.check, InstallerProgress()))
    }

    func testAFakeThatFinishesInsideLaunchIsHandled() {
        let harness = InstallerHarness()
        harness.launcher.script = { process in
            process.emit(#"{"event":"done","models":["1.7b"]}"# + "\n")
            process.exit(code: 0)
        }
        harness.installer.start(.check)
        XCTAssertEqual(harness.installer.state, .finished(.check))
        harness.installer.cancel()
        XCTAssertEqual(harness.launcher.last?.terminateCount, 0, "nothing runs any more")
        harness.installer.start(.check)
        XCTAssertEqual(harness.launcher.processes.count, 2, "the run ended, so a new one starts")
    }

    // MARK: - Cancel and shutdown

    func testCancelSendsSIGTERMAndEndsCancelled() throws {
        let harness = InstallerHarness()
        harness.installer.start(.install)
        let process = try harness.process
        process.exitsOnTerminate = false
        process.emit(#"{"event":"download","file":"model.safetensors","done":10,"total":100}"# + "\n")
        harness.installer.cancel()
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertTrue(harness.installer.state.isRunning, "until install-hq.sh has stopped")
        // What install-hq.sh's TERM trap prints, then its exit.
        process.emit(#"{"event":"error","message":"stopped by a signal"}"# + "\n")
        process.exit(code: 143)
        XCTAssertEqual(harness.installer.state, .cancelled(.install))
        XCTAssertEqual(harness.finishes.map(\.state), [.cancelled(.install)])
    }

    /// Its process group, so what install-hq.sh runs in the foreground stops too (and nothing is
    /// left running after a SIGKILL).
    func testCancelAndShutdownSignalTheScriptsProcessGroup() throws {
        let harness = InstallerHarness()
        harness.installer.start(.install)
        let process = try harness.process
        process.exitsOnTerminate = false
        harness.installer.cancel()
        XCTAssertEqual(process.groupSignals, [SIGTERM])
        harness.installer.shutdown()
        XCTAssertEqual(process.groupSignals, [SIGTERM, SIGTERM, SIGKILL])
        XCTAssertEqual(harness.installer.state, .cancelled(.install))
    }

    /// An uninstall whose removal had begun when Cancel came finishes (install-hq.sh ignores
    /// signals from there on): it is uninstalled, not cancelled.
    func testAnUninstallThatFinishesDespiteACancelIsFinished() throws {
        let harness = InstallerHarness()
        harness.installFiles()
        harness.installer.refresh()
        harness.installer.start(.uninstall)
        let process = try harness.process
        process.exitsOnTerminate = false
        harness.installer.cancel()
        harness.removeInstallFiles()
        process.emit(#"{"event":"done","removed":true}"# + "\n")
        process.exit(code: 0)
        XCTAssertEqual(harness.installer.state, .finished(.uninstall))
        XCTAssertEqual(harness.installer.installState, .notInstalled)
    }

    func testCancelWhenTheScriptExitsAtOnce() throws {
        let harness = InstallerHarness()
        harness.installer.start(.install)
        harness.installer.cancel()
        XCTAssertEqual(try harness.process.terminateCount, 1)
        XCTAssertEqual(harness.installer.state, .cancelled(.install))
    }

    func testARunThatFinishedBeforeTheCancelArrivedIsFinished() throws {
        let harness = InstallerHarness()
        harness.installer.start(.check)
        let process = try harness.process
        process.exitsOnTerminate = false
        process.emit(#"{"event":"done","models":["1.7b"]}"# + "\n")
        harness.installer.cancel()
        process.exit(code: 0)
        XCTAssertEqual(harness.installer.state, .finished(.check))
    }

    func testCancelAndShutdownWithoutARunDoNothing() {
        let harness = InstallerHarness()
        harness.installer.cancel()
        harness.installer.shutdown()
        XCTAssertEqual(harness.installer.state, .idle)
        XCTAssertEqual(harness.finishes, [])
    }

    func testShutdownWaitsForTheScriptToStop() throws {
        let harness = InstallerHarness()
        harness.installer.start(.install)
        let process = try harness.process
        harness.installer.shutdown()
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 0, "it stopped on SIGTERM")
        XCTAssertEqual(harness.installer.state, .cancelled(.install))
    }

    func testShutdownEscalatesToSIGKILLAfterTheGracePeriod() throws {
        let harness = InstallerHarness(shutdownGracePeriod: .milliseconds(150))
        harness.installer.start(.install)
        let process = try harness.process
        process.exitsOnTerminate = false
        let started = ContinuousClock.now
        harness.installer.shutdown()
        let waited = ContinuousClock.now - started
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 1)
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(140))
        XCTAssertLessThan(waited, .seconds(2), "bounded by the grace period")
        XCTAssertEqual(harness.installer.state, .cancelled(.install))
    }

    func testTheDefaultGracePeriodIsTwoSeconds() throws {
        let harness = InstallerHarness()
        let defaultInstaller = HQInstaller(scriptPath: InstallerHarness.script, environment: ServerEnvironment(
            launcher: harness.launcher, fileSystem: harness.fs,
            pathContext: TTSServerPaths.Context(bundleResources: nil, environment: ["READREAD_HQ_HOME": "/hq"],
                                                homeDirectory: "/Users/test", currentDirectory: "/work"),
            directories: RuntimeDirectories(logDirectory: "/logs", cacheDirectory: "/cache", userLexicon: "/l.json"),
            now: { 0 }, sleep: { _ in }, makeToken: { "unused" }))
        defaultInstaller.start(.install)
        let process = try harness.process
        process.exitsOnTerminate = false
        let started = ContinuousClock.now
        defaultInstaller.shutdown()
        let waited = ContinuousClock.now - started
        XCTAssertEqual(process.killCount, 1)
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(1_900))
        XCTAssertLessThan(waited, .milliseconds(3_000))
    }

    // MARK: - What a run leaves

    func testLeftoversOfAnInstallThatNeverFinishedAreReported() {
        let harness = InstallerHarness()
        XCTAssertFalse(harness.installer.hasLeftoverFiles)
        harness.fs.directories.insert("/hq/python")
        harness.installer.refresh()
        XCTAssertEqual(harness.installer.installState, .notInstalled)
        XCTAssertTrue(harness.installer.hasLeftoverFiles)
        harness.installFiles()
        harness.installer.refresh()
        XCTAssertNotNil(harness.installer.installState.installation)
        XCTAssertFalse(harness.installer.hasLeftoverFiles, "an install is uninstalled, not left over")

        let noHome = InstallerHarness(environment: ["READREAD_HQ_HOME": "", "HOME": "/Users/test"])
        noHome.fs.directories.insert("/Users/test/Library/Application Support/ReadRead/hq/python")
        noHome.installer.refresh()
        XCTAssertFalse(noHome.installer.hasLeftoverFiles, "no HQ home, nothing of it")
    }

    /// installer-tmp is install-hq.sh's TMPDIR: what pip left there after a cancel goes before the
    /// next run, and the directory goes after each run.
    func testInstallerTmpIsEmptiedBeforeARunAndRemovedAfterIt() throws {
        let root = try makeTemporaryDirectory().path
        let launcher = FakeLauncher()
        let script = root + "/install-hq.sh"
        try Data("#!/bin/bash\n".utf8).write(to: URL(fileURLWithPath: script))
        let installer = HQInstaller(scriptPath: script, environment: ServerEnvironment(
            launcher: launcher, fileSystem: LocalFileSystem(),
            pathContext: TTSServerPaths.Context(bundleResources: nil, environment: ["READREAD_HQ_HOME": root + "/hq"],
                                                homeDirectory: "/Users/test", currentDirectory: root),
            directories: RuntimeDirectories(logDirectory: root + "/logs", cacheDirectory: root + "/cache",
                                            userLexicon: root + "/lexicon.json"),
            now: { 0 }, sleep: { _ in }, makeToken: { "unused" }))
        let temporary = root + "/cache/installer-tmp"
        let stale = temporary + "/pip-unpack-q1w2e3/mlx-0.32.4.whl"
        let fm = FileManager.default
        try fm.createDirectory(atPath: (stale as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("wheel".utf8).write(to: URL(fileURLWithPath: stale))

        installer.start(.install)
        XCTAssertFalse(fm.fileExists(atPath: stale), "what a cancelled pip left goes first")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: temporary, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertEqual(try XCTUnwrap(launcher.last).configuration.environment["TMPDIR"], temporary)
        try Data("tracker".utf8).write(to: URL(fileURLWithPath: temporary + "/pip-build-tracker-x"))

        installer.cancel()
        XCTAssertEqual(installer.state, .cancelled(.install))
        XCTAssertFalse(fm.fileExists(atPath: temporary), "nothing in it outlives the run")
    }

    // MARK: - Failing at once

    func testALaunchFailureFailsAtOnceAndReportsOnTheNextTurn() async {
        let harness = InstallerHarness()
        harness.launcher.launchError = CocoaError(.fileReadNoPermission)
        harness.installer.start(.install)
        guard case .failed(.install, let message) = harness.installer.state else {
            return XCTFail("\(harness.installer.state)")
        }
        XCTAssertTrue(message.hasPrefix("Could not start install-hq.sh: "), message)
        XCTAssertEqual(harness.finishes, [], "never inside start()")
        await waitUntil { harness.finishes.count == 1 }
        XCTAssertEqual(harness.finishes.first?.state, harness.installer.state)
        harness.launcher.launchError = nil
        harness.installer.start(.install)
        XCTAssertTrue(harness.installer.state.isRunning, "a failed start leaves nothing behind")
    }

    func testNoScriptFailsNamingWhereItLooked() async {
        let harness = InstallerHarness(bundleResources: "/A.app/Contents/Resources", scriptPath: nil)
        harness.installer.start(.check)
        XCTAssertEqual(harness.installer.state, .failed(.check, message:
            "No install-hq.sh found (looked for /A.app/Contents/Resources/installer/scripts/install-hq.sh, "
            + "/rr/scripts/install-hq.sh, /work/scripts/install-hq.sh)."))
        XCTAssertTrue(harness.launcher.processes.isEmpty)
        await waitUntil { harness.finishes.count == 1 }
    }

    func testAMissingExplicitScriptFails() {
        let harness = InstallerHarness(scriptPath: "/nowhere/install-hq.sh", scriptExists: false)
        harness.installer.start(.install)
        XCTAssertEqual(harness.installer.state, .failed(.install, message:
            "No install-hq.sh found (looked for /nowhere/install-hq.sh)."))
    }

    func testAnEmptyHQHomeNeverRunsTheScript() async {
        let harness = InstallerHarness(environment: ["READREAD_HQ_HOME": "", "READREAD_HOME": "/rr"])
        let message = "READREAD_HQ_HOME is set but empty: unset it to use the default place, or give it a path."
        XCTAssertEqual(harness.installer.installState, .damaged(message))
        XCTAssertNil(harness.installer.home)
        harness.installer.start(.uninstall)
        XCTAssertEqual(harness.installer.state, .failed(.uninstall, message: message))
        XCTAssertTrue(harness.launcher.processes.isEmpty)
        await waitUntil { harness.finishes.count == 1 }
    }

    // MARK: - Log

    func testTheLogIsRotatedAtFiveMegabytesAndTheChildGetsIt() throws {
        let harness = InstallerHarness()
        harness.fs.addFile("/logs/hq-install.log", size: ServerLog.rotationBytes)
        harness.fs.addFile("/logs/hq-install.log.1", size: 10)
        harness.installer.start(.install)
        XCTAssertEqual(harness.fs.files["/logs/hq-install.log.1"], ServerLog.rotationBytes)
        XCTAssertEqual(harness.fs.opened, ["/logs/hq-install.log"])
        XCTAssertTrue(harness.fs.directories.contains("/logs"))
        XCTAssertEqual(harness.installer.logFileURL.path, "/logs/hq-install.log")
        XCTAssertEqual(harness.launcher.processes.count, 1)
    }

    func testTheLogGetsAHeaderAndAnEndLinePerRun() throws {
        let root = try makeTemporaryDirectory().path
        let launcher = FakeLauncher()
        let script = root + "/install-hq.sh"
        try Data("#!/bin/bash\n".utf8).write(to: URL(fileURLWithPath: script))
        let real = HQInstaller(scriptPath: script, environment: ServerEnvironment(
            launcher: launcher, fileSystem: LocalFileSystem(),
            pathContext: TTSServerPaths.Context(
                bundleResources: nil, environment: ["READREAD_HQ_HOME": root + "/hq", "READREAD_HOME": root + "/rr"],
                homeDirectory: "/Users/test", currentDirectory: root),
            directories: RuntimeDirectories(logDirectory: root + "/logs", cacheDirectory: root + "/cache",
                                            userLexicon: root + "/lexicon.json"),
            now: { 0 }, sleep: { _ in }, makeToken: { "unused" }))
        real.start(.check)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/cache/installer-tmp", isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let process = try XCTUnwrap(launcher.last)
        process.emit("garbage on stdout\n")
        process.emit(#"{"event":"done","models":["1.7b"]}"# + "\n")
        process.exit(code: 0)
        real.start(.install)
        try XCTUnwrap(launcher.last).exit(code: 1)

        let log = try String(contentsOfFile: root + "/logs/hq-install.log", encoding: .utf8)
        let lines = log.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 5, log)
        XCTAssertTrue(lines[0].hasSuffix("[app] === install-hq.sh check: /bin/bash \(script) --check --json-progress "
            + "(READREAD_HQ_HOME=\(root)/hq) ==="), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("[app] unexpected stdout line: garbage on stdout"), lines[1])
        XCTAssertTrue(lines[2].hasSuffix("[app] === install-hq.sh check ended (exit status 0): finished ==="), lines[2])
        XCTAssertTrue(lines[3].hasSuffix("[app] === install-hq.sh install: /bin/bash \(script) --json-progress "
            + "(READREAD_HQ_HOME=\(root)/hq) ==="), lines[3])
        XCTAssertTrue(lines[4].hasSuffix("[app] === install-hq.sh install ended (exit status 1): failed: no done event ==="),
                      lines[4])
    }

    // MARK: - Engine.strings

    /// Every `String(localized: "…", table: "Engine")` key has its line in
    /// zh-Hans.lproj/Engine.strings with the same `%@` count, and the file has no line the sources
    /// no longer use.
    func testEveryEngineMessageHasItsChineseLine() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/ReadRead")
        var keys = Set<String>()
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" {
            keys.formUnion(Self.engineKeys(in: try String(contentsOf: file, encoding: .utf8)))
        }
        XCTAssertGreaterThanOrEqual(keys.count, 14, "the scan found the messages")
        let data = try Data(contentsOf: sources.appending(path: "Resources/zh-Hans.lproj/Engine.strings"))
        XCTAssertNotNil(String(data: data, encoding: .utf8), "UTF-8")
        let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        for key in keys.sorted() {
            guard let value = table[key] else {
                XCTFail("no zh-Hans line in Engine.strings for: \(key)")
                continue
            }
            XCTAssertEqual(value.components(separatedBy: "%@").count, key.components(separatedBy: "%@").count, key)
            XCTAssertNotEqual(value, key, "translated: \(key)")
        }
        XCTAssertEqual(Set(table.keys).subtracting(keys).sorted(), [], "lines no source uses")
    }

    func testTheEngineKeyScannerReadsInterpolationsAsSpecifiers() {
        let source = #"""
        String(localized: "A \(path) b \(f("x)")).", table: "Engine")
        String(localized: "Not this one", table: "Content")
        String(localized: "Nor \(this)")
        String(localized: "Say \"hi\"",
               table: "Engine")
        """#
        XCTAssertEqual(Self.engineKeys(in: source), ["A %@ b %@.", "Say \"hi\""])
    }

    /// The keys of `String(localized: "…", table: "Engine")` in `source`: each `\(…)` becomes `%@`.
    static func engineKeys(in source: String) -> [String] {
        let chars = Array(source)
        let opening = Array("String(localized: \"")
        var keys: [String] = []
        var index = 0
        while index + opening.count <= chars.count {
            guard Array(chars[index..<(index + opening.count)]) == opening else {
                index += 1
                continue
            }
            var cursor = index + opening.count
            var key = ""
            var closed = false
            while cursor < chars.count {
                let character = chars[cursor]
                if character == "\"" {
                    closed = true
                    cursor += 1
                    break
                }
                if character == "\\", cursor + 1 < chars.count {
                    let next = chars[cursor + 1]
                    if next == "(" {
                        key += "%@"
                        var depth = 0
                        var inner = cursor + 1
                        var inString = false
                        while inner < chars.count {
                            let c = chars[inner]
                            if inString {
                                if c == "\\" { inner += 1 } else if c == "\"" { inString = false }
                            } else if c == "\"" {
                                inString = true
                            } else if c == "(" {
                                depth += 1
                            } else if c == ")" {
                                depth -= 1
                                if depth == 0 { break }
                            }
                            inner += 1
                        }
                        cursor = inner + 1
                        continue
                    }
                    key.append(next == "n" ? "\n" : next)
                    cursor += 2
                    continue
                }
                key.append(character)
                cursor += 1
            }
            guard closed else { break }
            let rest = String(chars[cursor..<min(chars.count, cursor + 200)])
            if rest.range(of: #"^\s*,\s*table:\s*"Engine""#, options: .regularExpression) != nil { keys.append(key) }
            index = cursor
        }
        return keys
    }
}
