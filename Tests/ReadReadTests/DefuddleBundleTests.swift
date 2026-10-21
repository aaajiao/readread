import Foundation
import XCTest

@testable import ReadRead

/// Where the page reader's Defuddle build is found: the app bundle's Resources first, then
/// `$READREAD_HOME` (setup.sh), never the real ~/.readread when READREAD_HOME is set but empty.
final class DefuddleBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ReadReadTests-defuddle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func install(_ source: String, under base: URL) throws -> URL {
        let file = base.appending(path: "defuddle/defuddle.full.js")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(source.utf8).write(to: file)
        return file
    }

    func testTheBundleComesFirstThenReadReadHome() throws {
        let resources = root.appending(path: "ReadRead.app/Contents/Resources")
        let home = root.appending(path: "rrhome")
        let bundled = try install("/* Defuddle, bundled */", under: resources)
        try install("/* Defuddle, dev */", under: home)
        var context = TTSServerPaths.Context(bundleResources: resources.path, environment: ["READREAD_HOME": home.path],
                                             homeDirectory: root.path, currentDirectory: root.path)
        XCTAssertEqual(DefuddleBundle.locate(context)?.url.path, bundled.path)
        XCTAssertEqual(DefuddleBundle.load(context), "/* Defuddle, bundled */")

        // An empty file, or one that is not Defuddle, is passed over.
        try Data().write(to: bundled)
        XCTAssertEqual(DefuddleBundle.load(context), "/* Defuddle, dev */")
        try Data("console.log(1)".utf8).write(to: bundled)
        XCTAssertEqual(DefuddleBundle.load(context), "/* Defuddle, dev */")

        // READREAD_HOME set but empty: no home candidate (and never ~/.readread).
        context.environment["READREAD_HOME"] = ""
        XCTAssertNil(DefuddleBundle.locate(context))
        XCTAssertEqual(DefuddleBundle.candidates(context).map(\.path), [bundled.path])
    }
}
