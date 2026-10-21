import XCTest

@testable import ReadRead

/// positions.json (R3-14 resume): round trip, corrupt files, the 200-entry limit, the path.
@MainActor
final class ReadingPositionStoreTests: XCTestCase {
    private func position(_ unit: Int, hash: String = "abc", at seconds: TimeInterval = 1_000) -> ReadingPosition {
        ReadingPosition(unit: unit, contentHash: hash, date: Date(timeIntervalSince1970: seconds))
    }

    func testPositionsSurviveANewStore() throws {
        let file = try makeTemporaryDirectory().appending(path: "nested/positions.json")
        let store = ReadingPositionStore(fileURL: file)
        XCTAssertNil(store.position(for: "url:https://example.com"))
        store.save(position(3), for: "url:https://example.com")
        store.save(position(7, hash: "def"), for: "file:/tmp/a.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the directory is created")

        let reopened = ReadingPositionStore(fileURL: file)
        XCTAssertEqual(reopened.position(for: "url:https://example.com"), position(3))
        XCTAssertEqual(reopened.position(for: "file:/tmp/a.txt"), position(7, hash: "def"))

        reopened.removePosition(for: "url:https://example.com")
        XCTAssertNil(ReadingPositionStore(fileURL: file).position(for: "url:https://example.com"))
        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(json.contains("\"version\":1"), json)
        XCTAssertTrue(json.contains("1970-01-01T00:16:40Z"), "ISO 8601 dates: \(json)")
    }

    func testACorruptFileIsIgnoredAndReplaced() throws {
        let file = try makeTemporaryDirectory().appending(path: "positions.json")
        try Data("{not json".utf8).write(to: file)
        let store = ReadingPositionStore(fileURL: file)
        XCTAssertNil(store.position(for: "x"))
        store.save(position(1), for: "x")
        XCTAssertEqual(ReadingPositionStore(fileURL: file).position(for: "x"), position(1))
    }

    func testOnlyTheNewest200AreKept() throws {
        let file = try makeTemporaryDirectory().appending(path: "positions.json")
        let store = ReadingPositionStore(fileURL: file)
        for index in 0..<205 { store.save(position(index, at: TimeInterval(index)), for: "key\(index)") }
        let reopened = ReadingPositionStore(fileURL: file)
        XCTAssertNil(reopened.position(for: "key4"))
        XCTAssertEqual(reopened.position(for: "key5")?.unit, 5)
        XCTAssertEqual(reopened.position(for: "key204")?.unit, 204)
    }

    func testTheFileLocation() {
        XCTAssertEqual(ReadingPositionStore.defaultFileURL(environment: [:], homeDirectory: "/Users/me").path,
                       "/Users/me/Library/Application Support/ReadRead/positions.json")
        XCTAssertEqual(ReadingPositionStore.defaultFileURL(environment: ["READREAD_POSITIONS_FILE": "/tmp/p.json"]).path,
                       "/tmp/p.json")
        XCTAssertEqual(ReadingPositionStore.defaultFileURL(environment: ["READREAD_POSITIONS_FILE": ""], homeDirectory: "/h").path,
                       "/h/Library/Application Support/ReadRead/positions.json")
    }
}
