import Foundation
import XCTest

@testable import ReadRead

/// The high-quality install's home and its install.json (`HQInstallation.home`, `read`, `state`).
@MainActor
final class HQInstallationTests: XCTestCase {
    private let home = "/hq"
    private var manifest: String { home + "/install.json" }
    private var folder: String { home + "/models/" + QwenModel.folder }

    /// What install-hq.sh writes, with `models` replaced when given.
    private func manifestJSON(version: String = "1", models: String? = nil,
                              installedAt: String = "\"2026-10-20T09:30:00Z\"") -> String {
        let entry = #"{"repo":"mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit","revision":"abc","dir":"Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit","files":["model.safetensors"],"bytes":2400000000}"#
        return #"{"version":\#(version),"python":"3.12.12","lock_sha256":"00","models":\#(models ?? #"{"1.7b":\#(entry)}"#),"installed_at":\#(installedAt)}"#
    }

    /// A fake tree with install.json holding `json`, the model folder, the venv python and the
    /// stamps of a complete python/ and venv/.
    private func fakeInstall(_ json: String? = nil, folder hasFolder: Bool = true, python: Bool = true,
                             stamps: [String] = HQInstallation.completionStamps) -> FakeFileSystem {
        let fs = FakeFileSystem()
        let data = Data((json ?? manifestJSON()).utf8)
        fs.addFile(manifest, size: UInt64(data.count))
        fs.tails[manifest] = data
        fs.directories.insert(home + "/models")
        if hasFolder { fs.directories.insert(folder) }
        if python { fs.addFile(home + "/venv/bin/python3", executable: true) }
        for stamp in stamps { fs.addFile(home + "/" + stamp) }
        return fs
    }

    private func damagedMessage(_ state: HQInstallState, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .damaged(let message) = state else {
            XCTFail("expected damaged, got \(state)", file: file, line: line)
            return ""
        }
        return message
    }

    // MARK: - Home

    func testHomeDefaultsToApplicationSupport() {
        XCTAssertEqual(HQInstallation.home(environment: [:], homeDirectory: "/Users/test"),
                       "/Users/test/Library/Application Support/ReadRead/hq")
    }

    func testHomeFromTheEnvironment() {
        func home(_ value: String) -> String? {
            HQInstallation.home(environment: ["READREAD_HQ_HOME": value], homeDirectory: "/Users/test")
        }
        XCTAssertEqual(home("/scratch/hq"), "/scratch/hq")
        XCTAssertEqual(home("/scratch/hq//"), "/scratch/hq")
        XCTAssertEqual(home("~"), "/Users/test")
        XCTAssertEqual(home("~/hq"), "/Users/test/hq")
        XCTAssertEqual(home("~/hq/"), "/Users/test/hq")
        XCTAssertEqual(home("~root/hq"), ("~root/hq" as NSString).expandingTildeInPath)
        XCTAssertEqual(home("/"), "/")
        XCTAssertEqual(home("relative/hq"), "relative/hq")
    }

    func testAnEmptyHomeIsNeverTheDefault() {
        XCTAssertNil(HQInstallation.home(environment: ["READREAD_HQ_HOME": ""], homeDirectory: "/Users/test"))
        let state = HQInstallation.state(environment: ["READREAD_HQ_HOME": ""], homeDirectory: "/Users/test",
                                         fileSystem: fakeInstall())
        XCTAssertEqual(state, .damaged(
            "READREAD_HQ_HOME is set but empty: unset it to use the default place, or give it a path."))
    }

    func testStateReadsTheHomeOfTheEnvironment() {
        let fs = fakeInstall()
        XCTAssertEqual(HQInstallation.state(environment: ["READREAD_HQ_HOME": "/hq/"], homeDirectory: "/Users/test",
                                            fileSystem: fs).installation?.home, "/hq")
        XCTAssertEqual(HQInstallation.state(environment: [:], homeDirectory: "/Users/test", fileSystem: fs),
                       .notInstalled, "the default home has nothing")
    }

    // MARK: - install.json

    func testACompleteInstall() throws {
        let state = HQInstallation.read(home: home, fileSystem: fakeInstall())
        let installation = try XCTUnwrap(state.installation)
        XCTAssertEqual(installation.home, home)
        XCTAssertEqual(installation.modelBytes, 2_400_000_000)
        XCTAssertEqual(installation.installedAt, Date(timeIntervalSince1970: 1_792_488_600))
        XCTAssertEqual(installation.venvPython, "/hq/venv/bin/python3")
        XCTAssertEqual(installation.modelsDirectory, "/hq/models")
    }

    func testNoManifestIsNotInstalled() {
        let fs = fakeInstall()
        fs.files.removeValue(forKey: manifest)
        XCTAssertEqual(HQInstallation.read(home: home, fileSystem: fs), .notInstalled,
                       "an install that never finished has its files but no install.json")
    }

    func testOtherModelEntriesAndFoldersAreIgnored() {
        let both = #"{"1.7b":{"bytes":5},"old":{"bytes":7,"dir":"Other-Model"}}"#
        let fs = fakeInstall(manifestJSON(models: both))
        fs.directories.insert(home + "/models/Other-Model")
        XCTAssertEqual(HQInstallation.read(home: home, fileSystem: fs).installation?.modelBytes, 5)
    }

    func testOptionalFieldsDegradeQuietly() throws {
        let fs = fakeInstall(manifestJSON(models: #"{"1.7b":{}}"#, installedAt: "\"yesterday\""))
        let installation = try XCTUnwrap(HQInstallation.read(home: home, fileSystem: fs).installation)
        XCTAssertNil(installation.installedAt)
        XCTAssertEqual(installation.modelBytes, 0)
        let odd = fakeInstall(manifestJSON(models: #"{"1.7b":{"bytes":true}}"#, installedAt: "5"))
        XCTAssertEqual(HQInstallation.read(home: home, fileSystem: odd).installation?.modelBytes, 0,
                       "a JSON true is not a size")
        let negative = fakeInstall(manifestJSON(models: #"{"1.7b":{"bytes":-3}}"#))
        XCTAssertEqual(HQInstallation.read(home: home, fileSystem: negative).installation?.modelBytes, 0)
    }

    func testAnotherVersionIsDamaged() {
        for version in ["2", "0", "true", "\"1\"", "null"] {
            let message = damagedMessage(HQInstallation.read(home: home, fileSystem: fakeInstall(manifestJSON(version: version))))
            XCTAssertEqual(message, "/hq/install.json has another format version (this ReadRead reads version 1).",
                           "version \(version)")
        }
        let noVersion = fakeInstall(#"{"models":{"1.7b":{}}}"#)
        XCTAssertTrue(damagedMessage(HQInstallation.read(home: home, fileSystem: noVersion)).contains("format version"))
    }

    func testTheModelMustBeListed() {
        for models in ["{}", #"{"old":{}}"#, #"{"1.7b":"yes"}"#, "[]", "null"] {
            let message = damagedMessage(HQInstallation.read(home: home, fileSystem: fakeInstall(manifestJSON(models: models))))
            XCTAssertEqual(message, "/hq/install.json does not list the 1.7b model.", models)
        }
    }

    func testNotAJSONObjectIsDamaged() {
        for text in ["", "[1,2]", "not json", "{\"version\":1", "\"text\""] {
            let message = damagedMessage(HQInstallation.read(home: home, fileSystem: fakeInstall(text)))
            XCTAssertEqual(message, "/hq/install.json is not a JSON object.", text)
        }
    }

    func testMissingFolderOrPythonIsDamaged() {
        XCTAssertEqual(damagedMessage(HQInstallation.read(home: home, fileSystem: fakeInstall(folder: false))),
                       "The model folder \(folder) is missing.")
        XCTAssertEqual(damagedMessage(HQInstallation.read(home: home, fileSystem: fakeInstall(python: false))),
                       "/hq/venv/bin/python3 is missing or not executable.")
        let notExecutable = fakeInstall(python: false)
        notExecutable.addFile("/hq/venv/bin/python3", executable: false)
        XCTAssertEqual(damagedMessage(HQInstallation.read(home: home, fileSystem: notExecutable)),
                       "/hq/venv/bin/python3 is missing or not executable.")
    }

    /// install-hq.sh moves install.json to install.json.prev before an install or repair first
    /// changes the install, and writes it again last: a run that stopped after a change (cancelled,
    /// a download failing) left only the .prev, and what it was replacing may be half done.
    func testAnInstallOrRepairThatDidNotFinishIsDamaged() {
        let stopped = fakeInstall()
        stopped.files.removeValue(forKey: manifest)
        stopped.addFile(home + "/install.json.prev")
        XCTAssertEqual(HQInstallation.read(home: home, fileSystem: stopped),
                       .damaged("The last install or repair has not finished."))
        let finished = fakeInstall()
        finished.addFile(home + "/install.json.prev")
        XCTAssertNotNil(HQInstallation.read(home: home, fileSystem: finished).installation,
                        "install.json written again (a .prev it could not remove does not count)")
    }

    /// An older install-hq.sh leaves install.json in place while it rebuilds the venv (whose python
    /// exists at once) or replaces Python: their stamps come only once they are complete.
    func testAPythonOrVenvWithoutItsStampIsDamaged() {
        XCTAssertEqual(damagedMessage(HQInstallation.read(home: home, fileSystem: fakeInstall(stamps: ["python/.readread-python"]))),
                       "/hq/venv is incomplete (an install or repair did not finish).")
        XCTAssertEqual(damagedMessage(HQInstallation.read(home: home, fileSystem: fakeInstall(stamps: ["venv/.readread-hq-venv"]))),
                       "/hq/python is incomplete (an install or repair did not finish).")
        XCTAssertEqual(damagedMessage(HQInstallation.read(home: home, fileSystem: fakeInstall(stamps: []))),
                       "/hq/python is incomplete (an install or repair did not finish).")
    }

    func testWhatAnInstallThatNeverFinishedLeft() {
        let empty = FakeFileSystem()
        XCTAssertFalse(HQInstallation.hasLeftovers(home: home, fileSystem: empty))
        empty.directories.insert(home + "/models")
        XCTAssertFalse(HQInstallation.hasLeftovers(home: home, fileSystem: empty), "an empty models/ is no download")
        for leftover in ["python", "python.partial", "venv", "models/" + QwenModel.folder] {
            let fs = FakeFileSystem()
            fs.directories.insert(home + "/" + leftover)
            XCTAssertTrue(HQInstallation.hasLeftovers(home: home, fileSystem: fs), leftover)
        }
    }

    func testOnlyAnEmptyHQHomeVariableMeansNoHome() {
        XCTAssertTrue(HQInstallState.damaged(HQInstallation.emptyHomeMessage).hasNoHome)
        XCTAssertFalse(HQInstallState.damaged("The model folder /hq/models/x is missing.").hasNoHome)
        XCTAssertFalse(HQInstallState.notInstalled.hasNoHome)
        XCTAssertFalse(HQInstallState.installed(makeInstallation()).hasNoHome)
    }

    func testAnUnreadableOrHugeManifestIsDamaged() {
        let unreadable = fakeInstall()
        unreadable.tails.removeValue(forKey: manifest)
        XCTAssertEqual(damagedMessage(HQInstallation.read(home: home, fileSystem: unreadable)),
                       "/hq/install.json cannot be read.")
        let huge = fakeInstall()
        huge.files[manifest] = UInt64(HQInstallation.maxManifestBytes) + 1
        XCTAssertEqual(damagedMessage(HQInstallation.read(home: home, fileSystem: huge)),
                       "/hq/install.json is larger than 1 MB.")
    }

    // MARK: - On disk

    /// A real tree in a temporary directory, read through `LocalFileSystem`.
    private func diskInstall(_ json: String? = nil) throws -> String {
        let root = try makeTemporaryDirectory().appending(path: "hq").path
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/models/" + QwenModel.folder, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/venv/bin", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/python", withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: root + "/venv/bin/python3", contents: Data("#!/bin/sh\n".utf8),
                                    attributes: [.posixPermissions: 0o755]))
        for stamp in HQInstallation.completionStamps {
            XCTAssertTrue(fm.createFile(atPath: root + "/" + stamp, contents: Data("stamp\n".utf8)))
        }
        if let json { try Data(json.utf8).write(to: URL(fileURLWithPath: root + "/install.json")) }
        return root
    }

    func testReadsARealInstall() throws {
        let root = try diskInstall(manifestJSON())
        XCTAssertEqual(HQInstallation.read(home: root, fileSystem: LocalFileSystem()).installation?.modelBytes,
                       2_400_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root + "/venv/bin/python3")
        XCTAssertEqual(HQInstallation.read(home: root, fileSystem: LocalFileSystem()),
                       .damaged("\(root)/venv/bin/python3 is missing or not executable."))
    }

    /// What install-hq.sh leaves when a Repair stops on the way: install.json moved aside; with an
    /// older script (install.json in place), a venv being rebuilt, its stamp not written yet.
    func testARealRepairStoppedOnTheWayIsDamaged() throws {
        let root = try diskInstall()
        let fm = FileManager.default
        try Data(manifestJSON().utf8).write(to: URL(fileURLWithPath: root + "/install.json.prev"))
        XCTAssertEqual(HQInstallation.read(home: root, fileSystem: LocalFileSystem()),
                       .damaged("The last install or repair has not finished."))
        try fm.moveItem(atPath: root + "/install.json.prev", toPath: root + "/install.json")
        XCTAssertNotNil(HQInstallation.read(home: root, fileSystem: LocalFileSystem()).installation)
        try fm.removeItem(atPath: root + "/venv/.readread-hq-venv")
        XCTAssertEqual(HQInstallation.read(home: root, fileSystem: LocalFileSystem()),
                       .damaged("\(root)/venv is incomplete (an install or repair did not finish)."))
        XCTAssertFalse(HQInstallation.hasLeftovers(home: root + "/elsewhere", fileSystem: LocalFileSystem()))
        XCTAssertTrue(HQInstallation.hasLeftovers(home: root, fileSystem: LocalFileSystem()))
    }

    func testARealManifestOverOneMegabyteIsNotRead() throws {
        let padding = String(repeating: " ", count: HQInstallation.maxManifestBytes)
        let root = try diskInstall(manifestJSON() + padding)
        XCTAssertEqual(HQInstallation.read(home: root, fileSystem: LocalFileSystem()),
                       .damaged("\(root)/install.json is larger than 1 MB."))
    }

    func testAFIFONamedInstallJSONNeitherHangsNorCounts() throws {
        let root = try diskInstall()
        XCTAssertEqual(mkfifo(root + "/install.json", 0o600), 0)
        XCTAssertEqual(HQInstallation.read(home: root, fileSystem: LocalFileSystem()),
                       .damaged("\(root)/install.json cannot be read."))
    }

    func testNoHomeDirectoryAtAllIsNotInstalled() throws {
        let root = try makeTemporaryDirectory().appending(path: "never-made").path
        XCTAssertEqual(HQInstallation.read(home: root, fileSystem: LocalFileSystem()), .notInstalled)
    }
}
