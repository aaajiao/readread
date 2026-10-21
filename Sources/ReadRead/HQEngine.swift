import Foundation

// Shared by the engine track (E) and the app track (U) of milestone v0.5.0: the optional
// high-quality engine (Qwen3-TTS through MLX, installed by install-hq.sh outside the app bundle).

/// The speech engines ReadRead reads with. The system voice is the fallback when an engine cannot
/// run, not a choice in Settings.
enum EngineKind: String, CaseIterable, Sendable {
    /// Kokoro, bundled with the app (the default).
    case kokoro
    /// Qwen3-TTS from the high-quality install.
    case qwen

    static let defaultsKey = "engine"
}

/// The one Qwen3-TTS model ReadRead uses: the best one (the owner wants no smaller option).
enum QwenModel {
    /// Its name for install-hq.sh's and the server's `--model`, and its key in install.json.
    static let id = "1.7b"
    /// Its folder under `<hq>/models` (also the name of its Hugging Face repository).
    static let folder = "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
    /// `SpeechSynthesizer.engineID` of the Qwen server (part of the synthesis cache key).
    static let engineID = "qwen-1.7b"
}

extension Voice {
    /// Qwen3-TTS's voices, one per language: what the server's `GET /voices` lists with
    /// `--engine qwen`. Serena reads Chinese (and the English words in it), Aiden reads English.
    static let qwen: [Voice] = [
        Voice(id: "serena", name: "Serena", language: .zh, accent: .zh),
        Voice(id: "aiden", name: "Aiden", language: .en, accent: .us),
    ]

    /// The voices of `engine`, in picker order.
    static func catalog(for engine: EngineKind) -> [Voice] {
        switch engine {
        case .kokoro: all
        case .qwen: qwen
        }
    }
}

/// What `<hq>/install.json` records once an install finished, smoke test included (install-hq.sh
/// writes the file last). Read without running anything.
struct HQInstallation: Equatable, Sendable {
    /// `$READREAD_HQ_HOME`, else `~/Library/Application Support/ReadRead/hq`.
    let home: String
    /// `installed_at`, when it parses.
    let installedAt: Date?
    /// The bytes of the model's files (`models["1.7b"].bytes`), for Settings.
    let modelBytes: Int64

    var venvPython: String { (home as NSString).appendingPathComponent("venv/bin/python3") }
    var modelsDirectory: String { (home as NSString).appendingPathComponent("models") }
}

/// The high-quality install as the app sees it.
enum HQInstallState: Equatable, Sendable {
    /// No install.json: nothing installed, or a first install that never finished.
    case notInstalled
    case installed(HQInstallation)
    /// install.json exists but cannot be used (unreadable, another version, the model not listed or
    /// its folder missing, venv/bin/python3 or the stamp of a complete python/ or venv/ missing), an
    /// install or repair over it did not finish (install.json.prev), or `$READREAD_HQ_HOME` is set
    /// but empty. The message says which; installing again repairs an install.
    case damaged(String)

    var installation: HQInstallation? {
        if case .installed(let installation) = self { return installation }
        return nil
    }
}

/// What the installer is asked to do: install-hq.sh's three modes.
enum InstallerOperation: Equatable, Sendable {
    /// Install, update or repair (install-hq.sh with no mode argument).
    case install
    /// Verify without changing anything (`--check`).
    case check
    /// Remove the whole install (`--uninstall`).
    case uninstall
}

/// One line of `install-hq.sh --json-progress` on its stdout.
enum InstallerEvent: Equatable, Sendable {
    /// `{"event":"step","name":…,"index":N,"count":N}`, index 1-based.
    case step(name: String, index: Int, count: Int)
    /// `{"event":"download","file":…,"done":N,"total":N}`, bytes of one file.
    case download(file: String, done: Int64, total: Int64)
    /// `{"event":"done",…}`: `models` for install and check, `removed` for uninstall.
    case done(models: [String], removed: Bool?)
    /// `{"event":"error","message":…}`: the run failed (or was stopped by a signal).
    case error(message: String)
}

/// Where a running operation is, for the Settings UI.
struct InstallerProgress: Equatable, Sendable {
    var stepName: String = ""
    /// 1-based; 0 before the first step event.
    var stepIndex: Int = 0
    var stepCount: Int = 0
    /// The file being downloaded, while one is.
    var file: String?
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
}

/// The installer's state. A new operation replaces a finished, failed or cancelled one.
enum InstallerState: Equatable, Sendable {
    case idle
    case running(InstallerOperation, InstallerProgress)
    case finished(InstallerOperation)
    case failed(InstallerOperation, message: String)
    case cancelled(InstallerOperation)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Runs install-hq.sh (the app bundle's copy, else the checkout's) as a child process and reports
/// its progress. The live implementation is `@Observable`, so SwiftUI follows `state` and
/// `installState` through this protocol.
@MainActor
protocol HQInstalling: AnyObject {
    var state: InstallerState { get }
    /// install.json, re-read by `refresh()` and after every operation.
    var installState: HQInstallState { get }
    /// Nothing is installed (`.notInstalled`), but an install that never finished left Python, the
    /// packages or model files in the HQ home; uninstalling removes them. Re-read with `installState`.
    var hasLeftoverFiles: Bool { get }
    /// Re-read install.json (cheap: no process).
    func refresh()
    /// Start an operation; ignored while one runs. The caller stops a running Qwen server first
    /// (an install may rebuild the venv the server runs from; uninstall removes it).
    func start(_ operation: InstallerOperation)
    /// SIGTERM the running operation (its process group: what install-hq.sh runs in the foreground
    /// too): it stops at once, downloads and pip included; installing again resumes. The state
    /// becomes `.cancelled`; an uninstall whose removal has begun finishes.
    func cancel()
    /// App termination: stop a running operation, waiting at most 2 s (then SIGKILL to its group).
    func shutdown()
    /// The installer's log: the stderr of every run, appended.
    var logFileURL: URL { get }
    /// Called when an operation ends (any outcome), after `installState` was refreshed.
    var onFinish: (@MainActor (InstallerOperation, InstallerState) -> Void)? { get set }
}

/// Makes the Qwen engine for an installation: a `TTSService` on its own server lifecycle (the HQ
/// venv's python, `--engine qwen`, a 5-minute idle exit, its own log).
typealias QwenEngineFactory = @MainActor (HQInstallation) -> any SpeechSynthesizer
