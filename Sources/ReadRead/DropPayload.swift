import AppKit
import UniformTypeIdentifiers

/// What a drop, the clipboard, a Services request or "Open With" hands over, read into plain
/// values (R4-13, R3-13).
struct PasteboardItems: Equatable, Sendable {
    var fileURLs: [URL] = []
    /// Web links (file URLs found here count as files).
    var urls: [URL] = []
    var strings: [String] = []

    var isEmpty: Bool { fileURLs.isEmpty && urls.isEmpty && strings.isEmpty }
}

/// What to do with `PasteboardItems`.
enum DropResolution: Equatable, Sendable {
    case read(ReadingInput)
    /// Only files ReadRead cannot read (`ReadableFileType.of` is nil).
    case unsupportedFile(URL)
    case nothing
}

enum DropResolver {
    /// The pasteboard types the panel and the status item accept.
    static let acceptedTypes: [UTType] = [.fileURL, .url, .utf8PlainText, .plainText]
    static let acceptedPasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]

    /// A readable file first (the first one, by `ReadableFileType`), then a web link, then text
    /// (through `InputParser`: a link or a path in it is followed, anything else is read). Text
    /// that only names the files (what Finder's ⌘C puts beside them) is not read in their place.
    static func resolve(
        _ items: PasteboardItems, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> DropResolution {
        let files = items.fileURLs + items.urls.filter(\.isFileURL)
        if let file = files.first(where: { ReadableFileType.of($0) != nil }) { return .read(.file(file)) }
        if let web = items.urls.first(where: { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }) {
            return .read(.url(web))
        }
        for string in items.strings where !namesOnly(string, of: files) {
            if let input = InputParser.parse(string, fileExists: fileExists) {
                if case .file(let url) = input, ReadableFileType.of(url) == nil { return .unsupportedFile(url) }
                return .read(input)
            }
        }
        if let file = files.first { return .unsupportedFile(file) }
        return .nothing
    }

    /// `string` is nothing but the names of `files`, one per line: each line a file's name (with
    /// or without its extension, as Finder shows it) or its path.
    static func namesOnly(_ string: String, of files: [URL]) -> Bool {
        guard !files.isEmpty else { return false }
        var names = Set<String>()
        for file in files {
            let path = file.path(percentEncoded: false)
            names.formUnion([file.lastPathComponent, file.deletingPathExtension().lastPathComponent, path,
                             (path as NSString).abbreviatingWithTildeInPath])
        }
        let lines = string.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return !lines.isEmpty && lines.allSatisfy(names.contains)
    }
}

/// The clipboard (and the pasteboards of drags and Services requests), behind a protocol so the
/// app's use of it is tested without the pasteboard server.
@MainActor
protocol PasteboardAccess: AnyObject {
    func readItems() -> PasteboardItems
    func write(_ string: String)
}

/// An `NSPasteboard` (the general one by default).
@MainActor
final class SystemPasteboard: PasteboardAccess {
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func readItems() -> PasteboardItems {
        Self.items(from: pasteboard)
    }

    func write(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    static func items(from pasteboard: NSPasteboard) -> PasteboardItems {
        var items = PasteboardItems()
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL] {
            items.fileURLs = files
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL] {
            items.urls = urls.filter { !$0.isFileURL }
        }
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            items.strings = [string]
        }
        return items
    }
}

/// Reads a SwiftUI drop's item providers into `PasteboardItems` (file URLs, links, text).
enum ItemProviderReader {
    @MainActor
    static func items(from providers: [NSItemProvider]) async -> PasteboardItems {
        var items = PasteboardItems()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let data = await data(provider, UTType.fileURL), let url = URL(dataRepresentation: data, relativeTo: nil) {
                    items.fileURLs.append(url)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let data = await data(provider, UTType.url), let url = URL(dataRepresentation: data, relativeTo: nil) {
                    items.urls.append(url)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                let type = provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
                    ? UTType.utf8PlainText : UTType.plainText
                if let data = await data(provider, type), let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    items.strings.append(text)
                }
            }
        }
        return items
    }

    @MainActor
    private static func data(_ provider: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
