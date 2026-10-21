import Foundation
import XCTest

/// The "Content" table (page, file and format messages) against the sources: every message in
/// `String(localized: "…", table: "Content")` has its Simplified Chinese line in
/// Sources/ReadRead/Resources/zh-Hans.lproj/Content.strings, with the same format specifiers, and
/// the file holds no line the sources no longer use.
final class ContentStringsTests: XCTestCase {
    private let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/ReadRead")

    func testEveryContentMessageHasItsChineseLine() throws {
        let keys = try contentKeys()
        XCTAssertGreaterThan(keys.count, 30, "the scan found the messages")
        let table = try chineseTable()
        for key in keys {
            guard let value = table[key] else {
                XCTFail("no zh-Hans line for: \(key)")
                continue
            }
            XCTAssertEqual(specifiers(value), specifiers(key), key)
            XCTAssertNotEqual(value, key, "translated: \(key)")
        }
        XCTAssertEqual(Set(table.keys).subtracting(keys).sorted(), [], "lines no source uses")
    }

    /// The table formats as the English does (the arguments' types match the specifiers).
    func testTheChineseLinesFormat() throws {
        let table = try chineseTable()
        let line = try XCTUnwrap(table["The %@ file is too large to read (%lld MB; the limit is %lld MB)."])
        XCTAssertEqual(String(format: line, "EPUB", 700, 512), "这个 EPUB 文件太大，无法读取（700 MB；上限为 512 MB）。")
        let status = try XCTUnwrap(table["ditto could not unpack it (status %d)"])
        XCTAssertEqual(String(format: status, Int32(1)), "ditto 无法解压它（状态 1）")
    }

    private func chineseTable() throws -> [String: String] {
        let file = sources.appending(path: "Resources/zh-Hans.lproj/Content.strings")
        let data = try Data(contentsOf: file)
        XCTAssertNotNil(String(data: data, encoding: .utf8), "UTF-8")
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    /// The literal keys of `String(localized: "…", table: "Content")` in Sources/ReadRead.
    private func contentKeys() throws -> Set<String> {
        var keys = Set<String>()
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            var rest = text[...]
            while let start = rest.range(of: "String(localized: \"") {
                var key = ""
                var index = start.upperBound
                var escaped = false
                while index < rest.endIndex {
                    let character = rest[index]
                    if escaped {
                        key.append(character == "n" ? "\n" : character)
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        break
                    } else {
                        key.append(character)
                    }
                    index = rest.index(after: index)
                }
                let after = rest[index...].prefix(200)
                if after.range(of: #"^"\s*,\s*table:\s*"Content""#, options: .regularExpression) != nil { keys.insert(key) }
                rest = rest[index...].dropFirst()
            }
        }
        return keys
    }

    private func specifiers(_ text: String) -> [String] {
        text.matches(of: /%(?:\d+\$)?(lld|d|@)/).map { String($0.output.1) }
    }
}
