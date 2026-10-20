import XCTest

@testable import ReadRead

@MainActor
final class ServerLogTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadReadTests-log-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var logPath: String { directory.appendingPathComponent("tts-server.log").path }

    private func makeFile(_ path: String, bytes: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handle = try LocalFileSystem().openForAppending(atPath: path)
        try handle.truncate(atOffset: UInt64(bytes))  // sparse: no real disk use
        try handle.close()
    }

    // MARK: - Rotation

    func testSmallLogIsNotRotated() throws {
        try makeFile(logPath, bytes: 1024)
        let log = ServerLog(path: logPath, fileSystem: LocalFileSystem())
        let handle = try log.prepareForLaunch()
        try handle.close()
        XCTAssertEqual(LocalFileSystem().fileSize(atPath: logPath), 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logPath + ".1"))
    }

    func testLogAtFiveMegabytesIsRotatedReplacingTheOldBackup() throws {
        try makeFile(logPath, bytes: Int(ServerLog.rotationBytes))
        try makeFile(logPath + ".1", bytes: 10)
        let log = ServerLog(path: logPath, fileSystem: LocalFileSystem())
        let handle = try log.prepareForLaunch()
        ServerLog.note("fresh", to: handle)
        try handle.close()

        XCTAssertEqual(LocalFileSystem().fileSize(atPath: logPath + ".1"), ServerLog.rotationBytes)
        let fresh = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(fresh.hasSuffix("[app] fresh\n"), fresh)
    }

    func testPrepareCreatesTheDirectory() throws {
        let log = ServerLog(path: logPath, fileSystem: LocalFileSystem())
        let handle = try log.prepareForLaunch()
        try handle.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath))
    }

    func testRotationWithFakeFileSystem() {
        let fs = FakeFileSystem()
        fs.addFile("/l/tts-server.log", size: ServerLog.rotationBytes + 1)
        fs.addFile("/l/tts-server.log.1", size: 3)
        ServerLog(path: "/l/tts-server.log", fileSystem: fs).rotateIfNeeded()
        XCTAssertEqual(fs.files["/l/tts-server.log.1"], ServerLog.rotationBytes + 1)
        XCTAssertNil(fs.files["/l/tts-server.log"])
    }

    // MARK: - Appending and tail

    func testAppendsAcrossLaunches() throws {
        let log = ServerLog(path: logPath, fileSystem: LocalFileSystem())
        for n in 1...2 {
            let handle = try log.prepareForLaunch()
            ServerLog.note("launch \(n)", to: handle)
            try handle.close()
        }
        let text = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(text.contains("launch 1") && text.contains("launch 2"))
    }

    func testTailReturnsLastNonEmptyLines() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "one\n\ntwo\n  three  \nfour\n".write(toFile: logPath, atomically: true, encoding: .utf8)
        let tail = ServerLog(path: logPath, fileSystem: LocalFileSystem()).tail(lines: 3)
        XCTAssertEqual(tail, ["two", "three", "four"])
    }

    func testTailOfMissingFileIsEmpty() {
        XCTAssertEqual(ServerLog(path: logPath, fileSystem: LocalFileSystem()).tail(lines: 3), [])
    }
}
