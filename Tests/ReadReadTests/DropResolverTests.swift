import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import ReadRead

/// What a drop, the clipboard, a Services request or Open With hands over → what is read
/// (R4-13, R3-13).
final class DropResolverTests: XCTestCase {
    private let none: (String) -> Bool = { _ in false }

    func testTheFirstReadableFileWins() {
        let items = PasteboardItems(
            fileURLs: [URL(fileURLWithPath: "/tmp/a.zip"), URL(fileURLWithPath: "/tmp/b.epub"), URL(fileURLWithPath: "/tmp/c.txt")],
            urls: [URL(string: "https://example.com")!], strings: ["text"])
        XCTAssertEqual(DropResolver.resolve(items, fileExists: none), .read(.file(URL(fileURLWithPath: "/tmp/b.epub"))))
    }

    func testEveryReadableFormatIsAccepted() {
        for type in ReadableFileType.allCases {
            for ext in type.extensions {
                let url = URL(fileURLWithPath: "/tmp/file.\(ext)")
                XCTAssertEqual(DropResolver.resolve(PasteboardItems(fileURLs: [url]), fileExists: none), .read(.file(url)), ext)
            }
        }
        let log = URL(fileURLWithPath: "/tmp/server.log")
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(fileURLs: [log]), fileExists: none), .read(.file(log)),
                       "another plain-text extension")
    }

    func testFileURLsAmongLinksCountAsFiles() {
        let file = URL(fileURLWithPath: "/tmp/notes.md")
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(urls: [file]), fileExists: none), .read(.file(file)))
    }

    func testAWebLinkComesBeforeText() {
        let items = PasteboardItems(urls: [URL(string: "mailto:a@example.com")!, URL(string: "https://example.com/post")!],
                                    strings: ["Some text"])
        XCTAssertEqual(DropResolver.resolve(items, fileExists: none), .read(.url(URL(string: "https://example.com/post")!)))
        let ftp = PasteboardItems(urls: [URL(string: "ftp://example.com/file")!], strings: ["Some text"])
        XCTAssertEqual(DropResolver.resolve(ftp, fileExists: none), .read(.text("Some text")), "only http(s) links are read")
    }

    func testTextGoesThroughTheInputParser() {
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(strings: ["example.com/post"]), fileExists: none),
                       .read(.url(URL(string: "https://example.com/post")!)))
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(strings: ["  今天天气很好。 "]), fileExists: none),
                       .read(.text("今天天气很好。")))
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(strings: ["/Users/me/book.md"]), fileExists: { _ in true }),
                       .read(.file(URL(fileURLWithPath: "/Users/me/book.md"))))
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(strings: ["/Users/me/photo.png"]), fileExists: { _ in true }),
                       .unsupportedFile(URL(fileURLWithPath: "/Users/me/photo.png")))
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(strings: ["   ", "second string"]), fileExists: none),
                       .read(.text("second string")), "a blank string is skipped")
    }

    func testOnlyUnreadableFilesOrNothing() {
        let zip = URL(fileURLWithPath: "/tmp/a.zip")
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(fileURLs: [zip]), fileExists: none), .unsupportedFile(zip))
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(fileURLs: [zip], strings: ["Read this instead."]), fileExists: none),
                       .read(.text("Read this instead.")))
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(), fileExists: none), .nothing)
        XCTAssertTrue(PasteboardItems().isEmpty)
    }

    /// ⌘C in Finder writes the files' URLs and their names as text: the names are not read (or
    /// fetched as https://<name>) instead of saying the file cannot be read.
    func testFinderCopiedNamesAreNotReadInsteadOfTheFiles() {
        let png = URL(fileURLWithPath: "/Users/me/photo.png")
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(fileURLs: [png], strings: ["photo.png"]), fileExists: none),
                       .unsupportedFile(png))
        let app = URL(fileURLWithPath: "/Applications/Keynote.app")
        let backup = URL(fileURLWithPath: "/Users/me/backup.gz")
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(fileURLs: [app, backup], strings: ["Keynote.app\rbackup.gz\r"]),
                                            fileExists: none), .unsupportedFile(app))
        let numbers = URL(fileURLWithPath: "/Users/me/Budget 2026.numbers")
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(fileURLs: [numbers], strings: ["Budget 2026"]), fileExists: none),
                       .unsupportedFile(numbers), "the name as Finder shows it with extensions hidden")
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(fileURLs: [numbers], strings: ["/Users/me/Budget 2026.numbers"]),
                                            fileExists: { _ in true }), .unsupportedFile(numbers))
        XCTAssertEqual(DropResolver.resolve(PasteboardItems(fileURLs: [png], strings: ["photo.png is the cover. Read this."]),
                                            fileExists: none), .read(.text("photo.png is the cover. Read this.")),
                       "text that says more than the names is read")
        XCTAssertFalse(DropResolver.namesOnly("photo.png", of: []))
    }

    func testThePasteboardTypesMatch() {
        XCTAssertEqual(DropResolver.acceptedTypes, [.fileURL, .url, .utf8PlainText, .plainText])
        XCTAssertEqual(DropResolver.acceptedPasteboardTypes, [.fileURL, .URL, .string])
    }

    /// A private, named pasteboard (never the user's clipboard), released afterwards.
    @MainActor
    func testAPasteboardIsReadIntoItems() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ReadReadTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let file = URL(fileURLWithPath: "/tmp/chapter.md")
        let web = try XCTUnwrap(URL(string: "https://example.com/post"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([file as NSURL, web as NSURL]))
        var items = SystemPasteboard.items(from: pasteboard)
        XCTAssertEqual(items.fileURLs, [file])
        XCTAssertEqual(items.urls, [web])

        let access = SystemPasteboard(pasteboard)
        access.write("Copied text")
        items = access.readItems()
        XCTAssertEqual(items.strings, ["Copied text"])
        XCTAssertTrue(items.fileURLs.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "Copied text")
    }

    @MainActor
    func testItemProvidersOfADropAreRead() async throws {
        func provider(_ type: UTType, _ data: Data) -> NSItemProvider {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            return provider
        }
        let file = URL(fileURLWithPath: "/tmp/book.epub")
        let web = try XCTUnwrap(URL(string: "https://example.com/a"))
        let items = await ItemProviderReader.items(from: [
            provider(.fileURL, file.dataRepresentation),
            provider(.url, web.dataRepresentation),
            provider(.utf8PlainText, Data("拖进来的文字".utf8)),
        ])
        XCTAssertEqual(items.fileURLs, [file])
        XCTAssertEqual(items.urls, [web])
        XCTAssertEqual(items.strings, ["拖进来的文字"])
        XCTAssertEqual(DropResolver.resolve(items, fileExists: none), .read(.file(file)))
    }
}
