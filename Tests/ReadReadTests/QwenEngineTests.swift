import Foundation
import XCTest

@testable import ReadRead

/// The high-quality engine and its installer for real, opt in (they need an install and the GPU;
/// run them outside any sandbox). Logs and caches go to a temporary directory, never ~/Library;
/// the server code and install-hq.sh are this checkout's.
///
/// - `READREAD_TEST_QWEN=1` + `READREAD_HQ_HOME=<an install>`: `TTSService.qwen` reads one Chinese
///   and one English sentence through the real server (synth_speed 1.0), then `stop()`: the process
///   is gone.
/// - `READREAD_TEST_HQ_INSTALLER=1` + `READREAD_HQ_HOME=<an install>`: `HQInstaller` runs `.check`
///   against that install (read only), and `.install` into an empty temporary home cancelled at its
///   first download (the network is touched only for that download's first bytes).
/// - `READREAD_TEST_HQ_FULL_INSTALL=1` + `READREAD_HQ_HOME=<an empty or new directory>` (+
///   `READREAD_TEST_HQ_SCRIPT`, another install-hq.sh such as the built bundle's): a complete install
///   (about 3.5 GB of downloads), then one sentence from it.
@MainActor
final class QwenEngineTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let checkoutScript = repository.appending(path: "scripts/install-hq.sh").path

    private var variables: [String: String] { ProcessInfo.processInfo.environment }

    /// Skips unless `flag` is 1; then `$READREAD_HQ_HOME` must be given.
    private func hqHome(_ flag: String) throws -> String {
        try XCTSkipUnless(variables[flag] == "1", "set \(flag)=1 and READREAD_HQ_HOME to run it")
        let home = try XCTUnwrap(variables["READREAD_HQ_HOME"].flatMap { $0.isEmpty ? nil : $0 },
                                 "\(flag) needs READREAD_HQ_HOME")
        return (home as NSString).expandingTildeInPath
    }

    /// The live launcher and file system with `hqHome`, the checkout's server code (an empty
    /// `READREAD_HOME`: never ~/.readread) and logs, cache and lexicon in `scratch`.
    private func environment(hqHome: String, scratch: URL) -> ServerEnvironment {
        var environment = ServerEnvironment.live()
        var context = environment.pathContext
        context.bundleResources = nil
        context.environment["READREAD_HQ_HOME"] = hqHome
        context.environment["READREAD_HOME"] = ""
        context.currentDirectory = Self.repository.path
        environment.pathContext = context
        environment.directories = RuntimeDirectories(
            logDirectory: scratch.appending(path: "logs").path, cacheDirectory: scratch.appending(path: "cache").path,
            userLexicon: scratch.appending(path: "lexicon_zh.json").path)
        return environment
    }

    private func logTail(_ path: String, lines: Int = 25) -> String {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "(no log at \(path))"
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    /// The command lines of running processes that mention `text` (pgrep -fl).
    private func processes(mentioning text: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", text]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private func isGone(_ pid: Int32) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

    // MARK: - The engine

    func testQwenReadsBothLanguagesAtSpeedOneThenStops() async throws {
        let home = try hqHome("READREAD_TEST_QWEN")
        let scratch = try makeTemporaryDirectory()
        let installation = try XCTUnwrap(HQInstallation.read(home: home, fileSystem: LocalFileSystem()).installation,
                                         "no usable install at \(home)")
        let service = TTSService.qwen(installation: installation, environment: environment(hqHome: home, scratch: scratch))
        addTeardownBlock { @MainActor in service.server.stopSynchronously() }
        XCTAssertEqual(service.engineID, QwenModel.engineID)
        XCTAssertFalse(service.honoursSpeed)

        let texts: [SpeechLanguage: String] = [.zh: "你好，欢迎使用高音质朗读。", .en: "Hello from the high-quality voice."]
        for voice in Voice.qwen {
            let text = try XCTUnwrap(texts[voice.language])
            let started = ContinuousClock.now
            do {
                // The requested speed is the player's business: the audio comes at 1.0.
                let result = try await service.synthesize(SynthesisRequest(text: text, voice: voice, speed: 1.3))
                print("qwen \(voice.id): \(result.duration) s of audio in \(ContinuousClock.now - started), "
                    + "synth_speed \(result.synthSpeed), \(result.tokens.count) tokens")
                XCTAssertEqual(result.synthSpeed, 1.0)
                XCTAssertTrue(TTSClient.isWAV(result.wav))
                XCTAssertFalse(result.silent)
                XCTAssertEqual(result.sampleRate, 24_000)
                XCTAssertGreaterThan(result.duration, 1.0)
                XCTAssertLessThan(result.duration, 15.0)
            } catch {
                XCTFail("\(voice.id): \(error.localizedDescription)\n\(logTail(service.server.logPath))")
                throw error
            }
        }
        let endpoint = try XCTUnwrap(service.server.endpoint)
        XCTAssertEqual(endpoint.engine, "qwen")
        XCTAssertEqual(endpoint.model, QwenModel.id)
        XCTAssertEqual(service.server.logPath, scratch.appending(path: "logs/tts-server-qwen.log").path)

        await service.stop()
        XCTAssertEqual(service.server.phase, .stopped)
        XCTAssertFalse(service.server.isProcessRunning)
        XCTAssertEqual(service.server.lastExit?.pid, endpoint.pid)
        XCTAssertTrue(isGone(endpoint.pid), "pid \(endpoint.pid) still exists")
    }

    // MARK: - The installer

    func testTheInstallerChecksTheInstall() async throws {
        let home = try hqHome("READREAD_TEST_HQ_INSTALLER")
        let scratch = try makeTemporaryDirectory()
        let installer = HQInstaller(scriptPath: Self.checkoutScript, environment: environment(hqHome: home, scratch: scratch))
        XCTAssertNotNil(installer.installState.installation, "\(installer.installState)")
        var outcomes: [InstallerState] = []
        installer.onFinish = { _, state in outcomes.append(state) }
        var steps = Set<Int>()
        let started = ContinuousClock.now
        installer.start(.check)
        await waitUntil(timeout: .seconds(900)) {
            if case .running(.check, let progress) = installer.state, progress.stepIndex > 0 { steps.insert(progress.stepIndex) }
            return !outcomes.isEmpty
        }
        print("install-hq.sh --check: \(installer.state) in \(ContinuousClock.now - started), steps seen \(steps.sorted())")
        XCTAssertEqual(outcomes, [.finished(.check)], logTail(installer.logFileURL.path))
        XCTAssertEqual(installer.reportedModels, [QwenModel.id])
        XCTAssertFalse(steps.isEmpty, "progress arrived")
        XCTAssertNotNil(installer.installState.installation)
        let log = try String(contentsOf: installer.logFileURL, encoding: .utf8)
        XCTAssertTrue(log.contains("=== install-hq.sh check: /bin/bash \(Self.checkoutScript) --check --json-progress"), log)
        XCTAssertTrue(log.contains("=== HQ install OK"), "install-hq.sh's stderr is in the log")
    }

    func testAnInstallCancelledAtItsFirstDownloadStopsEverything() async throws {
        _ = try hqHome("READREAD_TEST_HQ_INSTALLER")
        let scratch = try makeTemporaryDirectory()
        let home = scratch.appending(path: "hq").path
        let installer = HQInstaller(scriptPath: Self.checkoutScript, environment: environment(hqHome: home, scratch: scratch))
        XCTAssertEqual(installer.installState, .notInstalled)
        var outcomes: [InstallerState] = []
        installer.onFinish = { _, state in outcomes.append(state) }
        var download: InstallerProgress?
        installer.start(.install)
        await waitUntil(timeout: .seconds(120)) {
            if case .running(.install, let progress) = installer.state, progress.file != nil {
                download = progress
                return true
            }
            return !outcomes.isEmpty
        }
        let first = try XCTUnwrap(download, "no download event: \(installer.state)\n\(logTail(installer.logFileURL.path))")
        print("cancelling at the first download: \(first)")
        XCTAssertEqual(first.stepIndex, 1)
        XCTAssertEqual(first.stepCount, 6)
        XCTAssertGreaterThan(first.bytesTotal, 0)

        installer.cancel()
        await waitUntil(timeout: .seconds(60)) { !outcomes.isEmpty }
        XCTAssertEqual(outcomes, [.cancelled(.install)], logTail(installer.logFileURL.path))
        XCTAssertEqual(installer.installState, .notInstalled)
        XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: home + "/.lock"), "the lock is released")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/install.json"))
        // curl, pip and python name the scratch directory in their arguments (the download's
        // .part, the venv): none may be left.
        var left: [String] = []
        for _ in 0..<50 {
            left = try processes(mentioning: scratch.path)
            if left.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(left, [], "still running")
        let log = try String(contentsOf: installer.logFileURL, encoding: .utf8)
        XCTAssertTrue(log.contains("cancelled: SIGTERM to process group"), log)
        XCTAssertTrue(log.contains("interrupted by a signal"), "install-hq.sh's own message is in the log")
    }

    /// About 3.5 GB of downloads and several minutes: the integrator runs it once.
    func testAFullInstallThenOneSentence() async throws {
        let home = try hqHome("READREAD_TEST_HQ_FULL_INSTALL")
        let script = variables["READREAD_TEST_HQ_SCRIPT"].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? Self.checkoutScript
        let scratch = try makeTemporaryDirectory()
        let environment = environment(hqHome: home, scratch: scratch)
        let installer = HQInstaller(scriptPath: script, environment: environment)
        var outcomes: [InstallerState] = []
        installer.onFinish = { _, state in outcomes.append(state) }
        var steps = Set<Int>()
        var largestDownload: Int64 = 0
        let started = ContinuousClock.now
        installer.start(.install)
        await waitUntil(timeout: .seconds(4 * 3600)) {
            if case .running(.install, let progress) = installer.state {
                if progress.stepIndex > 0 { steps.insert(progress.stepIndex) }
                if progress.file != nil { largestDownload = max(largestDownload, progress.bytesTotal) }
            }
            return !outcomes.isEmpty
        }
        print("install-hq.sh (\(script)): \(installer.state) in \(ContinuousClock.now - started), "
            + "steps seen \(steps.sorted()), largest download \(largestDownload) bytes")
        XCTAssertEqual(outcomes, [.finished(.install)], logTail(installer.logFileURL.path, lines: 60))
        XCTAssertEqual(installer.reportedModels, [QwenModel.id])
        XCTAssertTrue(steps.isSuperset(of: [1, 2, 3]), "progress arrived: \(steps.sorted())")
        XCTAssertGreaterThan(largestDownload, 1_000_000_000, "the model's weights were downloaded")
        let installation = try XCTUnwrap(installer.installState.installation, "\(installer.installState)")
        XCTAssertGreaterThan(installation.modelBytes, 1_000_000_000)
        XCTAssertNotNil(installation.installedAt)

        let service = TTSService.qwen(installation: installation, environment: environment)
        addTeardownBlock { @MainActor in service.server.stopSynchronously() }
        let voice = try XCTUnwrap(Voice.qwen.first { $0.language == .zh })
        let result = try await service.synthesize(SynthesisRequest(text: "安装完成，现在用高音质朗读。", voice: voice, speed: 1.0))
        XCTAssertEqual(result.synthSpeed, 1.0)
        XCTAssertGreaterThan(result.duration, 1.0)
        XCTAssertFalse(result.silent)
        await service.stop()
        XCTAssertFalse(service.server.isProcessRunning)
    }
}
