import Foundation
import Synchronization
import XCTest

@testable import ReadRead

// MARK: - File system

/// In-memory file tree for path resolution and log rotation tests.
@MainActor
final class FakeFileSystem: FileSystem {
    var files: [String: UInt64] = [:]
    var directories: Set<String> = []
    var executables: Set<String> = []
    var tails: [String: Data] = [:]
    var opened: [String] = []

    func fileExists(atPath path: String) -> Bool { files[path] != nil }
    func directoryExists(atPath path: String) -> Bool { directories.contains(path) }
    func isExecutableFile(atPath path: String) -> Bool { files[path] != nil && executables.contains(path) }
    func fileSize(atPath path: String) -> UInt64? { files[path] }
    func createDirectory(atPath path: String) throws { directories.insert(path) }

    func moveItem(atPath source: String, toPath destination: String) throws {
        guard let size = files.removeValue(forKey: source) else { throw CocoaError(.fileNoSuchFile) }
        files[destination] = size
    }

    func removeItem(atPath path: String) throws {
        guard files.removeValue(forKey: path) != nil else { throw CocoaError(.fileNoSuchFile) }
    }

    func openForAppending(atPath path: String) throws -> FileHandle {
        opened.append(path)
        if files[path] == nil { files[path] = 0 }
        return FileHandle.nullDevice
    }

    func readTail(atPath path: String, maxBytes: Int) -> Data? { tails[path] }

    func addFile(_ path: String, size: UInt64 = 1, executable: Bool = false) {
        files[path] = size
        if executable { executables.insert(path) }
    }

    /// A complete layout under `root` the way setup.sh (dev) or build-app.sh
    /// (bundle) creates it.
    func install(at root: String, pythonPath: String) {
        addFile(root + pythonPath, executable: true)
        directories.insert(root + "/tts_server")
        addFile(root + "/tts_server/tts_server.py")
        directories.insert(root + "/models")
        for model in ModelFile.all {
            addFile(root + "/models/" + model.name, size: model.bytes)
        }
    }

    func installDev(at home: String) { install(at: home, pythonPath: "/env/bin/python3") }
    func installBundle(at resources: String) { install(at: resources, pythonPath: "/python/bin/python3") }
}

// MARK: - Processes

@MainActor
final class FakeProcess: ServerProcessHandle {
    let pid: Int32
    let configuration: LaunchConfiguration
    private let onStdout: @MainActor (Data) -> Void
    private let onExit: @MainActor (ProcessExit) -> Void

    private(set) var isRunning = true
    private(set) var terminateCount = 0
    private(set) var killCount = 0
    private(set) var stdinClosed = false
    /// Exit (status 0) as soon as SIGTERM arrives, like the real server.
    var exitsOnTerminate = true

    init(pid: Int32, configuration: LaunchConfiguration,
         onStdout: @escaping @MainActor (Data) -> Void, onExit: @escaping @MainActor (ProcessExit) -> Void) {
        self.pid = pid
        self.configuration = configuration
        self.onStdout = onStdout
        self.onExit = onExit
    }

    var token: String? { configuration.environment["READREAD_TOKEN"] }

    func emit(_ text: String) { onStdout(Data(text.utf8)) }

    func emitReady(port: Int = 50_123, loaded: [String] = ["zh"]) {
        let list = loaded.map { "\"\($0)\"" }.joined(separator: ",")
        emit("READY {\"port\":\(port),\"pid\":\(pid),\"api\":2,\"loaded\":[\(list)]}\n")
    }

    func exit(code: Int32 = 0, signal: Bool = false) {
        guard isRunning else { return }
        isRunning = false
        onExit(ProcessExit(reason: signal ? .signal : .exit, code: code))
    }

    func terminate() {
        terminateCount += 1
        if exitsOnTerminate { exit(code: 0) }
    }

    func kill() {
        killCount += 1
        exit(code: 9, signal: true)
    }

    func closeStdin() { stdinClosed = true }
}

@MainActor
final class FakeLauncher: ProcessLauncher {
    private(set) var processes: [FakeProcess] = []
    /// Runs synchronously inside launch(), e.g. to print READY immediately.
    var script: (FakeProcess) -> Void = { _ in }
    var launchError: (any Error)?
    private var nextPID: Int32 = 1000

    var last: FakeProcess? { processes.last }

    func launch(
        _ configuration: LaunchConfiguration,
        stderr: FileHandle,
        onStdout: @escaping @MainActor (Data) -> Void,
        onExit: @escaping @MainActor (ProcessExit) -> Void
    ) throws -> any ServerProcessHandle {
        if let launchError { throw launchError }
        nextPID += 1
        let process = FakeProcess(pid: nextPID, configuration: configuration, onStdout: onStdout, onExit: onExit)
        processes.append(process)
        script(process)
        return process
    }
}

// MARK: - Time

@MainActor
final class TestClock {
    var time: TimeInterval = 1_000
    func advance(_ seconds: TimeInterval) { time += seconds }
}

/// Injected `sleep`: records every request; per duration it returns at once,
/// suspends until cancelled, or waits until the test releases it.
final class TestSleeper: Sendable {
    enum Mode: Sendable { case immediate, forever, gated }

    private struct State {
        var calls: [Duration] = []
        var modes: [Duration: Mode] = [:]
        var fallback: Mode = .forever
        var gated: [Duration: [CheckedContinuation<Void, Never>]] = [:]
    }

    private let state = Mutex(State())

    var calls: [Duration] { state.withLock { $0.calls } }

    func set(_ mode: Mode, for duration: Duration) { state.withLock { $0.modes[duration] = mode } }
    func setDefault(_ mode: Mode) { state.withLock { $0.fallback = mode } }

    /// How many sleeps of `duration` are waiting for `release`.
    func waiting(for duration: Duration) -> Int { state.withLock { $0.gated[duration]?.count ?? 0 } }

    /// End every gated sleep of `duration` (they then honour cancellation).
    func release(_ duration: Duration) {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            defer { s.gated[duration] = nil }
            return s.gated[duration] ?? []
        }
        for waiter in waiters { waiter.resume() }
    }

    func sleep(_ duration: Duration) async throws {
        let mode = state.withLock { s -> Mode in
            s.calls.append(duration)
            return s.modes[duration] ?? s.fallback
        }
        switch mode {
        case .immediate:
            await Task.yield()
            try Task.checkCancellation()
        case .forever:
            try await Task.sleep(for: .seconds(1_000_000))
        case .gated:
            await withCheckedContinuation { continuation in
                state.withLock { $0.gated[duration, default: []].append(continuation) }
            }
            try Task.checkCancellation()
        }
    }
}

// MARK: - Server harness

@MainActor
final class ServerHarness {
    static let readreadHome = "/rr"

    let fs = FakeFileSystem()
    let launcher = FakeLauncher()
    let clock = TestClock()
    let sleeper = TestSleeper()
    let server: TTSServerProcess

    init(policy: ServerPolicy = ServerPolicy(), installDev: Bool = true) {
        if installDev { fs.installDev(at: Self.readreadHome) }
        fs.tails["/logs/tts-server.log"] = Data("Traceback (most recent call last):\nValueError: boom\n".utf8)
        let clock = self.clock
        let sleeper = self.sleeper
        let environment = ServerEnvironment(
            launcher: launcher,
            fileSystem: fs,
            pathContext: TTSServerPaths.Context(
                bundleResources: nil,
                environment: ["READREAD_HOME": Self.readreadHome, "HOME": "/Users/test", "TMPDIR": "/tmp/test"],
                homeDirectory: "/Users/test",
                currentDirectory: "/work"),
            directories: RuntimeDirectories(logDirectory: "/logs", cacheDirectory: "/cache", userLexicon: "/lexicon.json"),
            now: { clock.time },
            sleep: { try await sleeper.sleep($0) },
            makeToken: { ServerToken.make() }
        )
        server = TTSServerProcess(environment: environment, policy: policy)
    }
}

// MARK: - HTTP

/// Scripted HTTPTransport: records every request and answers from a queue of
/// replies (then `fallback`).
final class FakeTransport: Sendable {
    enum Reply: Sendable {
        case json(status: Int, body: String)
        case failure(URLError.Code)
        /// Suspend until the calling task is cancelled, then fail like URLSession.
        case hang
    }

    private struct State: Sendable {
        var requests: [URLRequest] = []
        var replies: [Reply]
        var fallback: Reply
        var cancellations = 0
    }

    private let state: Mutex<State>

    init(_ replies: [Reply] = [], fallback: Reply = .json(status: 200, body: synthesisJSON())) {
        state = Mutex(State(replies: replies, fallback: fallback))
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }
    var cancellations: Int { state.withLock { $0.cancellations } }

    var transport: HTTPTransport { { [self] request in try await self.send(request) } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let reply = state.withLock { s -> Reply in
            s.requests.append(request)
            return s.replies.isEmpty ? s.fallback : s.replies.removeFirst()
        }
        switch reply {
        case .json(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (Data(body.utf8), response)
        case .failure(let code):
            throw URLError(code)
        case .hang:
            do {
                try await Task.sleep(for: .seconds(1_000))
            } catch {
                state.withLock { $0.cancellations += 1 }
                throw URLError(.cancelled)
            }
            throw URLError(.timedOut)
        }
    }
}

/// A v2 /synthesize JSON body (format "json"); `synthSpeed` adds the `synth_speed` field.
func synthesisJSON(requestID: String = "rr-test", duration: Double = 1.25, silent: Bool = false,
                   synthSpeed: Double? = nil) -> String {
    let speedField = synthSpeed.map { ",\"synth_speed\":\($0)" } ?? ""
    return """
    {"request_id":"\(requestID)","sample_rate":24000,"duration":\(duration),\
    "audio":"\(minimalWAV.base64EncodedString())","silent":\(silent),"voice":"zf_001","lang":"zh","speed":1.0,\
    "sentences":[{"text":"你好。","start":0.0,"end":0.6},{"text":"再见。","start":0.6,"end":1.25}],\
    "tokens":[{"text":"你好","start":0.05,"end":0.5},{"text":"broken"}],\
    "timing_ms":{"frontend":3,"synth":120}\(speedField)}
    """
}

// MARK: - Speech fakes

@MainActor
final class FakeSynthesizer: SpeechSynthesizer {
    var engineID = "kokoro"
    var honoursSpeed = true
    var requests: [SynthesisRequest] = []
    /// Answers a request (after any hold); by default audio whose synthSpeed is the request's
    /// speed (1.0 when `honoursSpeed` is false) and whose duration is `duration(of:)`.
    var handler: ((SynthesisRequest) async throws -> SynthesisResult)?
    /// Seconds of audio a request's text gets by default.
    var duration: (String) -> Double = { _ in 1 }
    /// While true, requests wait (cancellably) until `release()` lets them through.
    var holding = false
    private var releases = 0
    /// Requests waiting for `release()`.
    private(set) var held = 0
    /// Errors to throw, keyed by request number (0 = the first request).
    var failures: [Int: any Error] = [:]
    /// Requests whose task was cancelled while in flight.
    var cancelledCount = 0
    var prewarmed: [SpeechLanguage] = []
    var restartCount = 0
    var restartError: (any Error)?
    /// While true, restart() suspends until `releaseRestart()`, like a real
    /// restart waiting for the old server to exit and the new one to load.
    var holdRestart = false
    private var restartWaiters: [CheckedContinuation<Void, Never>] = []
    var restartsWaiting: Int { restartWaiters.count }
    var playbackActiveHistory: [Bool] = []
    var shutdownCount = 0
    var status: SpeechEngineStatus = .idle
    var logFileURL: URL? = URL(fileURLWithPath: "/logs/tts-server.log")

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisResult {
        let number = requests.count
        requests.append(request)
        do {
            if holding {
                held += 1
                defer { held -= 1 }
                while holding && releases == 0 { try await Task.sleep(for: .milliseconds(1)) }
                if releases > 0 { releases -= 1 }
            }
            if let failure = failures[number] { throw failure }
            if let handler { return try await handler(request) }
            try Task.checkCancellation()
            return FakeSynthesizer.result(
                text: request.text, duration: duration(request.text),
                synthSpeed: honoursSpeed ? request.speed : 1.0, requestID: request.requestID)
        } catch is CancellationError {
            cancelledCount += 1
            throw CancellationError()
        }
    }

    /// Let `count` held requests through (and ones that arrive later, up to `count`).
    func release(_ count: Int = 1) { releases += count }

    /// Suspend every request until it is cancelled.
    func hangUntilCancelled() {
        handler = { _ in
            try await Task.sleep(for: .seconds(1_000))
            return FakeSynthesizer.result()
        }
    }

    func prewarm(for language: SpeechLanguage) { prewarmed.append(language) }

    func restart() async throws {
        restartCount += 1
        if holdRestart {
            await withCheckedContinuation { restartWaiters.append($0) }
        }
        if let restartError { throw restartError }
    }

    func releaseRestart() {
        holdRestart = false
        let waiters = restartWaiters
        restartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func setPlaybackActive(_ active: Bool) { playbackActiveHistory.append(active) }
    func shutdown() { shutdownCount += 1 }

    nonisolated static func result(text: String = "x", duration: Double = 1, synthSpeed: Double = 1,
                                   requestID: String? = nil) -> SynthesisResult {
        SynthesisResult(wav: minimalWAV, duration: duration, sampleRate: 24_000, silent: false,
                        sentences: [TimedSpan(text: text, start: 0, end: duration)], tokens: [], requestID: requestID,
                        synthSpeed: synthSpeed)
    }
}

/// An `AudioOutput` the test drives: `finish()` ends the current item.
@MainActor
final class FakeAudioOutput: AudioOutput {
    var onFinished: ((Int) -> Void)?
    var onFailure: ((any Error) -> Void)?
    var userSpeed: Double = 1.0
    var currentTime: Double = 0
    /// Every item `play` accepted, in order.
    private(set) var played: [AudioItem] = []
    private(set) var current: AudioItem?
    private(set) var isPaused = false
    private(set) var stopCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    var playError: (any Error)?
    var resumeError: (any Error)?

    var playedIDs: [Int] { played.map(\.id) }
    var isPlaying: Bool { current != nil && !isPaused }

    func play(_ item: AudioItem) throws {
        if let playError { throw playError }
        played.append(item)
        current = item
        isPaused = false
        currentTime = 0
    }

    func pause() {
        pauseCount += 1
        if current != nil { isPaused = true }
    }

    func resume() throws {
        if let resumeError { throw resumeError }
        resumeCount += 1
        isPaused = false
    }

    func stop() {
        stopCount += 1
        current = nil
        isPaused = false
    }

    /// The current item (audio and pause) played to its end.
    func finish(file: StaticString = #filePath, line: UInt = #line) {
        guard let item = current else { return XCTFail("nothing is playing", file: file, line: line) }
        current = nil
        onFinished?(item.id)
    }

    /// The output device went away for good.
    func fail(_ error: any Error) {
        current = nil
        onFailure?(error)
    }
}

/// Now Playing updates, kept for the test.
@MainActor
final class FakeNowPlaying: NowPlayingPublishing {
    var onCommand: ((NowPlayingCommand) -> Void)?
    private(set) var updates: [NowPlayingInfo] = []
    private(set) var clearCount = 0

    var last: NowPlayingInfo? { updates.last }

    func update(_ info: NowPlayingInfo) { updates.append(info) }
    func clear() { clearCount += 1 }
}

/// Reading positions in memory.
@MainActor
final class MemoryPositions: ReadingPositionStoring {
    var positions: [String: ReadingPosition] = [:]
    private(set) var saveCount = 0

    func position(for key: String) -> ReadingPosition? { positions[key] }

    func save(_ position: ReadingPosition, for key: String) {
        saveCount += 1
        positions[key] = position
    }

    func removePosition(for key: String) { positions.removeValue(forKey: key) }
}

// MARK: - Helpers

/// A 44-byte header-only PCM16 mono 24 kHz WAV.
let minimalWAV: Data = {
    var data = Data("RIFF".utf8)
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    le32(36)
    data.append(Data("WAVEfmt ".utf8))
    le32(16); le16(1); le16(1); le32(24_000); le32(48_000); le16(2); le16(16)
    data.append(Data("data".utf8))
    le32(0)
    return data
}()

/// Poll (yielding the main actor) until `condition` holds.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            XCTFail("condition not met within \(timeout)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// In-memory preferences (nothing is written to ~/Library/Preferences).
@MainActor
final class MemoryPreferences: PreferencesStore {
    var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
}

// MARK: - Fixtures and files

/// Tests/ReadReadTests/Fixtures, read by path (the test target has no SwiftPM resources).
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    static func url(_ path: String) -> URL { directory.appending(path: path) }
    static func data(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }
    static func text(_ path: String) throws -> String { String(decoding: try data(path), as: UTF8.self) }
}

extension XCTestCase {
    /// A new empty directory under the temporary directory, removed when the test ends.
    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ReadReadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
