import Foundation

/// Cleaned blocks → a `ReadingDocument`: the title first (R3-14), then every block's
/// sentences, each with the language its script census gives (R3-09).
enum DocumentBuilder {
    /// `keepsIndentedText`: pasted text, where an indented block is a paragraph, not code.
    static func fromMarkdown(
        _ markdown: String, title: String?, source: DocumentSource, sourceLabel: String, keepsIndentedText: Bool = false
    ) -> ReadingDocument {
        build(MarkdownCleaner.blocks(markdown, keepsIndentedText: keepsIndentedText), title: title, source: source,
              sourceLabel: sourceLabel)
    }

    static func fromPlainText(_ text: String, title: String?, source: DocumentSource, sourceLabel: String) -> ReadingDocument {
        build(PlainTextCleaner.blocks(text), title: title, source: source, sourceLabel: sourceLabel)
    }

    /// Longest header title derived from the text itself.
    static let derivedTitleLength = 80

    static func build(
        _ cleaned: [MarkdownCleaner.Block], title rawTitle: String?, source: DocumentSource, sourceLabel: String
    ) -> ReadingDocument {
        var blocks: [(kind: ReadingBlock.Kind, text: String)] = cleaned.map { (kind(of: $0.kind), $0.text) }
        let title = rawTitle.map(cleanTitle) ?? ""
        let documentTitle: String
        if !title.isEmpty {
            documentTitle = title
            // The title is read first, once: a first block that already is the title becomes it.
            if let first = blocks.first, first.kind != .listItem, comparable(first.text) == comparable(title) {
                blocks[0].kind = .title
            } else {
                blocks.insert((.title, title), at: 0)
            }
        } else if let first = blocks.first, first.kind == .heading {
            documentTitle = first.text
        } else {
            documentTitle = fallbackTitle(source: source, sourceLabel: sourceLabel, firstText: blocks.first?.text)
        }

        // Pieces and their verdicts; the document language from the decided ones.
        let pieces = blocks.map { SpeechChunker.pieces(of: $0.text) }
        let verdicts = pieces.map { $0.map { LanguageDetector.verdict($0.text) } }
        var weights: [(SpeechLanguage, Int)] = []
        for (blockPieces, blockVerdicts) in zip(pieces, verdicts) {
            for (piece, verdict) in zip(blockPieces, blockVerdicts) {
                switch verdict {
                case .zh: weights.append((.zh, piece.text.count))
                case .en: weights.append((.en, piece.text.count))
                case .mixed, .digitsOnly, .unsupported: break
                }
            }
        }
        let documentLanguage = LanguageDetector.documentLanguage(weights)

        var readingBlocks: [ReadingBlock] = []
        var units: [SpeechUnit] = []
        for (blockIndex, block) in blocks.enumerated() {
            let first = units.count
            let blockPieces = pieces[blockIndex]
            let kind: SpeechUnit.Kind = switch block.kind {
            case .title: .title
            case .heading: .heading
            case .paragraph, .listItem, .quote: .sentence
            }
            for (pieceIndex, piece) in blockPieces.enumerated() {
                let language = LanguageDetector.language(of: verdicts[blockIndex][pieceIndex], document: documentLanguage)
                let parts = parts(of: piece, language: language)
                for (partIndex, part) in parts.enumerated() {
                    var speakText = SpeechChunker.speechForm(part.piece.text)
                    if kind != .sentence, partIndex == parts.count - 1 {
                        speakText = SpeechChunker.withTerminalStop(speakText, language: part.language)
                    }
                    units.append(SpeechUnit(
                        id: units.count,
                        block: blockIndex,
                        range: part.piece.range,
                        speakText: SpeechChunker.clamp(speakText),
                        language: part.language,
                        kind: kind,
                        endsBlock: pieceIndex == blockPieces.count - 1 && partIndex == parts.count - 1
                    ))
                }
            }
            readingBlocks.append(ReadingBlock(kind: block.kind, text: block.text, units: first..<units.count))
        }
        return ReadingDocument(
            title: documentTitle,
            source: source,
            sourceLabel: sourceLabel,
            blocks: readingBlocks,
            units: units,
            detectedLanguage: documentLanguage
        )
    }

    /// A piece read in English never holds Han or kana: the en pipeline says "Chinese letter"
    /// for each (R3-09). Its CJK runs become units of their own, read in Chinese ("Lu Xun
    /// (Chinese: 鲁迅; …)"), or skipped when they are Japanese; the rest stays English.
    static func parts(of piece: SpeechChunker.Piece, language: SpeechLanguage?)
        -> [(piece: SpeechChunker.Piece, language: SpeechLanguage?)] {
        guard language == .en, LanguageDetector.hasCJKLetters(piece.text) else { return [(piece, language)] }
        return SpeechChunker.scriptRuns(of: piece).map { run, isCJK in
            let verdict = LanguageDetector.verdict(run.text)
            if isCJK { return (run, verdict == .unsupported ? nil : .zh) }
            return (run, LanguageDetector.language(of: verdict, document: .en))
        }
    }

    static func kind(of kind: MarkdownCleaner.Block.Kind) -> ReadingBlock.Kind {
        switch kind {
        case .heading: .heading
        case .paragraph: .paragraph
        case .listItem: .listItem
        case .quote: .quote
        }
    }

    /// Titles get the same inline clean-up as the text (entities, emoji, markup) on one line.
    static func cleanTitle(_ title: String) -> String {
        let cleaned = MarkdownCleaner.Inline.clean([title.replacingOccurrences(of: "\n", with: " ")], references: [])
        return (cleaned.first ?? "").replacingOccurrences(of: "\n", with: " ")
    }

    /// Lowercased letters and digits only, for "the body already starts with the title".
    static func comparable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }))
    }

    /// A header title when the source has none (it is shown, never read): the file name,
    /// the host, or the start of the text.
    static func fallbackTitle(source: DocumentSource, sourceLabel: String, firstText: String?) -> String {
        switch source {
        case .file(let url):
            let name = url.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        case .url(let url):
            if let host = url.host(), !host.isEmpty { return host }
        case .text:
            break
        }
        guard let firstText, !firstText.isEmpty else { return sourceLabel.isEmpty ? "Untitled" : sourceLabel }
        let line = firstText.split(separator: "\n").first.map(String.init) ?? firstText
        return line.count > derivedTitleLength ? String(line.prefix(derivedTitleLength)) + "…" : line
    }
}
