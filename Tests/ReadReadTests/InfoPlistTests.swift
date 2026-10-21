import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import ReadRead

/// The Info.plist that scripts/build-app.sh writes (its heredoc, with the shell values filled in):
/// localizations (R4-25), the Services entry and the document types (R4-13), against the code
/// they name. smoke-test.sh (f) checks the same keys in a built bundle.
@MainActor
final class InfoPlistTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The heredoc between `cat >"$CONTENTS/Info.plist" <<PLIST` and `PLIST`, each `$(…)` and
    /// `$NAME` replaced by a placeholder, parsed.
    static func builtInfoPlist() throws -> [String: Any] {
        let script = try String(contentsOf: root.appending(path: "scripts/build-app.sh"), encoding: .utf8)
        let lines = script.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex(of: #"cat >"$CONTENTS/Info.plist" <<PLIST"#), "no Info.plist heredoc")
        let end = try XCTUnwrap(lines[(start + 1)...].firstIndex(of: "PLIST"), "the heredoc does not end")
        let body = lines[(start + 1)..<end].joined(separator: "\n")
            .replacingOccurrences(of: #"\$\([^)]*\)"#, with: "0.0.0", options: .regularExpression)
            .replacingOccurrences(of: #"\$[A-Z_]+"#, with: "26.0", options: .regularExpression)
        let plist = try PropertyListSerialization.propertyList(from: Data(body.utf8), format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    func testEnglishIsTheDevelopmentLanguageAndChineseALocalization() throws {
        let plist = try Self.builtInfoPlist()
        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "en")
        XCTAssertEqual(plist["CFBundleLocalizations"] as? [String], ["en", "zh-Hans"])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.readread.app", "the v0.3.0 keys stay")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
    }

    /// The page reader's web view may open http:// pages (ATS refuses them in a bundle otherwise,
    /// NSURLErrorDomain -1022); URLSession keeps ATS: no NSAllowsArbitraryLoads.
    func testOnlyTheWebViewIsExemptFromAppTransportSecurity() throws {
        let ats = try XCTUnwrap(try Self.builtInfoPlist()["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true, "the TTS server on 127.0.0.1")
        XCTAssertEqual(ats["NSAllowsArbitraryLoadsInWebContent"] as? Bool, true)
        XCTAssertEqual(Set(ats.keys), ["NSAllowsLocalNetworking", "NSAllowsArbitraryLoadsInWebContent"])
    }

    func testEveryReadableFileTypeIsADocumentTypeThatNeverClaimsTheDefault() throws {
        let types = try XCTUnwrap(try Self.builtInfoPlist()["CFBundleDocumentTypes"] as? [[String: Any]])
        let identifiers = types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertEqual(identifiers, ReadableFileType.allCases.map(\.identifier), "in ReadableFileType's order")
        for type in types {
            let name = type["CFBundleTypeName"] as? String
            XCTAssertEqual(type["LSHandlerRank"] as? String, "Alternate", "\(name ?? "?"): listed under Open With only")
            XCTAssertEqual(type["CFBundleTypeRole"] as? String, "Viewer", "\(name ?? "?")")
            XCTAssertFalse(name?.isEmpty ?? true, "every type has a name")
        }
        for identifier in identifiers {
            // Declared by the system, so the Info.plist needs no imported type declarations.
            XCTAssertEqual(UTType(identifier)?.isDeclared, true, identifier)
        }
    }

    func testTheServicesEntryNamesTheDelegatesMethod() throws {
        let plist = try Self.builtInfoPlist()
        let services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        XCTAssertEqual(services.count, 1)
        let service = try XCTUnwrap(services.first)
        XCTAssertEqual((service["NSMenuItem"] as? [String: String])?["default"], "Read Aloud with ReadRead")
        XCTAssertEqual(service["NSPortName"] as? String, plist["CFBundleExecutable"] as? String)
        let message = try XCTUnwrap(service["NSMessage"] as? String)
        XCTAssertTrue(AppDelegate.instancesRespond(to: NSSelectorFromString("\(message):userData:error:")),
                      "NSMessage \(message) is AppDelegate's @objc(\(message):userData:error:)")
        let sendTypes = try XCTUnwrap(service["NSSendTypes"] as? [String])
        XCTAssertEqual(Set(sendTypes), [NSPasteboard.PasteboardType.string.rawValue, NSPasteboard.PasteboardType.URL.rawValue])
        XCTAssertNotNil(service["NSRequiredContext"] as? [String: Any], "without it the item is not shown")
    }

    func testTheServicesTitleIsTranslated() throws {
        let url = Self.root.appending(path: "Sources/ReadRead/Resources/zh-Hans.lproj/ServicesMenu.strings")
        let table = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        let services = try XCTUnwrap(try Self.builtInfoPlist()["NSServices"] as? [[String: Any]])
        let title = try XCTUnwrap((services.first?["NSMenuItem"] as? [String: String])?["default"])
        XCTAssertEqual(table, [title: "用 ReadRead 朗读"])
    }

    func testTheBuildCopiesTheLocalizations() throws {
        let script = try String(contentsOf: Self.root.appending(path: "scripts/build-app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains(#"LPROJ_SRC="$RR_REPO_DIR/Sources/ReadRead/Resources""#))
        XCTAssertTrue(script.contains(#"cp "$strings" "$RES/$lproj_name/""#), "every .strings of every .lproj")
        let lprojs = try FileManager.default.contentsOfDirectory(
            at: Self.root.appending(path: "Sources/ReadRead/Resources"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }.map(\.lastPathComponent)
        XCTAssertEqual(lprojs, ["zh-Hans.lproj"], "English is the development language: no en.lproj")
    }
}
