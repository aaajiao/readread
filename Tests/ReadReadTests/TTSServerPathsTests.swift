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
}
