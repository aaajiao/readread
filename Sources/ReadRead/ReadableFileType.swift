import Foundation
import UniformTypeIdentifiers

// Shared by the UI (file picker, drag and drop, "Open With") and the loader (milestone v0.4.0).

/// The file formats ReadRead opens. build-app.sh declares the same identifiers in
/// CFBundleDocumentTypes (rank Alternate: listed under Open With, never the default app).
enum ReadableFileType: String, CaseIterable, Sendable {
    case plainText
    case markdown
    case html
    case rtf
    case rtfd
    case docx
    case doc
    case odt
    case pdf
    case epub

    /// Lowercased file name extensions, the usual one first.
    var extensions: [String] {
        switch self {
        case .plainText: ["txt", "text"]
        case .markdown: ["md", "markdown", "mdown", "mkd"]
        case .html: ["html", "htm", "xhtml"]
        case .rtf: ["rtf"]
        case .rtfd: ["rtfd"]
        case .docx: ["docx"]
        case .doc: ["doc"]
        case .odt: ["odt"]
        case .pdf: ["pdf"]
        case .epub: ["epub"]
        }
    }

    /// The type identifier (LSItemContentTypes in the Info.plist).
    var identifier: String {
        switch self {
        case .plainText: "public.plain-text"
        case .markdown: "net.daringfireball.markdown"
        case .html: "public.html"
        case .rtf: "public.rtf"
        case .rtfd: "com.apple.rtfd"
        case .docx: "org.openxmlformats.wordprocessingml.document"
        case .doc: "com.microsoft.word.doc"
        case .odt: "org.oasis-open.opendocument.text"
        case .pdf: "com.adobe.pdf"
        case .epub: "org.idpf.epub-container"
        }
    }

    /// For pickers and drops: the declared type, else the one its usual extension maps to.
    var utType: UTType {
        UTType(identifier) ?? UTType(filenameExtension: extensions[0]) ?? .data
    }

    static var utTypes: [UTType] { allCases.map(\.utType) }

    /// The format of `url` by its extension; another extension whose type conforms to
    /// public.plain-text (.log, .csv, .srt …) is plain text; nil = not readable.
    static func of(_ url: URL) -> ReadableFileType? {
        let pathExtension = url.pathExtension.lowercased()
        if let match = allCases.first(where: { $0.extensions.contains(pathExtension) }) { return match }
        if !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension), type.conforms(to: .plainText) {
            return .plainText
        }
        return nil
    }
}

/// How web pages are read (Settings; the loader reads it at each load).
enum ExtractionMode: String, CaseIterable, Sendable {
    /// In ReadRead: an offscreen web view runs the bundled Defuddle; defuddle.md when that fails.
    case localFirst = "local"
    /// defuddle.md only (pages on the local network are still read locally: it cannot reach them).
    case remoteOnly = "remote"

    static let defaultsKey = "extraction_mode"

    /// The stored mode, local first by default; `value` reads a key (UserDefaults.standard, from
    /// any thread; tests read a dictionary instead of a persistent domain).
    static func current(_ value: (String) -> String? = { UserDefaults.standard.string(forKey: $0) }) -> ExtractionMode {
        value(defaultsKey).flatMap(ExtractionMode.init(rawValue:)) ?? .localFirst
    }
}
