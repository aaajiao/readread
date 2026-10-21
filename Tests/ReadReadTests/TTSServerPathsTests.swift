import XCTest

@testable import ReadRead

@MainActor
final class TTSServerPathsTests: XCTestCase {
    private let resources = "/Applications/ReadRead.app/Contents/Resources"

    private func context(bundle: Bool, environment: [String: String] = [:]) -> TTSServerPaths.Context {
        TTSServerPaths.Context(
            bundleResources: bundle ? resources : nil,
            environment: environment,
            homeDirectory: "/Users/test",
            currentDirectory: "/work/readread")
    }

    // MARK: - Order

    func testBundleWinsOverDevEnvironment() throws {
        let fs = FakeFileSystem()
        fs.installBundle(at: resources)
        fs.installDev(at: "/rr")
        let paths = try TTSServerPaths.resolve(context(bundle: true, environment: ["READREAD_HOME": "/rr"]), fileSystem: fs)
        XCTAssertEqual(paths.python, resources + "/python/bin/python3")
        XCTAssertEqual(paths.serverDirectory, resources + "/tts_server")
        XCTAssertEqual(paths.serverScript, resources + "/tts_server/tts_server.py")
        XCTAssertEqual(paths.modelsDirectory, resources + "/models")
        XCTAssertEqual(paths.source, .bundle)
    }

    func testReadreadHomeIsTheDevFallback() throws {
        let fs = FakeFileSystem()
        fs.installDev(at: "/rr")
        let paths = try TTSServerPaths.resolve(context(bundle: true, environment: ["READREAD_HOME": "/rr"]), fileSystem: fs)
        XCTAssertEqual(paths.python, "/rr/env/bin/python3")
        XCTAssertEqual(paths.serverDirectory, "/rr/tts_server")
        XCTAssertEqual(paths.modelsDirectory, "/rr/models")
        XCTAssertEqual(paths.source, .dev)
    }

    func testReadreadHomeDefaultsToDotReadreadInHome() throws {
        let fs = FakeFileSystem()
        fs.installDev(at: "/Users/test/.readread")
        let paths = try TTSServerPaths.resolve(context(bundle: false), fileSystem: fs)
        XCTAssertEqual(paths.python, "/Users/test/.readread/env/bin/python3")
        XCTAssertEqual(paths.modelsDirectory, "/Users/test/.readread/models")
    }

    func testCurrentDirectoryServerIsTheLastFallback() throws {
        let fs = FakeFileSystem()
        fs.installDev(at: "/rr")
        fs.files.removeValue(forKey: "/rr/tts_server/tts_server.py")
        fs.addFile("/work/readread/tts_server/tts_server.py")
        let paths = try TTSServerPaths.resolve(context(bundle: false, environment: ["READREAD_HOME": "/rr"]), fileSystem: fs)
        XCTAssertEqual(paths.serverDirectory, "/work/readread/tts_server")
        XCTAssertEqual(paths.python, "/rr/env/bin/python3")
    }

    func testBundleCandidatesAreIgnoredOutsideAnAppBundle() throws {
        // Under `swift run` resourceURL is .build/debug, which must not count.
        let fs = FakeFileSystem()
        fs.installBundle(at: resources)
        fs.installDev(at: "/rr")
        let paths = try TTSServerPaths.resolve(context(bundle: false, environment: ["READREAD_HOME": "/rr"]), fileSystem: fs)
        XCTAssertEqual(paths.source, .dev)
        XCTAssertEqual(paths.python, "/rr/env/bin/python3")
    }

    // MARK: - Missing resources

    func testNothingInstalledReportsEveryMissingPiece() {
        let fs = FakeFileSystem()
        XCTAssertThrowsError(try TTSServerPaths.resolve(context(bundle: false, environment: ["READREAD_HOME": "/rr"]), fileSystem: fs)) { error in
            guard case .resourcesMissing(let items)? = error as? TTSError else { return XCTFail("\(error)") }
            XCTAssertEqual(items.count, 3)
            XCTAssertTrue(items[0].contains("/rr/env/bin/python3"))
            XCTAssertTrue(items[1].contains("tts_server.py"))
            XCTAssertTrue(items[2].contains("/rr/models"))
            XCTAssertTrue((error as? TTSError)?.isResourcesMissing == true)
        }
    }

    func testNonExecutablePythonCountsAsMissing() {
        let fs = FakeFileSystem()
        fs.installDev(at: "/rr")
        fs.executables.removeAll()
        XCTAssertThrowsError(try TTSServerPaths.resolve(context(bundle: false, environment: ["READREAD_HOME": "/rr"]), fileSystem: fs))
    }

    func testStaleModelFileIsReportedWithItsSize() {
        // build/cache once held the old 177 MB export of kokoro-v1.0.fp16.onnx.
        let fs = FakeFileSystem()
        fs.installDev(at: "/rr")
        fs.files["/rr/models/kokoro-v1.0.fp16.onnx"] = 177_464_787
        XCTAssertThrowsError(try TTSServerPaths.resolve(context(bundle: false, environment: ["READREAD_HOME": "/rr"]), fileSystem: fs)) { error in
            guard case .resourcesMissing(let items)? = error as? TTSError else { return XCTFail("\(error)") }
            XCTAssertEqual(items.count, 1)
            XCTAssertTrue(items[0].contains("kokoro-v1.0.fp16.onnx"))
            XCTAssertTrue(items[0].contains("177464787"))
        }
    }

    func testMissingModelFileIsNamed() {
        let fs = FakeFileSystem()
        fs.installDev(at: "/rr")
        fs.files.removeValue(forKey: "/rr/models/voices-v1.1-zh.bin")
        XCTAssertThrowsError(try TTSServerPaths.resolve(context(bundle: false, environment: ["READREAD_HOME": "/rr"]), fileSystem: fs)) { error in
            XCTAssertTrue((error as? TTSError)?.errorDescription?.contains("voices-v1.1-zh.bin") == true)
        }
    }

    func testEmptyReadreadHomeNeverFallsBackToDotReadread() {
        // READREAD_HOME=$UNSET_VAR: the real ~/.readread must not be used silently.
        let fs = FakeFileSystem()
        fs.installDev(at: "/Users/test/.readread")
        XCTAssertThrowsError(try TTSServerPaths.resolve(context(bundle: false, environment: ["READREAD_HOME": ""]), fileSystem: fs)) { error in
            guard case .resourcesMissing(let items)? = error as? TTSError else { return XCTFail("\(error)") }
            XCTAssertTrue(items[0].contains("READREAD_HOME is set but empty"))
            XCTAssertFalse(items.joined().contains(".readread/env"), "\(items)")
        }
        // The app bundle does not need it.
        fs.installBundle(at: resources)
        let paths = try? TTSServerPaths.resolve(context(bundle: true, environment: ["READREAD_HOME": ""]), fileSystem: fs)
        XCTAssertEqual(paths?.source, .bundle)
    }

    func testLocalFileSystemReportsTheSizeASymlinkPointsAt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadReadTests-fs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("model.bin").path
        let link = directory.appendingPathComponent("link.bin").path
        try Data(count: 4096).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let fs = LocalFileSystem()
        XCTAssertEqual(fs.fileSize(atPath: target), 4096)
        XCTAssertEqual(fs.fileSize(atPath: link), 4096, "a linked model file has its target's size")
        XCTAssertTrue(fs.fileExists(atPath: link))
        XCTAssertNil(fs.fileSize(atPath: directory.appendingPathComponent("missing").path))
    }

    /// The app's size check, the downloads (RR_MODELS in scripts/lib/versions.sh, with the sha256)
    /// and the server's own check (MODEL_SIZES in engine_kokoro.py) name the same four files at the
    /// same sizes: a model bump that misses one of them fails here, not on a user's Mac.
    func testModelFilesAgreeWithTheDownloadPinsAndTheServer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = ModelFile.all.map { "\($0.name) \($0.bytes)" }

        let versions = try String(contentsOf: root.appending(path: "scripts/lib/versions.sh"), encoding: .utf8)
        let block = try XCTUnwrap(versions.range(of: #"RR_MODELS="[^"]*""#, options: .regularExpression))
        let pinned = versions[block].split(separator: "\n").dropFirst().dropLast().map { line in
            line.split(separator: " ").prefix(2).joined(separator: " ")
        }
        XCTAssertEqual(pinned, app, "scripts/lib/versions.sh RR_MODELS")

        let engine = try String(contentsOf: root.appending(path: "tts_server/readread_tts/engine_kokoro.py"), encoding: .utf8)
        let table = try XCTUnwrap(engine.range(of: #"MODEL_SIZES = \{[^}]*\}"#, options: .regularExpression))
        let server = engine[table].matches(of: /"([^"]+)": (\d+)/).map { "\($0.1) \($0.2)" }
        XCTAssertEqual(server, app, "tts_server/readread_tts/engine_kokoro.py MODEL_SIZES")
    }

    // MARK: - Runtime directories

    func testRuntimeDirectoriesDefaultToLibrary() {
        let dirs = RuntimeDirectories(environment: [:], homeDirectory: "/Users/test")
        XCTAssertEqual(dirs.logFile, "/Users/test/Library/Logs/ReadRead/tts-server.log")
        XCTAssertEqual(dirs.cacheDirectory, "/Users/test/Library/Caches/ReadRead")
        XCTAssertEqual(dirs.userLexicon, "/Users/test/Library/Application Support/ReadRead/lexicon_zh.json")
    }

    func testRuntimeDirectoriesHonourOverrides() {
        let dirs = RuntimeDirectories(
            environment: ["READREAD_LOG_DIR": "/s/logs", "READREAD_CACHE_DIR": "/s/cache", "READREAD_USER_LEXICON": "/s/lex.json"],
            homeDirectory: "/Users/test")
        XCTAssertEqual(dirs.logFile, "/s/logs/tts-server.log")
        XCTAssertEqual(dirs.cacheDirectory, "/s/cache")
        XCTAssertEqual(dirs.userLexicon, "/s/lex.json")
    }

    func testTheHighQualityEngineHasItsOwnLogsAndInstallerDirectories() {
        let dirs = RuntimeDirectories(logDirectory: "/s/logs", cacheDirectory: "/s/cache", userLexicon: "/s/lex.json")
        XCTAssertEqual(dirs.qwenLogFile, "/s/logs/tts-server-qwen.log")
        XCTAssertEqual(dirs.installerLogFile, "/s/logs/hq-install.log")
        XCTAssertEqual(dirs.installerTemporaryDirectory, "/s/cache/installer-tmp")
        XCTAssertEqual(dirs.installerBuildCache, "/s/cache/hq-build")
        XCTAssertNotEqual(dirs.qwenLogFile, dirs.logFile)
    }

    // MARK: - Qwen

    private let hqHome = "/hq"
    private var installation: HQInstallation { HQInstallation(home: hqHome, installedAt: nil, modelBytes: 1) }

    /// The HQ venv's python and the model's folder under `<hq>/models`.
    private func installHQ(_ fs: FakeFileSystem, python: Bool = true, folder: Bool = true) {
        if python { fs.addFile(hqHome + "/venv/bin/python3", executable: true) }
        fs.directories.insert(hqHome + "/models")
        if folder { fs.directories.insert(hqHome + "/models/" + QwenModel.folder) }
    }

    func testQwenRunsTheHQVenvWithTheAppsOwnServerCode() throws {
        let fs = FakeFileSystem()
        installHQ(fs)
        fs.installDev(at: "/rr")
        let paths = try TTSServerPaths.resolveQwen(
            context(bundle: false, environment: ["READREAD_HOME": "/rr"]), installation: installation, fileSystem: fs)
        XCTAssertEqual(paths.python, "/hq/venv/bin/python3")
        XCTAssertEqual(paths.serverDirectory, "/rr/tts_server")
        XCTAssertEqual(paths.modelsDirectory, "/hq/models")
        XCTAssertEqual(paths.source, .dev)
    }

    func testQwenPrefersTheBundlesServerCode() throws {
        let fs = FakeFileSystem()
        installHQ(fs)
        fs.installBundle(at: resources)
        fs.installDev(at: "/rr")
        let paths = try TTSServerPaths.resolveQwen(
            context(bundle: true, environment: ["READREAD_HOME": "/rr"]), installation: installation, fileSystem: fs)
        XCTAssertEqual(paths.serverDirectory, resources + "/tts_server")
        XCTAssertEqual(paths.python, "/hq/venv/bin/python3", "never the bundle's own python")
        XCTAssertEqual(paths.source, .bundle)
    }

    func testQwenNeedsNoKokoroModelsOrDevPython() throws {
        let fs = FakeFileSystem()
        installHQ(fs)
        fs.addFile("/work/readread/tts_server/tts_server.py")
        let paths = try TTSServerPaths.resolveQwen(
            context(bundle: false, environment: ["READREAD_HOME": "/rr"]), installation: installation, fileSystem: fs)
        XCTAssertEqual(paths.serverDirectory, "/work/readread/tts_server")
    }

    func testABrokenHQInstallIsHQUnavailableNamingEveryProblem() {
        let fs = FakeFileSystem()
        installHQ(fs, python: false, folder: false)
        fs.addFile("/hq/venv/bin/python3", executable: false)
        fs.installDev(at: "/rr")
        XCTAssertThrowsError(try TTSServerPaths.resolveQwen(
            context(bundle: false, environment: ["READREAD_HOME": "/rr"]), installation: installation, fileSystem: fs)
        ) { error in
            guard case .hqUnavailable(let detail) = error as? TTSError else { return XCTFail("\(error)") }
            XCTAssertEqual(detail, "its Python /hq/venv/bin/python3 is missing or not executable; "
                + "its model folder /hq/models/\(QwenModel.folder) is missing")
            XCTAssertFalse(TTSError.hqUnavailable(detail).isResourcesMissing, "Kokoro's setup hint is not for this")
            XCTAssertTrue(TTSError.hqUnavailable(detail).isServerFailure)
        }
    }

    func testQwenWithoutServerCodeIsALaunchFailure() {
        let fs = FakeFileSystem()
        installHQ(fs)
        XCTAssertThrowsError(try TTSServerPaths.resolveQwen(
            context(bundle: true, environment: ["READREAD_HOME": "/rr"]), installation: installation, fileSystem: fs)
        ) { error in
            guard case .launchFailed(let detail) = error as? TTSError else { return XCTFail("\(error)") }
            XCTAssertEqual(detail, "TTS server code not found (looked for tts_server.py in "
                + "\(resources)/tts_server, /rr/tts_server, /work/readread/tts_server)")
        }
    }

    func testServerDirectoryFollowsTheKokoroOrder() {
        let fs = FakeFileSystem()
        let ctx = context(bundle: true, environment: ["READREAD_HOME": "/rr"])
        XCTAssertEqual(TTSServerPaths.serverCandidates(ctx),
                       [resources + "/tts_server", "/rr/tts_server", "/work/readread/tts_server"])
        XCTAssertNil(TTSServerPaths.serverDirectory(ctx, fileSystem: fs))
        fs.addFile("/work/readread/tts_server/tts_server.py")
        XCTAssertEqual(TTSServerPaths.serverDirectory(ctx, fileSystem: fs), "/work/readread/tts_server")
        fs.addFile("/rr/tts_server/tts_server.py")
        XCTAssertEqual(TTSServerPaths.serverDirectory(ctx, fileSystem: fs), "/rr/tts_server")
        fs.addFile(resources + "/tts_server/tts_server.py")
        XCTAssertEqual(TTSServerPaths.serverDirectory(ctx, fileSystem: fs), resources + "/tts_server")
        // An empty READREAD_HOME never means ~/.readread.
        XCTAssertEqual(TTSServerPaths.serverCandidates(context(bundle: false, environment: ["READREAD_HOME": ""])),
                       ["/work/readread/tts_server"])
    }

    // MARK: - LocalFileSystem reads

    func testLocalFileSystemReadsWholeSmallRegularFilesOnly() throws {
        let directory = try makeTemporaryDirectory()
        let fs = LocalFileSystem()
        let small = directory.appending(path: "small.json").path
        try Data("{\"a\":1}".utf8).write(to: URL(fileURLWithPath: small))
        XCTAssertEqual(fs.contents(atPath: small, maxBytes: 7), Data("{\"a\":1}".utf8))
        XCTAssertNil(fs.contents(atPath: small, maxBytes: 6), "one byte over the limit")
        XCTAssertNil(fs.contents(atPath: directory.appending(path: "missing").path, maxBytes: 100))
        XCTAssertNil(fs.contents(atPath: directory.path, maxBytes: 100), "a directory is not read")

        let fifo = directory.appending(path: "fifo").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        XCTAssertNil(fs.contents(atPath: fifo, maxBytes: 100), "a FIFO neither blocks nor counts as a file")

        let link = directory.appending(path: "link.json").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: small)
        XCTAssertEqual(fs.contents(atPath: link, maxBytes: 100), Data("{\"a\":1}".utf8))
        XCTAssertEqual(fs.resolvingSymlinks(atPath: link), fs.resolvingSymlinks(atPath: small))
        XCTAssertTrue(fs.resolvingSymlinks(atPath: link).hasSuffix("/small.json"))
        let missing = directory.appending(path: "nowhere/at/all").path
        XCTAssertEqual(fs.resolvingSymlinks(atPath: missing), missing)
    }
}
