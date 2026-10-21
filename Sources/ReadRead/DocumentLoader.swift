import Foundation

enum DocumentError: LocalizedError, Equatable {
    /// Empty, only markup, or only scripts ReadRead does not read (R3-12).
    case nothingToRead
    /// A page on the local network, and no Defuddle to read it here (defuddle.md cannot reach it).
    case localNetwork(String)
    /// Neither this Mac nor defuddle.md could read the page: both reasons.
    case pageUnreadable(local: String, remote: String)

    var errorDescription: String? {
        switch self {
        case .nothingToRead:
            return String(localized: "Nothing to read (没有可读的内容): the text is empty, only markup, or in a language ReadRead does not read.",
                          table: "Content")
        case .localNetwork(let host):
            return String(format: String(localized: "%@ is on your local network, which defuddle.md cannot reach, and ReadRead's page reader (Defuddle) is not installed: run ./scripts/setup.sh, or use the app build-app.sh builds. Or copy the page's text and paste it here to read it.",
                                         table: "Content"), host)
        case .pageUnreadable(let local, let remote):
            return String(format: String(localized: "ReadRead could not read the page on this Mac (%@) nor through defuddle.md (%@).",
                                         table: "Content"), local, remote)
        }
    }
}

/// Input → `ReadingDocument`: fetches or reads it, cleans it and splits it into units, off
/// the main actor. Cancellation is checked between the steps (R1-15, H9).
struct DocumentLoader: Sendable {
    var fetchPage: @Sendable (URL) async throws -> WebPage
    var readFile: @Sendable (URL) async throws -> LocalFile

    /// By default pages go through `WebPageFetcher` (this Mac or defuddle.md, as Settings says;
    /// local-network pages only here) and files through `DocumentReader` (every `ReadableFileType`).
    init(
        fetchPage: @escaping @Sendable (URL) async throws -> WebPage = { try await WebPageFetcher.live().fetch($0) },
        readFile: @escaping @Sendable (URL) async throws -> LocalFile = { try await DocumentReader.read($0) }
    ) {
        self.fetchPage = fetchPage
        self.readFile = readFile
    }

    @concurrent
    func load(_ input: ReadingInput) async throws -> ReadingDocument {
        let document: ReadingDocument
        switch input {
        case .url(let url):
            let page = try await fetchPage(url)
            try Task.checkCancellation()
            document = page.isPlainText
                ? DocumentBuilder.fromPlainText(page.markdown, title: page.title, source: .url(url), sourceLabel: page.domain)
                : DocumentBuilder.fromMarkdown(page.markdown, title: page.title, source: .url(url), sourceLabel: page.domain)
        case .file(let url):
            let file = try await readFile(url)
            try Task.checkCancellation()
            let title = file.titleFromMetadata ? file.title : nil
            if let blocks = file.blocks {
                document = DocumentBuilder.build(blocks, title: title, source: .file(url), sourceLabel: file.fileName)
            } else if file.isMarkdown {
                document = DocumentBuilder.fromMarkdown(file.body, title: title, source: .file(url), sourceLabel: file.fileName)
            } else {
                document = DocumentBuilder.fromPlainText(file.body, title: title, source: .file(url), sourceLabel: file.fileName)
            }
        case .text(let text):
            let normalized = TextDecoding.normalizeNewlines(text)
            // One Markdown signal must not cost the paste its indented paragraphs.
            document = Self.looksLikeMarkdown(normalized)
                ? DocumentBuilder.fromMarkdown(normalized, title: nil, source: .text, sourceLabel: "", keepsIndentedText: true)
                : DocumentBuilder.fromPlainText(normalized, title: nil, source: .text, sourceLabel: "")
        }
        try Task.checkCancellation()
        guard Self.hasContent(document) else { throw DocumentError.nothingToRead }
        return document
    }

    /// Something to read besides the title.
    static func hasContent(_ document: ReadingDocument) -> Bool {
        document.units.contains { $0.kind != .title && $0.language != nil }
    }

    /// Pasted text copied from a Markdown editor or a chat: headings, links, fences or
    /// strong emphasis. Plain prose goes through the plain-text cleaner.
    static func looksLikeMarkdown(_ text: String) -> Bool {
        let signals = [
            #"(?m)^#{1,6}[ \t]+\S"#, #"\[[^\]\n]+\]\([^)\n]+\)"#, #"(?m)^[ \t]*(```|~~~)"#, #"\*\*[^*\n]+\*\*"#,
            #"(?m)^[ \t]*[-*+][ \t]+\S"#, #"(?m)^>[ \t]?\S"#,
        ]
        return signals.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}
