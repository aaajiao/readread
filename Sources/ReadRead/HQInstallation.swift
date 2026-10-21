import CoreFoundation
import Foundation

/// The high-quality install's home and its install.json, as install-hq.sh writes them (format in
/// tts_server/README.md: `{"version":1,"python","lock_sha256","models":{"1.7b":{"repo",
/// "revision","dir","files","bytes"}},"installed_at"}`, written last, once the install's smoke test
/// passed). Reading never runs a process and reads at most `maxManifestBytes` of the file.
extension HQInstallation {
    static let manifestName = "install.json"
    /// Where install-hq.sh moves install.json before an install or repair first changes python/,
    /// venv/ or a model file (it writes install.json again last, then removes this): a run that
    /// stopped after that leaves it.
    static let unfinishedManifestName = "install.json.prev"
    /// What install-hq.sh writes into python/ once it is extracted and into venv/ once pip installed
    /// the whole lock and the venv matched it: a venv being rebuilt has no stamp yet.
    static let completionStamps = ["python/.readread-python", "venv/.readread-hq-venv"]
    static let maxManifestBytes = 1 << 20

    /// `$READREAD_HQ_HOME` (a leading `~` expanded), else `~/Library/Application Support/ReadRead/hq`;
    /// nil when the variable is set but empty, which never means the default (as in install-hq.sh).
    static func home(environment: [String: String], homeDirectory: String) -> String? {
        guard let value = environment["READREAD_HQ_HOME"] else {
            return (homeDirectory as NSString).appendingPathComponent("Library/Application Support/ReadRead/hq")
        }
        guard !value.isEmpty else { return nil }
        var path = value
        if path == "~" {
            path = homeDirectory
        } else if path.hasPrefix("~/") {
            path = (homeDirectory as NSString).appendingPathComponent(String(path.dropFirst(2)))
        } else if path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath  // ~user
        }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The install at `home`: `.notInstalled` without install.json, but `.damaged` when
    /// install.json.prev says an install or repair began and did not finish; `.damaged` when the file
    /// is unreadable, larger than 1 MB, not JSON, of another version, without the "1.7b" model, or
    /// when `models/<QwenModel.folder>/`, an executable `venv/bin/python3` or a `completionStamps`
    /// file is missing. Other model keys (an older install-hq.sh could add a second model) are
    /// ignored.
    @MainActor
    static func read(home: String, fileSystem: any FileSystem) -> HQInstallState {
        let path = (home as NSString).appendingPathComponent(manifestName)
        guard fileSystem.fileExists(atPath: path) else {
            // What it was replacing (the venv, Python, a model file) may be half done.
            let unfinished = (home as NSString).appendingPathComponent(unfinishedManifestName)
            return fileSystem.fileExists(atPath: unfinished)
                ? .damaged(String(localized: "The last install or repair has not finished.", table: "Engine"))
                : .notInstalled
        }
        guard let data = fileSystem.contents(atPath: path, maxBytes: maxManifestBytes) else {
            if let size = fileSystem.fileSize(atPath: path), size > UInt64(maxManifestBytes) {
                return .damaged(String(localized: "\(path) is larger than 1 MB.", table: "Engine"))
            }
            return .damaged(String(localized: "\(path) cannot be read.", table: "Engine"))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .damaged(String(localized: "\(path) is not a JSON object.", table: "Engine"))
        }
        guard let version = number(object["version"]), version.doubleValue == 1 else {
            return .damaged(String(localized: "\(path) has another format version (this ReadRead reads version 1).",
                                   table: "Engine"))
        }
        guard let models = object["models"] as? [String: Any], let model = models[QwenModel.id] as? [String: Any] else {
            return .damaged(String(localized: "\(path) does not list the \(QwenModel.id) model.", table: "Engine"))
        }
        let installation = HQInstallation(
            home: home,
            installedAt: (object["installed_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            modelBytes: number(model["bytes"]).map { max(0, $0.int64Value) } ?? 0)
        let folder = (installation.modelsDirectory as NSString).appendingPathComponent(QwenModel.folder)
        guard fileSystem.directoryExists(atPath: folder) else {
            return .damaged(String(localized: "The model folder \(folder) is missing.", table: "Engine"))
        }
        guard fileSystem.isExecutableFile(atPath: installation.venvPython) else {
            return .damaged(String(localized: "\(installation.venvPython) is missing or not executable.",
                                   table: "Engine"))
        }
        // An older install-hq.sh (one that leaves install.json in place) may be rebuilding them.
        let base = home as NSString
        for stamp in completionStamps where !fileSystem.fileExists(atPath: base.appendingPathComponent(stamp)) {
            let directory = base.appendingPathComponent((stamp as NSString).deletingLastPathComponent)
            return .damaged(String(localized: "\(directory) is incomplete (an install or repair did not finish).",
                                   table: "Engine"))
        }
        return .installed(installation)
    }

    /// What an install that never finished (no install.json) left in `home`: Python, the packages or
    /// model files, which uninstalling removes (Settings: Remove Downloaded Files…).
    @MainActor
    static func hasLeftovers(home: String, fileSystem: any FileSystem) -> Bool {
        ["python", "python.partial", "venv", "models/" + QwenModel.folder].contains {
            fileSystem.directoryExists(atPath: (home as NSString).appendingPathComponent($0))
        }
    }

    /// The install at `home(environment:homeDirectory:)`; `.damaged` when `$READREAD_HQ_HOME` is set
    /// but empty.
    @MainActor
    static func state(environment: [String: String], homeDirectory: String, fileSystem: any FileSystem) -> HQInstallState {
        guard let home = home(environment: environment, homeDirectory: homeDirectory) else {
            return .damaged(emptyHomeMessage)
        }
        return read(home: home, fileSystem: fileSystem)
    }

    /// Why there is no HQ home: `$READREAD_HQ_HOME` is set but empty.
    static var emptyHomeMessage: String {
        String(localized: "READREAD_HQ_HOME is set but empty: unset it to use the default place, or give it a path.",
               table: "Engine")
    }

    /// A JSON number (never a JSON `true` or `false`, which Foundation also bridges to NSNumber).
    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }
}

extension HQInstallState {
    /// `$READREAD_HQ_HOME` is set but empty: there is no install to repair or remove.
    var hasNoHome: Bool { self == .damaged(HQInstallation.emptyHomeMessage) }
}
