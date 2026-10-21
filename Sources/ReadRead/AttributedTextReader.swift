import AppKit

/// RTF, RTFD, Word (.doc, .docx), OpenDocument (.odt) and, as a fallback, HTML → blocks, through
/// `NSAttributedString`. A paragraph is a block: a list item when it is in a text list (its marker
/// dropped), a heading when its style says so or its font is clearly larger than the body's (or it
/// is short and all bold), else a paragraph. Attachments (images) are dropped; table cells are
/// paragraphs. The blocks still need `DocumentReader.finish`.
enum AttributedTextReader {
    static func documentType(for type: ReadableFileType) -> NSAttributedString.DocumentType? {
        switch type {
        case .rtf: .rtf
        case .rtfd: .rtfd
        case .doc: .docFormat
        case .docx: .officeOpenXML
        case .odt: .openDocument
        case .html: .html
        case .plainText, .markdown, .pdf, .epub: nil
        }
    }

    /// What a .doc file holds: Word 97–2003 (an OLE2 compound file), or what office suites and
    /// web sites also save under that name: RTF, HTML, a .docx (ZIP), Word 2003 XML.
    enum DocContent: Equatable {
        case word
        case rtf
        case html
        case officeOpenXML
        case wordML
        /// Something else: the importer decides.
        case unknown
    }

    static func docContent(of url: URL) -> DocContent {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        return docContent((try? handle.read(upToCount: 4_096)) ?? Data())
    }

    /// By the first bytes: the OLE2 and ZIP signatures, or the text after a byte-order mark and
    /// white space ("{\rtf", "<?xml" with WordML's namespace, "<").
    static func docContent(_ head: Data) -> DocContent {
        let bytes = [UInt8](head)
        if bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return .word }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .officeOpenXML }
        var text: String
        if let (bom, encoding, _) = TextDecoding.byteOrderMark(of: head), encoding != .utf8 {
            let body = head.dropFirst(bom)
            text = String(data: body.prefix(body.count & ~3), encoding: encoding) ?? ""
        } else {
            text = String(decoding: bytes, as: UTF8.self)
        }
        text = String(text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }.prefix(4_096)).lowercased()
        if text.hasPrefix("{\\rtf") { return .rtf }
        if text.hasPrefix("<?xml") {
            if text.contains("w:worddocument") || text.contains("schemas.microsoft.com/office/word/2003/wordml") { return .wordML }
            return text.contains("<html") ? .html : .unknown
        }
        return text.hasPrefix("<") ? .html : .unknown
    }

    /// Any of the formats but HTML (whose importer must run on the main thread: `readHTML`). A
    /// .doc is read as what it holds (`docContent`; HTML goes through `DocumentReader`'s HTML
    /// reader, something unknown to the importer's own guess).
    static func read(_ url: URL, type: ReadableFileType) throws -> (blocks: [MarkdownCleaner.Block], title: String?) {
        guard let documentType = documentType(for: type), type != .html else {
            throw DocumentReadError.unreadable(DocumentReader.formatName(type), String(localized: "not a text document format", table: "Content"))
        }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: documentType]
        if type == .doc {
            switch docContent(of: url) {
            case .word: break
            case .rtf: options[.documentType] = NSAttributedString.DocumentType.rtf
            case .officeOpenXML: options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
            case .wordML: options[.documentType] = NSAttributedString.DocumentType.wordML
            case .html: break  // DocumentReader reads it as HTML (that importer must run on the main thread)
            case .unknown: options[.documentType] = nil
            }
        }
        var attributes: NSDictionary?
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(url: url, options: options, documentAttributes: &attributes)
        } catch {
            throw DocumentReadError.unreadable(DocumentReader.formatName(type), error.localizedDescription)
        }
        let title = (attributes?[NSAttributedString.DocumentAttributeKey.title] as? String)
            ?? (attributes?[NSAttributedString.DocumentAttributeKey.title.rawValue] as? String)
        return (blocks(attributed), title)
    }

    /// HTML without Defuddle: elements that would load something (scripts, images, frames, style
    /// sheets …) are removed first, and the importer may read only the file's directory. Up to
    /// `importerLimit` bytes: larger HTML is for `readLargeHTML`.
    @MainActor
    static func readHTML(_ html: String, fileURL: URL, format: ReadableFileType = .html) throws
        -> (blocks: [MarkdownCleaner.Block], title: String?) {
        let cleaned = sanitizedHTML(html)
        var attributes: NSDictionary?
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(
                data: Data(cleaned.utf8),
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                    .readAccessURL: fileURL.deletingLastPathComponent(),
                    .timeout: 10,
                ],
                documentAttributes: &attributes)
        } catch {
            throw DocumentReadError.unreadable(DocumentReader.formatName(format), error.localizedDescription)
        }
        let title = self.title(of: html, documentTitle: attributes?[NSAttributedString.DocumentAttributeKey.title] as? String)
        return (blocks(attributed), title)
    }

    /// Above this many bytes (UTF-8) HTML does not go to the importer, which holds the main
    /// thread about a second a megabyte (a 9.6 MB page: 9 s).
    static let importerLimit = 256 * 1024

    /// HTML too large for the importer, read on the caller's thread: libxml2's HTML parser
    /// (`XMLDocument`'s `.documentTidyHTML`) makes it well-formed and `XHTMLBlockParser` reads it
    /// as it reads an EPUB chapter (headings, paragraphs, list items and quotes by their elements).
    static func readLargeHTML(_ html: String, format: ReadableFileType = .html) throws -> (blocks: [MarkdownCleaner.Block], title: String?) {
        (try XHTMLBlockParser.blocks(ofHTML: html, format: format), title(of: html, documentTitle: nil))
    }

    /// The document's title (the importer's, else the `<title>` element), without the site's name
    /// ("Article – Site": Defuddle would drop it too).
    static func title(of html: String, documentTitle: String?) -> String? {
        var title = documentTitle
        if title == nil, let match = html.range(of: #"(?is)<title[^>]*>(.*?)</title\s*>"#, options: .regularExpression) {
            let inner = html[match].replacingOccurrences(of: #"(?is)</?title[^>]*>"#, with: "", options: .regularExpression)
            title = MarkdownCleaner.Inline.decodeEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let site = siteName(html), let full = title { title = WebExtractor.stripSiteSuffix(full, site: site) }
        return title
    }

    static let metaTag = TextPattern(#"<meta\s[^>]*>"#, [.caseInsensitive])
    static let siteProperty = TextPattern(#"(?:property|name)\s*=\s*["']?(?:og:site_name|application-name)\b"#, [.caseInsensitive])
    static let contentAttribute = TextPattern(#"\bcontent\s*=\s*(?:"([^"]*)"|'([^']*)')"#, [.caseInsensitive])

    /// The page's og:site_name (or application-name) meta value.
    static func siteName(_ html: String) -> String? {
        let source = html as NSString
        for match in metaTag.regex.matches(in: html, range: NSRange(location: 0, length: min(source.length, 200_000))) {
            let tag = source.substring(with: match.range)
            guard siteProperty.matches(tag), let groups = contentAttribute.firstMatch(in: tag) else { continue }
            let value = MarkdownCleaner.Inline.decodeEntities(groups[1].isEmpty ? groups[2] : groups[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    static let removedElements = TextPattern(
        #"<(script|style|iframe|object|embed|video|audio|picture|svg|math|template|noscript|canvas|frameset|head)\b[^>]*>.*?</\1\s*>"#,
        [.caseInsensitive, .dotMatchesLineSeparators])
    static let removedTags = TextPattern(
        #"<(?:img|link|source|track|embed|input|base|meta|frame|area|param|object|iframe|script|style|video|audio)\b[^>]*>"#,
        [.caseInsensitive])
    static let loadingAttributes = TextPattern(
        #"\s(?:style|src|srcset|background|poster|data|lowsrc|dynsrc|longdesc|xlink:href|formaction|action)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#,
        [.caseInsensitive])

    /// The page's text and structure, nothing that loads.
    static func sanitizedHTML(_ html: String) -> String {
        var text = removedElements.replace(in: html, with: "")
        text = removedTags.replace(in: text, with: "")
        return loadingAttributes.replace(in: text, with: "")
    }

    // MARK: - Blocks

    static let listMarker = TextPattern(
        #"^[\t ]*(?:(?:[•◦▪▫‣⁃●○■□◆◇–—*+\x{F0B7}\x{F0A7}-]|\(?[0-9]{1,3}[.)、]|\(?[a-zA-Z][.)]|\(?[ivxlcdmIVXLCDM]{1,6}[.)])[\t \x{00A0}]+|[0-9]{1,3}\t+)"#)
    /// Word's lists come without text lists: "\t•\tItem", "\t1.\tItem".
    static let tabbedListMarker = TextPattern(
        #"^[\t ]*(?:[•◦▪▫‣⁃●○■□◆◇–—*+\x{F0B7}\x{F0A7}-]|\(?[0-9]{1,3}[.)、]?|\(?[a-zA-Z][.)]|\(?[ivxlcdmIVXLCDM]{1,6}[.)])\t"#)
    static let sentenceEnds: Set<Character> = [".", "。", "!", "！", "?", "？", ";", "；", ",", "，", "、", ":", "："]

    static func blocks(_ attributed: NSAttributedString) -> [MarkdownCleaner.Block] {
        let string = attributed.string as NSString
        let whole = NSRange(location: 0, length: string.length)
        guard whole.length > 0 else { return [] }
        // The body size: the font size most characters have.
        var sizes: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? NSFont else { return }
            sizes[(font.pointSize * 2).rounded() / 2, default: 0] += range.length
        }
        let bodySize = sizes.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 12

        var result: [MarkdownCleaner.Block] = []
        string.enumerateSubstrings(in: whole, options: [.byParagraphs]) { substring, range, _, _ in
            guard let substring else { return }
            var text = substring.replacingOccurrences(of: "\u{FFFC}", with: "")
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\u{0C}", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard MarkdownCleaner.Inline.isSpeakable(text) else { return }
            let style = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            if (style.map { !$0.textLists.isEmpty } ?? false) || tabbedListMarker.matches(text) {
                text = listMarker.replace(in: text, with: "")
                result.append(MarkdownCleaner.Block(kind: .listItem, text: text))
                return
            }
            if let level = headingLevel(text, range: range, style: style, in: attributed, bodySize: bodySize) {
                result.append(MarkdownCleaner.Block(kind: .heading(level), text: text.replacingOccurrences(of: "\n", with: " ")))
            } else {
                result.append(MarkdownCleaner.Block(kind: .paragraph, text: text))
            }
        }
        return result
    }

    /// 1–3 by the size of its font against the body's, 4 for a short all-bold line; nil for a
    /// paragraph (also when long, several lines, or ending like a sentence).
    static func headingLevel(_ text: String, range: NSRange, style: NSParagraphStyle?, in attributed: NSAttributedString,
                             bodySize: CGFloat) -> Int? {
        if let level = style?.headerLevel, level > 0 { return min(level, 6) }
        guard text.count <= 120, !text.contains("\n"), let last = text.last, !sentenceEnds.contains(last) else { return nil }
        var smallest = CGFloat.greatestFiniteMagnitude
        var allBold = true
        attributed.enumerateAttribute(.font, in: range) { value, run, _ in
            let runText = (attributed.string as NSString).substring(with: run)
            guard runText.contains(where: { !$0.isWhitespace }) else { return }
            guard let font = value as? NSFont else {
                allBold = false
                return
            }
            smallest = min(smallest, font.pointSize)
            if !font.fontDescriptor.symbolicTraits.contains(.bold) { allBold = false }
        }
        guard smallest < .greatestFiniteMagnitude else { return nil }
        let ratio = smallest / max(bodySize, 1)
        if ratio >= 1.7 { return 1 }
        if ratio >= 1.4 { return 2 }
        if ratio >= 1.15 { return 3 }
        if allBold, ratio >= 0.95, text.count <= 80 { return 4 }
        return nil
    }
}
