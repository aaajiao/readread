import CryptoKit
import Foundation

// Shared reading model (milestone v0.3.0). The text pipeline (DocumentBuilder) produces a
// ReadingDocument; the playback side (PlaybackController) reads its units one by one.

/// Where a document came from: the header label and the key for the saved reading position.
enum DocumentSource: Sendable, Equatable, Hashable {
    case url(URL)
    case file(URL)
    /// Pasted or dropped text.
    case text
}

/// The user's language choice for a document. `.auto` reads every unit in its own detected
/// language; `.zh` / `.en` read every unit with that language's pipeline and voice.
enum LanguageChoice: String, Sendable, Equatable, CaseIterable, Codable {
    case auto
    case zh
    case en

    var fixedLanguage: SpeechLanguage? {
        switch self {
        case .auto: nil
        case .zh: .zh
        case .en: .en
        }
    }
}

/// What the reading view shows as one paragraph-like element.
struct ReadingBlock: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case title
        case heading
        case paragraph
        case listItem
        case quote
    }

    let kind: Kind
    /// Display text, markup removed.
    let text: String
    /// Indices into `ReadingDocument.units` of this block's units (empty when nothing in the
    /// block is speakable).
    let units: Range<Int>
}

/// One request to the speech engine and one audio buffer for the player.
struct SpeechUnit: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable, Equatable {
        case title
        case heading
        case sentence
    }

    /// Index in `ReadingDocument.units`.
    let id: Int
    /// Index in `ReadingDocument.blocks`.
    let block: Int
    /// This unit's span of its block's `text`, in Character offsets (for highlighting).
    let range: Range<Int>
    /// What is sent to the engine; may differ from the displayed span.
    let speakText: String
    /// The unit's own language from the script census; nil = a script ReadRead does not read
    /// (shown, skipped by the player).
    let language: SpeechLanguage?
    let kind: Kind
    /// The last unit of its block.
    let endsBlock: Bool

    /// Silence the player leaves after this unit, in seconds.
    var pauseAfter: Double {
        kind != .sentence || endsBlock ? 0.5 : 0.25
    }

    /// The language this unit is read in under `choice`; nil = skipped.
    func language(under choice: LanguageChoice) -> SpeechLanguage? {
        guard let language else { return nil }
        return choice.fixedLanguage ?? language
    }
}

struct ReadingDocument: Sendable, Equatable {
    let title: String
    let source: DocumentSource
    /// Domain or file name for the header; empty for pasted text.
    let sourceLabel: String
    let blocks: [ReadingBlock]
    let units: [SpeechUnit]
    /// Character-weighted majority of the units' languages (zh when there is none).
    let detectedLanguage: SpeechLanguage
    /// sha256 (lowercase hex) of the units' speak texts joined by "\n". A saved position is
    /// only restored while it matches.
    let contentHash: String

    init(
        title: String,
        source: DocumentSource,
        sourceLabel: String,
        blocks: [ReadingBlock],
        units: [SpeechUnit],
        detectedLanguage: SpeechLanguage
    ) {
        self.title = title
        self.source = source
        self.sourceLabel = sourceLabel
        self.blocks = blocks
        self.units = units
        self.detectedLanguage = detectedLanguage
        self.contentHash = Self.hash(of: units)
    }

    /// Nothing the player would read.
    var isEmpty: Bool { !units.contains { $0.language != nil } }

    /// The document language under `choice`: the voice picker offers this language's voices.
    func language(under choice: LanguageChoice) -> SpeechLanguage {
        choice.fixedLanguage ?? detectedLanguage
    }

    /// The text a unit shows (its span of its block).
    func displayText(of unit: SpeechUnit) -> String {
        let text = blocks[unit.block].text
        let start = text.index(text.startIndex, offsetBy: unit.range.lowerBound, limitedBy: text.endIndex)
            ?? text.endIndex
        let end = text.index(start, offsetBy: unit.range.count, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }

    /// Key for the saved reading position: the URL without its fragment, the standardized file
    /// path, or "text:" plus the content hash.
    var positionKey: String {
        switch source {
        case .url(let url):
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return "url:" + (components?.string ?? url.absoluteString)
        case .file(let url):
            return "file:" + url.standardizedFileURL.path(percentEncoded: false)
        case .text:
            return "text:" + contentHash
        }
    }

    static func hash(of units: [SpeechUnit]) -> String {
        let joined = units.map(\.speakText).joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
