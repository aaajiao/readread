import Foundation
import XCTest

@testable import ReadRead

/// Every literal UI string in Sources/ReadRead has a zh-Hans translation (R4-25), and every
/// translation is used.
///
/// The scan finds the string literal passed first to `Text`, `Button`, `Label`, `Toggle`, `Picker`,
/// `Section`, `Tab`, `LabeledContent`, `TextField`, `Link`, `Menu`, `.help`,
/// `.accessibilityLabel` / `Hint` / `Value`, `.navigationTitle`, `String(localized:)` and
/// `LocalizedStringKey(…)`, outside `//` comments, and turns each `\(…)` into `%@`: the UI code
/// interpolates strings only, so `%@` is exactly the key's specifier. The keys must be in
/// `zh-Hans.lproj/Localizable.strings`; a key the content track (P6) owns may instead be in
/// `Content.strings` (its specifiers are compared loosely there).
///
/// What it cannot see: strings built at runtime (variables, concatenation, a ternary between two
/// literals, which Swift may type as `String` and so never look up), multi-line and raw literals,
/// `Text(verbatim:)` (not localized on purpose: names, numbers, 中文 / English), the Info.plist's
/// Services title (ServicesMenu.strings, checked by `InfoPlistTests`), and a non-string
/// interpolation (its runtime key ends in `%lld`, not `%@`: the lookup misses and English shows).
/// A bare literal in an `errorDescription` body (`return "…"`, shown in the banner as it is) is
/// caught separately: every error message the user sees goes through `String(localized:)`.
final class LocalizationCoverageTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sources = root.appending(path: "Sources/ReadRead")
    static let zhHans = sources.appending(path: "Resources/zh-Hans.lproj")

    static let calls = [
        "Text(", "Button(", "Label(", "Toggle(", "Picker(", "Section(", "Tab(", "LabeledContent(", "TextField(",
        "Link(", "Menu(", ".help(", ".accessibilityLabel(", ".accessibilityHint(", ".accessibilityValue(",
        ".navigationTitle(", "String(localized:", "LocalizedStringKey(",
    ]

    // MARK: - Scanning

    /// The keys of the localizable literals in `source`.
    static func keys(in source: String) -> [String] {
        let chars = Array(source)
        var keys: [String] = []
        var index = 0
        while index < chars.count {
            if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if chars[index] == "\"" {
                // A literal that is not an argument we look at: skip it whole.
                index = skipLiteral(chars, from: index)
                continue
            }
            guard firstCharacters.contains(chars[index]) else {
                index += 1
                continue
            }
            var matched = false
            for pattern in patterns where matches(pattern, chars, at: index) {
                var cursor = index + pattern.count
                while cursor < chars.count, chars[cursor] == " " { cursor += 1 }
                guard cursor < chars.count, chars[cursor] == "\"",
                      !(cursor + 2 < chars.count && chars[cursor + 1] == "\"" && chars[cursor + 2] == "\"") else { continue }
                if let (key, end) = literal(chars, from: cursor) {
                    keys.append(key)
                    index = end
                    matched = true
                }
                break
            }
            if !matched { index += 1 }
        }
        return keys
    }

    private static let patterns: [[Character]] = calls.map { Array($0) }
    private static let firstCharacters = Set(patterns.compactMap(\.first))

    private static func matches(_ pattern: [Character], _ chars: [Character], at index: Int) -> Bool {
        guard index + pattern.count <= chars.count else { return false }
        for offset in pattern.indices where chars[index + offset] != pattern[offset] { return false }
        // `Text(` but not `BlockText(`; `.help(` is a modifier, any receiver.
        if pattern.first == "." { return true }
        guard index > 0 else { return true }
        let before = chars[index - 1]
        return !(before.isLetter || before.isNumber || before == "_")
    }

    /// The literal starting at the quote at `start`, as its localization key, and the index after it.
    static func literal(_ chars: [Character], from start: Int) -> (String, Int)? {
        var key = ""
        var index = start + 1
        while index < chars.count {
            let character = chars[index]
            if character == "\"" { return (key, index + 1) }
            if character == "\n" { return nil }
            if character == "\\", index + 1 < chars.count {
                let next = chars[index + 1]
                switch next {
                case "(":
                    key += "%@"
                    index = skipInterpolation(chars, from: index + 1)
                    continue
                case "n": key += "\n"
                case "t": key += "\t"
                case "\"": key += "\""
                case "\\": key += "\\"
                case "'": key += "'"
                case "u":
                    // \u{XXXX}
                    if let close = chars[(index + 2)...].firstIndex(of: "}"),
                       let value = UInt32(String(chars[(index + 3)..<close]), radix: 16), let scalar = Unicode.Scalar(value) {
                        key.unicodeScalars.append(scalar)
                        index = close + 1
                        continue
                    }
                default: key.append(next)
                }
                index += 2
                continue
            }
            key.append(character)
            index += 1
        }
        return nil
    }

    /// From the `(` of an interpolation to after its `)`, over nested parentheses and literals.
    private static func skipInterpolation(_ chars: [Character], from open: Int) -> Int {
        var depth = 0
        var index = open
        while index < chars.count {
            switch chars[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index + 1 }
            case "\"":
                index = skipLiteral(chars, from: index)
                continue
            default: break
            }
            index += 1
        }
        return index
    }

    private static func skipLiteral(_ chars: [Character], from start: Int) -> Int {
        if start + 2 < chars.count, chars[start + 1] == "\"", chars[start + 2] == "\"" {
            // """ … """
            var index = start + 3
            while index + 2 < chars.count {
                if chars[index] == "\"", chars[index + 1] == "\"", chars[index + 2] == "\"" { return index + 3 }
                index += 1
            }
            return chars.count
        }
        var index = start + 1
        while index < chars.count {
            switch chars[index] {
            case "\\":
                if index + 1 < chars.count, chars[index + 1] == "(" {
                    index = skipInterpolation(chars, from: index + 1)
                    continue
                }
                index += 2
                continue
            case "\"", "\n":
                return index + 1
            default:
                index += 1
            }
        }
        return index
    }

    /// The literals with a letter in the `errorDescription` bodies of `source` that are not the
    /// key of a `String(localized:)` (interpolations skipped): English the banner would show as it is.
    static func bareErrorLiterals(in source: String) -> [String] {
        let chars = Array(source)
        let opening = Array("var errorDescription: String? {")
        let localized: [[Character]] = [Array("String(localized:"), Array("LocalizedStringKey(")]
        var found: [String] = []
        var index = 0
        while index < chars.count {
            guard matches(opening, chars, at: index) else {
                index += 1
                continue
            }
            var cursor = index + opening.count
            var depth = 1
            while cursor < chars.count, depth > 0 {
                let character = chars[cursor]
                if character == "/", cursor + 1 < chars.count, chars[cursor + 1] == "/" {
                    while cursor < chars.count, chars[cursor] != "\n" { cursor += 1 }
                    continue
                }
                if let call = localized.first(where: { matches($0, chars, at: cursor) }) {
                    var start = cursor + call.count
                    while start < chars.count, chars[start] == " " { start += 1 }
                    if start < chars.count, chars[start] == "\"" {
                        cursor = skipLiteral(chars, from: start)
                        continue
                    }
                }
                switch character {
                case "{": depth += 1
                case "}": depth -= 1
                case "\"":
                    let end = skipLiteral(chars, from: cursor)
                    var before = cursor - 1
                    while before > 0, chars[before] == " " { before -= 1 }
                    let isTable = before >= 5 && String(chars[(before - 5)...before]) == "table:"
                    if isTable {
                        // String(localized: "…", table: "Content"): the table's name
                    } else if let (key, _) = literal(chars, from: cursor), key.replacingOccurrences(of: "%@", with: "")
                        .contains(where: { $0.isLetter }) {
                        found.append(key)
                    } else if end - cursor > 2, chars[cursor + 1] == "\"", chars[cursor + 2] == "\"" {
                        found.append(String(chars[cursor..<end]))
                    }
                    cursor = end
                    continue
                default: break
                }
                cursor += 1
            }
            index = cursor
        }
        return found
    }

    /// `%lld`, `%d`, `%1$@`… → `%@`, for P6's table.
    static func looseKey(_ key: String) -> String {
        key.replacingOccurrences(of: #"%(\d+\$)?(l{0,2}[dDuUxX]|@|\.?\d*f)"#, with: "%@", options: .regularExpression)
    }

    static func specifierCount(_ text: String) -> Int {
        text.components(separatedBy: "%@").count - 1
    }

    // MARK: - Files

    static func table(_ name: String) throws -> [String: String]? {
        let url = zhHans.appending(path: "\(name).strings")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard String(data: data, encoding: .utf8) != nil else {
            XCTFail("\(name).strings is not UTF-8")
            return [:]
        }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String], "\(name).strings is not a strings table")
    }

    static func scannedKeys() throws -> [(file: String, key: String)] {
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var result: [(String, String)] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for key in keys(in: source) where key.contains(where: { $0.isLetter }) {
                result.append((file.lastPathComponent, key))
            }
        }
        return result
    }

    // MARK: - Tests

    func testEveryUIStringHasAChineseTranslation() throws {
        let localizable = try XCTUnwrap(try Self.table("Localizable"), "zh-Hans.lproj/Localizable.strings is missing")
        let content = try Self.table("Content") ?? [:]
        let looseContent = Set(content.keys.map(Self.looseKey))
        let scanned = try Self.scannedKeys()
        XCTAssertGreaterThan(scanned.count, 100, "the scan finds the UI strings")
        var missing: [String] = []
        for (file, key) in scanned where localizable[key] == nil && !looseContent.contains(Self.looseKey(key)) {
            missing.append("\(file): \"\(key)\"")
        }
        XCTAssertTrue(missing.isEmpty, "no zh-Hans entry for:\n" + Set(missing).sorted().joined(separator: "\n"))
    }

    func testEveryTranslationIsUsedAndKeepsItsPlaceholders() throws {
        let localizable = try XCTUnwrap(try Self.table("Localizable"))
        let used = Set(try Self.scannedKeys().map(\.key))
        let unused = localizable.keys.filter { !used.contains($0) }.sorted()
        XCTAssertTrue(unused.isEmpty, "not in the code (stale, or a key the code builds differently):\n" + unused.joined(separator: "\n"))
        for (key, value) in localizable {
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "empty translation for \"\(key)\"")
            XCTAssertEqual(Self.specifierCount(key), Self.specifierCount(value), "placeholders of \"\(key)\" → \"\(value)\"")
            XCTAssertFalse(value.contains("%lld") || value.contains("%d"), "\"\(value)\": the code interpolates strings (%@)")
        }
    }

    func testEveryErrorMessageIsLocalized() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var bare: [String] = []
        var bodies = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            bodies += source.components(separatedBy: "var errorDescription: String? {").count - 1
            bare += Self.bareErrorLiterals(in: source).map { "\(file.lastPathComponent): \"\($0)\"" }
        }
        XCTAssertGreaterThan(bodies, 5, "the scan finds the error types")
        XCTAssertEqual(bare.sorted(), [], "error messages not looked up in Localizable.strings or Content.strings")
    }

    func testTheErrorScanFindsBareLiterals() {
        let source = #"""
        enum E: LocalizedError {
            var errorDescription: String? {
                switch self {
                case .a: return "Plain English."  // "a comment"
                case .b(let x): return String(localized: "Localized \(x ? "yes" : "no").") + "\n• \(x)"
                case .c: return String(localized: "Two", table: "Content") + "Tail"
                }
            }
            var other: String { "Not an error message" }
        }
        """#
        XCTAssertEqual(LocalizationCoverageTests.bareErrorLiterals(in: source), ["Plain English.", "Tail"])
    }

    func testTheTableHasNoDuplicateKeys() throws {
        let text = try String(contentsOf: Self.zhHans.appending(path: "Localizable.strings"), encoding: .utf8)
        var seen: [String: Int] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("\"") {
            guard let range = line.range(of: #"^"(?:[^"\\]|\\.)*""#, options: .regularExpression) else { continue }
            seen[String(line[range]), default: 0] += 1
        }
        XCTAssertEqual(seen.filter { $0.value > 1 }.keys.sorted(), [], "a later duplicate silently wins")
    }

    func testTheScannerReadsLiteralsAsKeys() {
        let source = #"""
        Text("Plain") // Text("in a comment")
        Button("Hear \(voice.name)") { }
        .help(Text("Speed for \(VoiceAccent.languageName(language)) text"))
        String(localized: "Failed: \(message(for: "x"))")
        Text(verbatim: "ReadRead")
        BlockText(block)
        Text("Say \"hi\"\n")
        let s = "Text(\"not a call\")"
        LocalizedStringKey("中文 voice")
        """#
        XCTAssertEqual(LocalizationCoverageTests.keys(in: source),
                       ["Plain", "Hear %@", "Speed for %@ text", "Failed: %@", "Say \"hi\"\n", "中文 voice"])
        XCTAssertEqual(Self.looseKey("%lld pages, %1$@ and %.1f"), "%@ pages, %@ and %@")
    }
}
