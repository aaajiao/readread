import XCTest

@testable import ReadRead

/// The live check (network): four pages through this Mac's reader the way the app reads a link
/// (InputParser, then DocumentLoader), and the first one through defuddle.md as well. Gated by
/// READREAD_TEST_LIVE=1 and READREAD_TEST_WEBKIT=1 with a Defuddle build (`WebKitTestGate`). The
/// web view loads only from each page's own host (`allowedHosts`). The report goes to
/// $READREAD_TEST_SUMMARY when it is set (never into the repository), else to the test log;
/// READREAD_TEST_LIVE_DUMP names a directory for each page's Markdown and units.
@MainActor
final class LiveExtractionTests: XCTestCase {
    static let pages = [
        "https://en.wikipedia.org/wiki/Speech_synthesis", "https://zh.wikipedia.org/wiki/语音合成",
        "https://www.ruanyifeng.com/blog/2020/08/rsync.html", "https://example.com",
    ]

    func testLivePages() async throws {
        guard ProcessInfo.processInfo.environment["READREAD_TEST_LIVE"] == "1" else {
            throw XCTSkip("set READREAD_TEST_LIVE=1 (and READREAD_TEST_WEBKIT=1) to read live pages")
        }
        let script = try WebKitTestGate.defuddleScript()
        let rules = try makeTemporaryDirectory()
        var lines: [String] = []
        var readHere: [String: ReadingDocument] = [:]
        for address in Self.pages {
            guard case .url(let url) = InputParser.parse(address), let host = url.host() else {
                XCTFail("not a link: \(address)")
                continue
            }
            var configured = LocalExtractor.Options(rulesDirectory: rules)
            configured.allowedHosts = [host]
            let options = configured
            let (result, line) = await Self.read(address, url, reader: "this Mac") {
                try await LocalExtractor.read($0, script: script, options: options)
            }
            lines.append(line)
            switch result {
            case .success(let document):
                readHere[address] = document
                XCTAssertFalse(document.units.isEmpty, address)
            case .failure(let error):
                XCTFail("\(address): \(error)")
            }
        }
        XCTAssertEqual(readHere[Self.pages[3]]?.title, "Example Domain")
        XCTAssertEqual(readHere[Self.pages[0]]?.title, "Speech synthesis")
        XCTAssertEqual(readHere[Self.pages[1]]?.title, "语音合成")

        let first = Self.pages[0]
        if case .url(let url) = InputParser.parse(first) {
            let (result, line) = await Self.read(first, url, reader: "defuddle.md") { try await WebExtractor.extractFromURL($0) }
            lines.append(line)
            if case .success(let there) = result, let here = readHere[first] {
                let shared = Set(here.units.map(\.speakText)).intersection(there.units.map(\.speakText)).count
                lines.append("  this Mac vs defuddle.md: titles \"\(here.title)\" / \"\(there.title)\"; \(here.units.count) vs "
                    + "\(there.units.count) units, \(shared) of defuddle.md's units identical here "
                    + String(format: "(%.0f%%)", Double(shared) * 100 / Double(max(1, there.units.count))))
            }
        }
        let report = lines.joined(separator: "\n") + "\n"
        if let path = ProcessInfo.processInfo.environment["READREAD_TEST_SUMMARY"], !path.isEmpty {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            print(report)
        }
    }

    /// One read through DocumentLoader: the document (or the error) and its report line.
    private static func read(
        _ address: String, _ url: URL, reader: String, fetch: @escaping @Sendable (URL) async throws -> WebPage
    ) async -> (Result<ReadingDocument, any Error>, String) {
        let captured = Shared<WebPage?>(nil)
        let dump = ProcessInfo.processInfo.environment["READREAD_TEST_LIVE_DUMP"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let loader = DocumentLoader(fetchPage: { url in
            let page = try await fetch(url)
            captured.value = page
            return page
        }, readFile: { _ in throw WebExtractorError.invalidURL })
        let started = ContinuousClock.now
        do {
            let document = try await loader.load(.url(url))
            let time = seconds(ContinuousClock.now - started)
            let metadata = captured.value.map {
                "author \($0.author ?? "-"), site \($0.site ?? "-"), published \($0.published ?? "-"), \($0.markdown.count) characters"
            } ?? ""
            let units = document.units.prefix(3).map(\.speakText).joined(separator: " | ")
            if let dump, let page = captured.value {
                let name = "\(pages.firstIndex(of: address) ?? 0)-\(reader.replacingOccurrences(of: " ", with: "-"))"
                try? FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
                try? page.markdown.write(to: dump.appending(path: name + ".md"), atomically: true, encoding: .utf8)
                try? document.units.map(\.speakText).joined(separator: "\n")
                    .write(to: dump.appending(path: name + ".units.txt"), atomically: true, encoding: .utf8)
            }
            return (.success(document), "\(address) [\(reader)]: title \"\(document.title)\", \(document.units.count) units, "
                + "\(time); \(metadata)\n  first 3: \(units)")
        } catch {
            return (.failure(error), "\(address) [\(reader)]: \(error.localizedDescription) after \(seconds(ContinuousClock.now - started))")
        }
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.2f s", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }
}
