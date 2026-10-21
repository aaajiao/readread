import Foundation

/// Why a document file could not be read.
enum DocumentReadError: LocalizedError, Equatable {
    /// Format name, its size, the format's limit (bytes).
    case tooLarge(String, Int, Int)
    /// Format name, reason.
    case unreadable(String, String)
    case passwordProtected
    /// A PDF of scanned pages: images, no text.
    case noTextLayer
    case drmProtected
    case invalidEPUB(String)
    /// An EPUB whose content unpacks to more than the limit (bytes), whatever the file's own size.
    case unpackedTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let format, let bytes, let limit):
            return String(format: String(localized: "The %@ file is too large to read (%lld MB; the limit is %lld MB).", table: "Content"),
                          format, max(1, bytes / 1_000_000), limit / 1_000_000)
        case .unreadable(let format, let reason):
            return String(format: String(localized: "This %@ file could not be read: %@", table: "Content"), format, reason)
        case .passwordProtected:
            return String(localized: "This PDF is protected by a password. Open it in Preview, export a copy without the password, and open that.",
                          table: "Content")
        case .noTextLayer:
            return String(localized: "This PDF has no text, only images of pages (a scan). Recognize its text first (OCR), then open it again.",
                          table: "Content")
        case .drmProtected:
            return String(localized: "This EPUB is protected by DRM: ReadRead reads only books without it.", table: "Content")
        case .invalidEPUB(let reason):
            return String(format: String(localized: "This EPUB file is damaged or not an EPUB: %@", table: "Content"), reason)
        case .unpackedTooLarge(let limit):
            return String(format: String(localized: "This EPUB is too large to read: its content unpacks to more than %lld MB.", table: "Content"),
                          max(1, limit / 1_000_000))
        }
    }
}

/// A local file → `LocalFile`, by its format (`ReadableFileType`): text and Markdown as before
/// (`WebExtractor.readFile`), HTML through the local Defuddle (else the system's HTML reader),
/// RTF, RTFD, Word and OpenDocument through `NSAttributedString`, PDF through PDFKit and EPUB
/// unpacked into a temporary directory. Each format has a size limit; documents become cleaned
/// blocks (`LocalFile.blocks`). An unknown extension is read as text.
struct DocumentReader: Sendable {
    struct Limits: Sendable {
        /// File (or RTFD package) size per format.
        var bytes: [ReadableFileType: Int] = [
            .html: 32_000_000, .rtf: 64_000_000, .doc: 64_000_000, .docx: 128_000_000, .odt: 128_000_000,
            .rtfd: 256_000_000, .pdf: 256_000_000, .epub: 512_000_000,
        ]
        /// An EPUB's content, unpacked.
        var epubExpandedBytes = 1_000_000_000
        var epubEntries = 20_000
        /// Text kept from one document (like a 32 MB text file).
        var characters = 32_000_000
    }

    /// The Defuddle source for .html files; nil = the system's HTML reader only.
    var defuddleScript: @Sendable () -> String?
    var webKitOptions: LocalExtractor.Options
    /// Where an EPUB is unpacked (`<cache>/epub`), each in a directory of its own, removed after.
    var unpackDirectory: URL
    var limits = Limits()

    static func live() -> DocumentReader {
        let environment = ProcessInfo.processInfo.environment
        let cache = RuntimeDirectories(environment: environment, homeDirectory: NSHomeDirectory()).cacheDirectory
        return DocumentReader(
            defuddleScript: { DefuddleBundle.live() },
            webKitOptions: LocalExtractor.liveOptions(environment: environment),
            unpackDirectory: URL(fileURLWithPath: cache, isDirectory: true).appending(path: "epub"))
    }

    static func read(_ url: URL) async throws -> LocalFile { try await live().read(url) }

    func read(_ url: URL) async throws -> LocalFile {
        guard let type = ReadableFileType.of(url), type != .plainText, type != .markdown else {
            return try await WebExtractor.readFile(url)
        }
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer {
            if gotAccess { url.stopAccessingSecurityScopedResource() }
        }
        let size = try Self.size(of: url, type: type)
        let limit = limits.bytes[type] ?? WebExtractor.maxFileBytes
        if size > limit { throw DocumentReadError.tooLarge(Self.formatName(type), size, limit) }
        try Task.checkCancellation()

        let content: (blocks: [MarkdownCleaner.Block], title: String?)
        switch type {
        case .html:
            content = try await readHTML(url)
        case .doc where AttributedTextReader.docContent(of: url) == .html:
            // A web page saved as .doc (office suites' and web sites' "Word" exports): the user's
            // own document, read whole by the system's HTML reader.
            content = try await readHTMLWithoutDefuddle(url, format: .doc)
        case .rtf, .rtfd, .doc, .docx, .odt:
            content = try AttributedTextReader.read(url, type: type)
        case .pdf:
            content = try PDFTextReader.read(url)
        case .epub:
            content = try await EPUBReader(limits: limits, unpackDirectory: unpackDirectory).read(url)
        case .plainText, .markdown:
            return try await WebExtractor.readFile(url)
        }
        try Task.checkCancellation()
        // A web page's notes and see-also sections are boilerplate; a document's own notes are not.
        let headings = type == .html ? MarkdownCleaner.boilerplateHeadings : MarkdownCleaner.citationHeadings
        let blocks = Self.finish(content.blocks, characterLimit: limits.characters, headings: headings)
        let title = content.title.flatMap(Self.plausibleTitle)
        let baseName = url.deletingPathExtension().lastPathComponent
        return LocalFile(title: title ?? baseName, titleFromMetadata: title != nil, fileName: url.lastPathComponent,
                         body: blocks.map(\.text).joined(separator: "\n\n"), isMarkdown: false, blocks: blocks)
    }

    /// The local Defuddle reads the file (its directory readable, no network, no page scripts);
    /// without it, or when it finds nothing, the system's HTML reader does.
    private func readHTML(_ url: URL) async throws -> (blocks: [MarkdownCleaner.Block], title: String?) {
        if let script = defuddleScript() {
            let options = webKitOptions
            var page: WebPage?
            do {
                page = try await LocalExtractor.read(fileURL: url, script: script, options: options)
            } catch LocalExtractorError.incomplete(let partial) {
                page = partial
            } catch {
                page = nil  // the system's HTML reader says what is wrong, if anything is
            }
            try Task.checkCancellation()
            if let page {
                let blocks = page.isPlainText ? PlainTextCleaner.blocks(page.markdown) : MarkdownCleaner.blocks(page.markdown)
                if !blocks.isEmpty { return (blocks, page.title) }
            }
        }
        return try await readHTMLWithoutDefuddle(url, format: .html)
    }

    /// The system's HTML reader, whose importer must run on the main thread, for a page of up to
    /// `AttributedTextReader.importerLimit` bytes; a larger one, which would hold the main thread
    /// for seconds (about one a megabyte), is read here by `AttributedTextReader.readLargeHTML`.
    private func readHTMLWithoutDefuddle(_ url: URL, format: ReadableFileType) async throws
        -> (blocks: [MarkdownCleaner.Block], title: String?) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DocumentReadError.unreadable(Self.formatName(format), error.localizedDescription)
        }
        let text = try TextDecoding.decode(data).text
        try Task.checkCancellation()
        if text.utf8.count > AttributedTextReader.importerLimit {
            return try AttributedTextReader.readLargeHTML(text, format: format)
        }
        return try await MainActor.run { try AttributedTextReader.readHTML(text, fileURL: url, format: format) }
    }

    // MARK: - Shared steps

    /// Inline clean-up as for plain text (citation markers, URLs, emoji …), blocks with nothing to
    /// say dropped, then the sections `headings` names (`MarkdownCleaner.dropBoilerplateSections`);
    /// at most `characterLimit` characters are kept.
    static func finish(_ raw: [MarkdownCleaner.Block], characterLimit: Int,
                       headings: Set<String> = MarkdownCleaner.boilerplateHeadings) -> [MarkdownCleaner.Block] {
        var kept: [MarkdownCleaner.Block] = []
        var total = 0
        for block in raw {
            total += block.text.count
            if total > characterLimit { break }
            kept.append(block)
        }
        let cleaned = MarkdownCleaner.Inline.clean(kept.map(\.text), references: [])
        let blocks = zip(kept, cleaned).compactMap { block, text in
            MarkdownCleaner.Inline.isSpeakable(text) ? MarkdownCleaner.Block(kind: block.kind, text: text) : nil
        }
        return MarkdownCleaner.dropBoilerplateSections(blocks, headings: headings)
    }

    /// A metadata title worth showing and reading: not empty, not a file name or a tool's
    /// placeholder ("Microsoft Word - draft.docx", "Untitled").
    static func plausibleTitle(_ raw: String) -> String? {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard MarkdownCleaner.Inline.isSpeakable(title), title.count <= 300 else { return nil }
        let lower = title.lowercased()
        let placeholders = ["untitled", "untitled document", "document", "title", "无标题", "未命名", "microsoft word"]
        if placeholders.contains(lower) || lower.hasPrefix("microsoft word - ") || lower.hasPrefix("microsoft powerpoint - ") {
            return nil
        }
        let fileExtensions = [".doc", ".docx", ".pdf", ".rtf", ".odt", ".txt", ".indd", ".tex", ".dvi", ".html", ".xhtml", ".epub"]
        if fileExtensions.contains(where: lower.hasSuffix) { return nil }
        return title
    }

    static func formatName(_ type: ReadableFileType) -> String {
        switch type {
        case .plainText: "text"
        case .markdown: "Markdown"
        case .html: "HTML"
        case .rtf: "RTF"
        case .rtfd: "RTFD"
        case .docx: "Word (.docx)"
        case .doc: "Word (.doc)"
        case .odt: "OpenDocument (.odt)"
        case .pdf: "PDF"
        case .epub: "EPUB"
        }
    }

    /// The file's size; an RTFD package's is the sum of its files.
    static func size(of url: URL, type: ReadableFileType) throws -> Int {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        } catch {
            throw DocumentReadError.unreadable(formatName(type), error.localizedDescription)
        }
        guard values.isDirectory == true else { return values.fileSize ?? 0 }
        var total = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let file = enumerator?.nextObject() as? URL {
            let fileValues = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if fileValues?.isRegularFile == true { total += fileValues?.fileSize ?? 0 }
        }
        return total
    }
}
