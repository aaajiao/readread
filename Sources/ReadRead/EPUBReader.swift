import Foundation

/// EPUB → blocks. The archive's central directory is checked first (entry count, unpacked size,
/// no absolute names, no "..", no links, no ZIP64, no encrypted entries); /usr/bin/ditto unpacks
/// it into a directory of its own under `unpackDirectory` (watched: it stops beyond the size
/// limit or after two minutes), the result is checked again, and the directory is removed when
/// the book is read. A book whose content is encrypted (DRM; font obfuscation is fine) is refused.
/// META-INF/container.xml names the package (OPF): its dc:title is the title, its spine the order
/// of the XHTML documents read (linear="no" items and the navigation document skipped). In each
/// document, `XHTMLBlockParser` keeps headings, paragraphs, list items and quotes, and skips the
/// head, scripts, styles, navigation, SVG, MathML, ruby annotations, and footnotes or endnotes and
/// their markers. The blocks still need `DocumentReader.finish`.
struct EPUBReader: Sendable {
    let limits: DocumentReader.Limits
    let unpackDirectory: URL
    /// The longest time ditto may take.
    var unpackLimit: Duration = .seconds(120)

    func read(_ url: URL) async throws -> (blocks: [MarkdownCleaner.Block], title: String?) {
        let entries: [ZipDirectory.Entry]
        do {
            entries = try ZipDirectory.entries(of: url, maximumEntries: limits.epubEntries)
        } catch let problem as ZipDirectory.Problem {
            throw DocumentReadError.invalidEPUB(problem.message)
        }
        try check(entries)
        removeStaleDirectories()
        let root = unpackDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw DocumentReadError.unreadable(DocumentReader.formatName(.epub), error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try await unpack(url, into: root)
        try verifyTree(root)
        if try isProtected(root) { throw DocumentReadError.drmProtected }
        let package = try packageDocument(root)
        var blocks: [MarkdownCleaner.Block] = []
        var characters = 0
        for document in package.spine {
            try Task.checkCancellation()
            let documentBlocks = try await XHTMLBlockParser.blocks(of: document)
            blocks += documentBlocks
            characters += documentBlocks.reduce(0) { $0 + $1.text.count }
            if characters > limits.characters { break }
        }
        return (blocks, package.title)
    }

    /// The central directory against the limits, before anything is written.
    func check(_ entries: [ZipDirectory.Entry]) throws {
        var total: UInt64 = 0
        for entry in entries {
            total += entry.uncompressedSize
            if entry.isEncrypted {
                throw DocumentReadError.invalidEPUB(String(localized: "its entries are encrypted", table: "Content"))
            }
            if entry.isSymlink {
                throw DocumentReadError.invalidEPUB(String(format: String(localized: "it holds a symbolic link: %@", table: "Content"), entry.name))
            }
            guard Self.isSafeName(entry.name) else {
                throw DocumentReadError.invalidEPUB(String(format: String(localized: "unsafe entry name: %@", table: "Content"), entry.name))
            }
        }
        if total > UInt64(limits.epubExpandedBytes) { throw DocumentReadError.unpackedTooLarge(limits.epubExpandedBytes) }
    }

    /// Relative, without "..", NUL, a drive letter or a backslash path.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 1024, !name.contains("\0"), !name.hasPrefix("/"), !name.hasPrefix("\\"),
              !name.contains("\\")
        else { return false }
        if name.count >= 2, name.dropFirst().first == ":" { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    /// Leftovers of a read that never finished (the app quit): directories older than an hour.
    func removeStaleDirectories() {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: unpackDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        for child in children where UUID(uuidString: child.lastPathComponent) != nil {
            let date = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, Date().timeIntervalSince(date) > 3600 { try? FileManager.default.removeItem(at: child) }
        }
    }

    /// /usr/bin/ditto without resource forks, extended attributes or quarantine; stopped when the
    /// directory grows past the limit, after `unpackLimit`, or when the task is cancelled.
    func unpack(_ archive: URL, into root: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl",
                             archive.path(percentEncoded: false), root.path(percentEncoded: false)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw DocumentReadError.unreadable(DocumentReader.formatName(.epub), error.localizedDescription)
        }
        let started = ContinuousClock.now
        var lastSizeCheck = started
        do {
            while process.isRunning {
                try await Task.sleep(for: .milliseconds(50))
                if ContinuousClock.now - started > unpackLimit {
                    throw DocumentReadError.invalidEPUB(String(localized: "unpacking it took longer than two minutes", table: "Content"))
                }
                if ContinuousClock.now - lastSizeCheck > .milliseconds(500) {
                    lastSizeCheck = .now
                    if Self.treeSize(root) > UInt64(limits.epubExpandedBytes) {
                        throw DocumentReadError.unpackedTooLarge(limits.epubExpandedBytes)
                    }
                }
            }
        } catch {
            process.terminate()
            process.waitUntilExit()
            throw error
        }
        guard process.terminationStatus == 0 else {
            throw DocumentReadError.invalidEPUB(
                String(format: String(localized: "ditto could not unpack it (status %d)", table: "Content"), process.terminationStatus))
        }
    }

    static func treeSize(_ root: URL) -> UInt64 {
        var total: UInt64 = 0
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        while let file = enumerator?.nextObject() as? URL {
            total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// No links, nothing outside `root`, within the size limit.
    func verifyTree(_ root: URL) throws {
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let inside = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .fileSizeKey]
        var total: UInt64 = 0
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys))
        while let file = enumerator?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true {
                throw DocumentReadError.invalidEPUB(String(localized: "it unpacked a symbolic link", table: "Content"))
            }
            guard file.standardizedFileURL.path(percentEncoded: false).hasPrefix(inside) else {
                throw DocumentReadError.invalidEPUB(String(localized: "it unpacked a file outside its directory", table: "Content"))
            }
            total += UInt64(values?.fileSize ?? 0)
        }
        if total > UInt64(limits.epubExpandedBytes) { throw DocumentReadError.unpackedTooLarge(limits.epubExpandedBytes) }
    }

    /// Font obfuscation only; anything else encrypted (Adobe, Readium LCP …) or FairPlay is DRM.
    static let fontObfuscation: Set<String> = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]

    func isProtected(_ root: URL) throws -> Bool {
        let metaInf = root.appending(path: "META-INF")
        if FileManager.default.fileExists(atPath: metaInf.appending(path: "sinf.xml").path(percentEncoded: false)) { return true }
        guard let data = try? Data(contentsOf: metaInf.appending(path: "encryption.xml")) else { return false }
        let algorithms = SimpleXML.elements(in: data).filter { $0.name == "EncryptionMethod" }.compactMap { $0.attributes["Algorithm"] }
        return algorithms.contains { !Self.fontObfuscation.contains($0) }
    }

    struct PackageDocument {
        var title: String?
        var spine: [URL]
    }

    /// container.xml → the OPF → its title and the documents of its spine, in order.
    func packageDocument(_ root: URL) throws -> PackageDocument {
        guard let container = try? Data(contentsOf: root.appending(path: "META-INF/container.xml")) else {
            throw DocumentReadError.invalidEPUB(String(localized: "META-INF/container.xml is missing", table: "Content"))
        }
        let rootFiles = SimpleXML.elements(in: container).filter { $0.name == "rootfile" }
        guard let path = (rootFiles.first { $0.attributes["media-type"] == "application/oebps-package+xml" } ?? rootFiles.first)?
                .attributes["full-path"],
              let opfURL = Self.resolve(path, against: root, root: root),
              let opf = try? Data(contentsOf: opfURL)
        else { throw DocumentReadError.invalidEPUB(String(localized: "the package document is missing", table: "Content")) }

        let elements = SimpleXML.elements(in: opf)
        let title = elements.first { $0.name == "title" && $0.namespace == "http://purl.org/dc/elements/1.1/" && !$0.text.isEmpty }?
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
        var manifest: [String: (href: String, type: String, properties: String)] = [:]
        for item in elements where item.name == "item" {
            guard let id = item.attributes["id"], let href = item.attributes["href"] else { continue }
            manifest[id] = (href, item.attributes["media-type"] ?? "", item.attributes["properties"] ?? "")
        }
        let base = opfURL.deletingLastPathComponent()
        var spine: [URL] = []
        var missing = 0
        for reference in elements where reference.name == "itemref" {
            guard reference.attributes["linear"]?.lowercased() != "no",
                  let id = reference.attributes["idref"], let item = manifest[id],
                  ["application/xhtml+xml", "text/html", "application/xml"].contains(item.type.lowercased()),
                  !item.properties.split(separator: " ").contains("nav")
            else { continue }
            guard let url = Self.resolve(item.href, against: base, root: root) else {
                missing += 1
                continue
            }
            if !spine.contains(url) { spine.append(url) }
        }
        guard !spine.isEmpty else {
            throw DocumentReadError.invalidEPUB(missing > 0
                ? String(localized: "none of the documents its spine lists are in the file", table: "Content")
                : String(localized: "its spine lists no documents", table: "Content"))
        }
        return PackageDocument(title: title, spine: spine)
    }

    /// A manifest href (percent-encoded, maybe with a fragment) as a file inside `root`, or nil.
    static func resolve(_ href: String, against base: URL, root: URL) -> URL? {
        let withoutFragment = String(href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard !withoutFragment.isEmpty, !withoutFragment.contains("://"),
              let path = withoutFragment.removingPercentEncoding else { return nil }
        let url = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard url.path(percentEncoded: false).hasPrefix(prefix),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return url
    }
}

// MARK: - ZIP central directory

/// The entries a ZIP archive's central directory lists (read, not unpacked).
enum ZipDirectory {
    struct Entry: Equatable, Sendable {
        var name: String
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var isSymlink: Bool
        var isEncrypted: Bool
    }

    struct Problem: Error, Equatable {
        let message: String
    }

    /// Larger central directories are not read (20,000 entries take about 2 MB).
    static let maximumDirectoryBytes = 32_000_000

    static func entries(of url: URL, maximumEntries: Int) throws -> [Entry] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Problem(message: error.localizedDescription)
        }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            guard size >= 22 else { throw Problem(message: String(localized: "it is not a ZIP archive", table: "Content")) }
            let tailLength = min(size, 22 + 65_535)
            try handle.seek(toOffset: size - tailLength)
            let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
            guard let end = endRecord(in: tail) else {
                throw Problem(message: String(localized: "it is not a ZIP archive", table: "Content"))
            }
            if end >= 20, u32(tail, end - 20) == 0x0706_4B50 {
                throw Problem(message: String(localized: "ZIP64 archives are not supported", table: "Content"))
            }
            let diskNumber = u16(tail, end + 4), directoryDisk = u16(tail, end + 6)
            let count = Int(u16(tail, end + 10))
            let directorySize = UInt64(u32(tail, end + 12)), directoryOffset = UInt64(u32(tail, end + 16))
            if diskNumber != 0 || directoryDisk != 0 {
                throw Problem(message: String(localized: "multi-part archives are not supported", table: "Content"))
            }
            if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
                throw Problem(message: String(localized: "ZIP64 archives are not supported", table: "Content"))
            }
            if count > maximumEntries {
                throw Problem(message: String(format: String(localized: "it has more than %lld entries", table: "Content"), maximumEntries))
            }
            guard directorySize <= UInt64(maximumDirectoryBytes), directoryOffset + directorySize <= size else {
                throw Problem(message: String(localized: "its central directory is damaged", table: "Content"))
            }
            try handle.seek(toOffset: directoryOffset)
            let directory = try handle.read(upToCount: Int(directorySize)) ?? Data()
            guard directory.count == Int(directorySize) else {
                throw Problem(message: String(localized: "its central directory is damaged", table: "Content"))
            }
            return try parse(directory, count: count)
        } catch let problem as Problem {
            throw problem
        } catch {
            throw Problem(message: error.localizedDescription)
        }
    }

    /// The end of central directory record, searched from the end (a comment may follow it).
    static func endRecord(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var index = data.count - 22
        while index >= 0 {
            if u32(data, index) == 0x0605_4B50 { return index }
            index -= 1
        }
        return nil
    }

    static func parse(_ directory: Data, count: Int) throws -> [Entry] {
        var entries: [Entry] = []
        var position = 0
        while entries.count < count {
            guard position + 46 <= directory.count, u32(directory, position) == 0x0201_4B50 else {
                throw Problem(message: String(localized: "its central directory is damaged", table: "Content"))
            }
            let madeBy = u16(directory, position + 4) >> 8
            let flags = u16(directory, position + 8)
            let compressed = UInt64(u32(directory, position + 20)), uncompressed = UInt64(u32(directory, position + 24))
            let nameLength = Int(u16(directory, position + 28))
            let extraLength = Int(u16(directory, position + 30)), commentLength = Int(u16(directory, position + 32))
            let external = u32(directory, position + 38)
            let nameStart = position + 46
            guard nameStart + nameLength + extraLength + commentLength <= directory.count else {
                throw Problem(message: String(localized: "its central directory is damaged", table: "Content"))
            }
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF {
                throw Problem(message: String(localized: "ZIP64 archives are not supported", table: "Content"))
            }
            let nameData = directory.subdata(in: directory.startIndex + nameStart..<directory.startIndex + nameStart + nameLength)
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            let mode = external >> 16
            let isUnix = madeBy == 3 || madeBy == 19
            entries.append(Entry(name: name, compressedSize: compressed, uncompressedSize: uncompressed,
                                 isSymlink: isUnix && (mode & 0xF000) == 0xA000, isEncrypted: flags & 1 != 0))
            position = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }
}

// MARK: - XML

/// Every element of a small XML document (container.xml, the OPF, encryption.xml): local name,
/// namespace, attributes (by qualified name and by local name) and its own text.
enum SimpleXML {
    struct Element {
        var name: String
        var namespace: String?
        var attributes: [String: String]
        var text: String
    }

    static func elements(in data: Data) -> [Element] {
        let parser = XMLParser(data: data)
        let collector = Collector()
        parser.delegate = collector
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return collector.elements
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var elements: [Element] = []
        var open: [Int] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            var attributes = attributeDict
            for (key, value) in attributeDict {
                if let colon = key.lastIndex(of: ":") { attributes[String(key[key.index(after: colon)...])] = value }
            }
            elements.append(Element(name: elementName, namespace: namespaceURI, attributes: attributes, text: ""))
            open.append(elements.count - 1)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = open.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if let index = open.last { elements[index].text += string }
        }
    }
}

/// One XHTML document → blocks (see `EPUBReader`); when it is not well-formed XML, libxml2's HTML
/// parser makes it so first (`blocks(ofHTML:format:)`, also for large HTML files).
final class XHTMLBlockParser: NSObject, XMLParserDelegate {
    static let skippedElements: Set<String> = [
        "head", "script", "style", "nav", "svg", "math", "rt", "rp", "noscript", "template", "button", "select", "textarea",
        "audio", "video", "object", "iframe",
    ]
    static let blockElements: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "section", "article", "header", "footer",
        "figure", "figcaption", "aside", "dd", "dt", "dl", "ul", "ol", "table", "thead", "tbody", "tfoot", "tr", "td", "th",
        "caption", "pre", "hr", "address", "main", "center", "details", "summary", "body", "html", "hgroup", "legend",
        "fieldset",
    ]
    /// epub:type and role values of notes, their references, and navigation lists.
    static let skippedTypes: Set<String> = [
        "footnote", "footnotes", "endnote", "endnotes", "rearnote", "rearnotes", "note", "noteref", "toc", "landmarks",
        "page-list", "pagebreak", "doc-footnote", "doc-endnote", "doc-endnotes", "doc-noteref", "doc-toc", "doc-pagelist",
        "doc-pagebreak", "doc-backlink",
    ]
    static let noteMarker = TextPattern(#"^[\[(]?(?:\d{1,3}|[*†‡§¶]{1,3}|[a-z])[\])]?$"#)

    private var blocks: [MarkdownCleaner.Block] = []
    private var stack: [String] = []
    private var skipDepth = 0
    private var text = ""
    private var preDepth = 0
    /// Open <sup> and <a href="#…"> elements: where their text starts, and whether they hold a link.
    private var markers: [(name: String, start: String.Index, hasLink: Bool)] = []

    static func blocks(of file: URL) async throws -> [MarkdownCleaner.Block] {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw DocumentReadError.unreadable(DocumentReader.formatName(.epub), error.localizedDescription)
        }
        let source = String(data: data, encoding: .utf8) ?? (try? TextDecoding.decode(data).text) ?? ""
        if let blocks = parse(Data(prepare(source).utf8)) { return blocks }
        // Not well-formed: through libxml2's HTML parser, here (not the importer: main thread).
        return try blocks(ofHTML: source, format: .epub)
    }

    /// The blocks of well-formed XHTML; nil when it is not well-formed.
    static func parse(_ data: Data) -> [MarkdownCleaner.Block]? {
        let parser = XMLParser(data: data)
        let delegate = XHTMLBlockParser()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        delegate.flush()
        return delegate.blocks
    }

    /// Any HTML, made well-formed by libxml2's HTML parser (`XMLDocument` with
    /// `.documentTidyHTML`, which closes what HTML leaves open), then read by `parse`. What
    /// would load something goes first (`AttributedTextReader.sanitizedHTML`: no meta charset
    /// either), and the text goes in as UTF-8 with a byte-order mark: nothing in the page can
    /// change its encoding. Nothing is loaded.
    static func blocks(ofHTML html: String, format: ReadableFileType) throws -> [MarkdownCleaner.Block] {
        let source = prepare(AttributedTextReader.sanitizedHTML(html))
        guard source.contains(where: { !$0.isWhitespace }) else { return [] }
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(source.utf8))
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        } catch {
            throw DocumentReadError.unreadable(DocumentReader.formatName(format), error.localizedDescription)
        }
        guard let blocks = parse(document.xmlData) else {
            throw DocumentReadError.unreadable(DocumentReader.formatName(format),
                                               String(localized: "its HTML could not be made well-formed", table: "Content"))
        }
        return blocks
    }

    static let xmlDeclaration = TextPattern(#"^\s*<\?xml[^>]*\?>"#)
    static let namedEntity = TextPattern(#"&([A-Za-z][A-Za-z0-9]{1,31});"#)
    static let xmlEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    /// UTF-8 without its declaration (the bytes are UTF-8 whatever it said), HTML's named entities
    /// as numeric references (XML knows only five).
    static func prepare(_ source: String) -> String {
        var text = source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source
        text = xmlDeclaration.replace(in: text, with: "")
        guard text.contains("&") else { return text }
        return namedEntity.replace(in: text) { groups in
            let name = groups[1]
            if xmlEntities.contains(name) { return groups[0] }
            guard let value = MarkdownCleaner.Inline.namedEntities[name] else { return " " }
            return value.unicodeScalars.map { "&#x\(String($0.value, radix: 16));" }.joined()
        }
    }

    private func isSkipped(_ name: String, _ attributes: [String: String]) -> Bool {
        if Self.skippedElements.contains(name) || attributes["hidden"] != nil || attributes["aria-hidden"] == "true" {
            return true
        }
        for (key, value) in attributes where key == "role" || key == "epub:type" || key.hasSuffix(":type") || key == "type" {
            if value.lowercased().split(separator: " ").contains(where: { Self.skippedTypes.contains(String($0)) }) {
                return true
            }
        }
        return false
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        if skipDepth > 0 || isSkipped(name, attributeDict) {
            skipDepth += 1
            return
        }
        if Self.blockElements.contains(name) { flush() }
        if name == "br" {
            while text.last == " " { text.removeLast() }
            if !text.isEmpty, text.last != "\n" { text.append("\n") }
        }
        if name == "pre" { preDepth += 1 }
        if name == "sup" { markers.append((name, text.endIndex, false)) }
        if name == "a", attributeDict["href"]?.hasPrefix("#") == true || attributeDict["href"]?.contains("#") == true {
            for index in markers.indices { markers[index].hasLink = true }
            markers.append((name, text.endIndex, true))
        }
        stack.append(name)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if skipDepth > 0 {
            skipDepth -= 1
            return
        }
        let name = elementName.lowercased()
        if name == "sup" || name == "a", let open = markers.lastIndex(where: { $0.name == name }) {
            let marker = markers.remove(at: open)
            if marker.start <= text.endIndex {
                let inner = text[marker.start...].trimmingCharacters(in: .whitespaces)
                // A note reference: a linked superscript, or a short marker like ¹ [2] * linked to the notes.
                if Self.noteMarker.matches(inner), marker.hasLink || name == "a" {
                    text.removeSubrange(marker.start...)
                }
            }
        }
        if Self.blockElements.contains(name) { flush() }
        if name == "pre" { preDepth = max(0, preDepth - 1) }
        if let index = stack.lastIndex(of: name) { stack.removeSubrange(index...) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        if preDepth > 0 {
            text += string
            return
        }
        for character in string {
            // XML white space only: U+3000 and no-break spaces are text.
            if character == " " || character == "\n" || character == "\t" || character == "\r" || character == "\r\n" {
                if let last = text.last, last != " ", last != "\n" { text.append(" ") }
            } else {
                text.append(character)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }

    /// The text so far as a block of the kind its innermost heading, list item or quote gives.
    func flush() {
        defer {
            text = ""
            markers.removeAll()
        }
        var value = Self.joinCJK(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard MarkdownCleaner.Inline.isSpeakable(value) else { return }
        var kind = MarkdownCleaner.Block.Kind.paragraph
        for name in stack.reversed() {
            if name.count == 2, name.hasPrefix("h"), let level = Int(name.dropFirst()), (1...6).contains(level) {
                kind = .heading(level)
                value = value.replacingOccurrences(of: "\n", with: " ")
                break
            }
            if name == "li" {
                kind = .listItem
                break
            }
            if name == "blockquote" {
                kind = .quote
                break
            }
        }
        blocks.append(MarkdownCleaner.Block(kind: kind, text: value))
    }

    /// A space the source's line wrapping left between two CJK characters goes.
    static func joinCJK(_ text: String) -> String {
        guard text.contains(" ") else { return text }
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for (index, character) in characters.enumerated() {
            if character == " ", index > 0, index + 1 < characters.count,
               MarkdownCleaner.Inline.isCJK(characters[index - 1].unicodeScalars.first),
               MarkdownCleaner.Inline.isCJK(characters[index + 1].unicodeScalars.first) {
                continue
            }
            result.append(character)
        }
        return result
    }
}
