import Foundation

/// Plain text (.txt files, pasted text) → display blocks (R3-03 app side). A blank line
/// separates paragraphs. A single newline is a paragraph break too (a Chinese novel with
/// one paragraph per line), except a soft wrap, joined with a space (or with nothing
/// between CJK characters): the next line is not indented and the line is long without
/// closing punctuation, or, in a hard-wrapped text (see `wrapColumn`), a Latin-script line
/// near the wrap column whatever it ends with. Footnote and citation markers, emoji and
/// separators are handled as in Markdown. Expects LF newlines.
enum PlainTextCleaner {
    /// A line at least this wide (CJK characters count 2) that ends without closing
    /// punctuation is taken to be wrapped.
    static let wrapWidth = 40

    /// Characters that end a line on purpose: sentence ends, closing quotes and brackets, colons.
    static let lineEnds: Set<Character> = [
        ".", "!", "?", "。", "！", "？", "…", "”", "\"", "’", "」", "』", ":", "：", ";", "；", ")", "）", "】", "》",
    ]

    static func blocks(_ text: String) -> [MarkdownCleaner.Block] {
        let normalized = TextDecoding.normalizeNewlines(text)
            .replacingOccurrences(of: "\u{2029}", with: "\n\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
        let paragraphs = self.paragraphs(normalized)
        let cleaned = MarkdownCleaner.Inline.clean(paragraphs.map(\.text), references: [])
        return zip(paragraphs, cleaned).compactMap { paragraph, text in
            MarkdownCleaner.Inline.isSpeakable(text) ? MarkdownCleaner.Block(kind: paragraph.kind, text: text) : nil
        }
    }

    struct Paragraph {
        let kind: MarkdownCleaner.Block.Kind
        let text: String
    }

    static func paragraphs(_ text: String) -> [Paragraph] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let column = wrapColumn(lines)
        var result: [Paragraph] = []
        var current = ""
        var currentKind = MarkdownCleaner.Block.Kind.paragraph
        var previousLine: Substring = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { result.append(Paragraph(kind: currentKind, text: trimmed)) }
            current = ""
            currentKind = .paragraph
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: indentation)
            if line.isEmpty {
                flush()
                previousLine = ""
                continue
            }
            let item = bulletItem(line)
            if current.isEmpty || item != nil {
                flush()
            } else {
                let indented = raw.first.map { indentation.contains($0.unicodeScalars.first!) } ?? false
                let previous = previousLine.trimmingCharacters(in: indentation)
                let softWrap = !indented && runsOn(previous, column: column)
                if softWrap {
                    let joinsCJK = MarkdownCleaner.Inline.isCJK(current.unicodeScalars.last)
                        && MarkdownCleaner.Inline.isCJK(line.unicodeScalars.first)
                    current += current.hasSuffix("-") || joinsCJK ? "" : " "
                    current += line
                    previousLine = raw
                    continue
                }
                flush()
            }
            if let item {
                currentKind = .listItem
                current = item
            } else {
                current = line
            }
            previousLine = raw
        }
        flush()
        return result
    }

    private static let indentation = CharacterSet(charactersIn: " \t\u{3000}")

    /// Whether `line` was wrapped into the next one.
    static func runsOn(_ line: String, column: Int?) -> Bool {
        let lineWidth = width(line)
        let endsOnPurpose = line.last.map { lineEnds.contains($0) } ?? true
        if let column, lineWidth * 10 >= column * 7, !endsOnPurpose || !isMostlyCJK(line) {
            return true
        }
        return lineWidth >= wrapWidth && !endsOnPurpose
    }

    /// The column a hard-wrapped text was wrapped at: blank lines separate its paragraphs
    /// and most lines end near the same width. nil for a paragraph per line (their widths
    /// vary), for short lines and for wraps wider than any editor's.
    static func wrapColumn(_ lines: [Substring]) -> Int? {
        var widths: [Int] = []
        var blankLines = 0
        for line in lines {
            let lineWidth = width(line.trimmingCharacters(in: indentation))
            if lineWidth == 0 { blankLines += 1 } else { widths.append(lineWidth) }
        }
        guard widths.count >= 8, blankLines > 0 else { return nil }
        let column = widths.sorted()[(widths.count - 1) * 9 / 10]
        guard (wrapWidth...200).contains(column) else { return nil }
        let near = widths.filter { $0 * 10 >= column * 7 && $0 * 10 <= column * 11 }.count
        return near * 2 >= widths.count ? column : nil
    }

    /// CJK text wraps anywhere, a sentence end at the wrap column included, but a line of a
    /// one-paragraph-per-line novel ends on purpose; only its closing punctuation tells.
    static func isMostlyCJK(_ line: String) -> Bool {
        let census = LanguageDetector.census(line)
        return census.han + census.kana > census.latin
    }

    /// "• text", "- text", "* text" at the start of a line: a list item's text.
    static func bulletItem(_ line: String) -> String? {
        guard let first = line.first, "•·‣◦▪-*".contains(first) else { return nil }
        let rest = line.dropFirst()
        guard let space = rest.first, space == " " || space == "\t" else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Display width: CJK characters count 2.
    static func width<S: StringProtocol>(_ text: S) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (MarkdownCleaner.Inline.isCJK($1) ? 2 : 1) }
    }
}
