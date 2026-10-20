import Foundation

/// A model file the server needs, with the size of the verified download, so a
/// stale or truncated file is reported as missing instead of failing later.
struct ModelFile: Equatable, Sendable {
    let name: String
    let bytes: UInt64

    static let all: [ModelFile] = [
        ModelFile(name: "kokoro-v1.1-zh.fp16.onnx", bytes: 163_528_759),
        ModelFile(name: "voices-v1.1-zh.bin", bytes: 53_815_880),
        ModelFile(name: "kokoro-v1.0.fp16.onnx", bytes: 163_527_961),
        ModelFile(name: "voices-v1.0.bin", bytes: 28_214_398),
    ]
}

/// Where the server's pieces live. Resolution order per piece: the app bundle's
/// Resources, then the dev environment `$READREAD_HOME` (default `~/.readread`),
/// and for the server code also `<cwd>/tts_server`.
struct TTSServerPaths: Equatable, Sendable {
    enum Source: String, Sendable { case bundle, dev }

    let python: String
    let serverDirectory: String
    let modelsDirectory: String
    let source: Source

    var serverScript: String { (serverDirectory as NSString).appendingPathComponent("tts_server.py") }

    /// Inputs for resolution, so tests can describe any layout.
    struct Context: Sendable {
        /// `Contents/Resources` when running from a .app bundle, else nil.
        var bundleResources: String?
        var environment: [String: String]
        var homeDirectory: String
        var currentDirectory: String

        static func live() -> Context {
            let bundle = Bundle.main
            let resources = bundle.bundleURL.pathExtension == "app"
                ? bundle.resourceURL?.path(percentEncoded: false)
                : nil
            return Context(
                bundleResources: resources,
                environment: ProcessInfo.processInfo.environment,
                homeDirectory: NSHomeDirectory(),
                currentDirectory: FileManager.default.currentDirectoryPath
            )
        }

        /// `$READREAD_HOME`, defaulting to `~/.readread`; nil when it is set but
        /// empty (READREAD_HOME=$UNSET_VAR), which must never mean the real ~/.readread.
        var readreadHome: String? {
            guard let home = environment["READREAD_HOME"] else {
                return (homeDirectory as NSString).appendingPathComponent(".readread")
            }
            return home.isEmpty ? nil : (home as NSString).expandingTildeInPath
        }
    }

    @MainActor
    static func resolve(_ context: Context, fileSystem fs: any FileSystem) throws(TTSError) -> TTSServerPaths {
        let home = context.readreadHome
        func join(_ base: String, _ parts: String...) -> String {
            parts.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
        }

        var pythonCandidates: [String] = []
        var serverCandidates: [String] = []
        var modelCandidates: [String] = []
        if let resources = context.bundleResources {
            pythonCandidates.append(join(resources, "python", "bin", "python3"))
            serverCandidates.append(join(resources, "tts_server"))
            modelCandidates.append(join(resources, "models"))
        }
        if let home {
            pythonCandidates.append(join(home, "env", "bin", "python3"))
            serverCandidates.append(join(home, "tts_server"))
        }
        serverCandidates.append(join(context.currentDirectory, "tts_server"))
        if let home { modelCandidates.append(join(home, "models")) }

        var missing: [String] = []
        if home == nil { missing.append("dev environment (READREAD_HOME is set but empty; unset it for ~/.readread)") }

        let python = pythonCandidates.first { fs.isExecutableFile(atPath: $0) }
        if python == nil {
            missing.append("Python runtime (looked for \(pythonCandidates.joined(separator: ", ")))")
        }

        let server = serverCandidates.first { fs.fileExists(atPath: join($0, "tts_server.py")) }
        if server == nil {
            missing.append("TTS server code (looked for tts_server.py in \(serverCandidates.joined(separator: ", ")))")
        }

        func problems(in dir: String) -> [String] {
            ModelFile.all.compactMap { model in
                let path = join(dir, model.name)
                guard let size = fs.fileSize(atPath: path), fs.fileExists(atPath: path) else {
                    return "model \(model.name) not found in \(dir)"
                }
                guard size == model.bytes else {
                    return "model \(model.name) in \(dir) has \(size) bytes, expected \(model.bytes) (stale or incomplete download)"
                }
                return nil
            }
        }
        let models = modelCandidates.first { fs.directoryExists(atPath: $0) && problems(in: $0).isEmpty }
        if models == nil {
            if let existing = modelCandidates.first(where: { fs.directoryExists(atPath: $0) }) {
                missing.append(contentsOf: problems(in: existing))
            } else {
                missing.append("model directory (looked in \(modelCandidates.joined(separator: ", ")))")
            }
        }

        guard let python, let server, let models else { throw .resourcesMissing(missing) }
        let source: Source = context.bundleResources.map { python.hasPrefix($0) } == true ? .bundle : .dev
        return TTSServerPaths(python: python, serverDirectory: server, modelsDirectory: models, source: source)
    }
}

/// Per-user runtime locations, overridable by environment variables so tests and
/// smoke runs never touch the real ones.
struct RuntimeDirectories: Equatable, Sendable {
    let logDirectory: String
    let cacheDirectory: String
    let userLexicon: String

    var logFile: String { (logDirectory as NSString).appendingPathComponent("tts-server.log") }

    init(logDirectory: String, cacheDirectory: String, userLexicon: String) {
        self.logDirectory = logDirectory
        self.cacheDirectory = cacheDirectory
        self.userLexicon = userLexicon
    }

    init(environment: [String: String], homeDirectory: String) {
        func value(_ key: String) -> String? {
            guard let v = environment[key], !v.isEmpty else { return nil }
            return (v as NSString).expandingTildeInPath
        }
        let library = (homeDirectory as NSString).appendingPathComponent("Library")
        logDirectory = value("READREAD_LOG_DIR")
            ?? (library as NSString).appendingPathComponent("Logs/ReadRead")
        cacheDirectory = value("READREAD_CACHE_DIR")
            ?? (library as NSString).appendingPathComponent("Caches/ReadRead")
        userLexicon = value("READREAD_USER_LEXICON")
            ?? (library as NSString).appendingPathComponent("Application Support/ReadRead/lexicon_zh.json")
    }
}
