import Foundation
import PDFKit

/// PDF → blocks, from PDFKit's text lines and their positions. Running headers and footers (the
/// same top or bottom line on at least 40% of the pages and three of them, or on both pages of
/// two, digits aside) and page numbers go; lines join into paragraphs (a paragraph ends at a
/// larger gap, a first-line indent, a change of font size, a short line or a list marker, and runs
/// on across a page break when its last line does not end it), words hyphenated at a line end are
/// joined (a compound's hyphen stays: "text-" + "to-speech"), CJK lines join without a space.
/// A page in columns (`columns`) measures each line against its own column, and a paragraph runs
/// on from the foot of one column to the top of the next unless it ended there. Single lines in a
/// clearly larger font are headings. A locked PDF throws `passwordProtected`; one without any text
/// (a scan) throws `noTextLayer`. The blocks still need `DocumentReader.finish`.
enum PDFTextReader {
    struct Line: Equatable {
        var text: String
        var rect: CGRect
        var page: Int
    }

    static func read(_ url: URL) throws -> (blocks: [MarkdownCleaner.Block], title: String?) {
        guard let document = PDFDocument(url: url) else {
            throw DocumentReadError.unreadable(DocumentReader.formatName(.pdf), String(localized: "PDFKit cannot open it", table: "Content"))
        }
        if document.isLocked, !document.unlock(withPassword: "") { throw DocumentReadError.passwordProtected }
        var pages: [[Line]] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            pages.append(lines(of: page, index: index))
        }
        let blocks = paragraphs(withoutRunningLines(pages))
        guard !blocks.isEmpty else { throw DocumentReadError.noTextLayer }
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return (blocks, title)
    }

    /// The page's text lines in reading order, as PDFKit finds them.
    static func lines(of page: PDFPage, index: Int) -> [Line] {
        guard let selection = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
        var result: [Line] = []
        for line in selection.selectionsByLine() {
            let rect = line.bounds(for: page)
            for part in (line.string ?? "").split(whereSeparator: \.isNewline) {
                let text = normalize(String(part))
                if !text.isEmpty { result.append(Line(text: text, rect: rect, page: index)) }
            }
        }
        return result
    }

    static let ligatures: [Character: String] = [
        "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi", "\u{FB04}": "ffl", "\u{FB05}": "st", "\u{FB06}": "st",
    ]

    static func normalize(_ text: String) -> String {
        var result = ""
        for character in TextDecoding.sanitize(text) {
            if let replacement = ligatures[character] { result += replacement } else { result.append(character) }
        }
        return MarkdownCleaner.Inline.spaceRun.replace(in: result, with: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Running headers, footers, page numbers

    static let pageNumber = TextPattern(
        #"^(?:(?:page|p\.|pp\.)\s*)?[-–—(\[]?\s*\d{1,4}\s*[-–—)\]]?(?:\s*(?:/|of|von|sur)\s*\d{1,4})?$|^[ivxlcdm]{1,7}$|^第\s*[\d一二三四五六七八九十百千零〇]{1,6}\s*页(?:\s*[,，/、]?\s*共\s*\d{1,5}\s*页)?$|^\d{1,4}\s*/\s*\d{1,4}$"#,
        [.caseInsensitive])

    /// A header or footer compared without its numbers: "Chapter 3 · 12" and "Chapter 3 · 13" match.
    static func runningKey(_ text: String) -> String {
        String(text.lowercased().map { $0.isNumber ? "#" : $0 }.filter { !$0.isWhitespace })
    }

    /// The top and bottom two lines of a page, by position.
    static func edgeIndices(_ lines: [Line]) -> (top: [Int], bottom: [Int]) {
        guard !lines.isEmpty else { return ([], []) }
        let byHeight = lines.indices.sorted { lines[$0].rect.midY > lines[$1].rect.midY }
        let count = min(2, lines.count)
        return (Array(byHeight.prefix(count)), Array(byHeight.suffix(count)))
    }

    static func withoutRunningLines(_ pages: [[Line]]) -> [[Line]] {
        let pagesWithText = pages.filter { !$0.isEmpty }.count
        // Both pages of a two-page document; else at least three pages and 40% of them.
        let threshold = pagesWithText == 2 ? 2 : max(3, Int((Double(pagesWithText) * 0.4).rounded(.up)))
        var topCounts: [String: Int] = [:]
        var bottomCounts: [String: Int] = [:]
        for lines in pages {
            let edges = edgeIndices(lines)
            for key in Set(edges.top.map { runningKey(lines[$0].text) }) { topCounts[key, default: 0] += 1 }
            for key in Set(edges.bottom.map { runningKey(lines[$0].text) }) { bottomCounts[key, default: 0] += 1 }
        }
        return pages.map { lines in
            let edges = edgeIndices(lines)
            var dropped = Set<Int>()
            for index in edges.top where pageNumber.matches(lines[index].text)
                || (pagesWithText >= 2 && topCounts[runningKey(lines[index].text), default: 0] >= threshold) {
                dropped.insert(index)
            }
            for index in edges.bottom where pageNumber.matches(lines[index].text)
                || (pagesWithText >= 2 && bottomCounts[runningKey(lines[index].text), default: 0] >= threshold) {
                dropped.insert(index)
            }
            return lines.indices.filter { !dropped.contains($0) }.map { lines[$0] }
        }
    }

    // MARK: - Paragraphs

    static let listMarker = TextPattern(#"^(?:[•◦▪▫‣⁃●○■□◆◇–*]|\(?[0-9]{1,3}[.)]|\([a-z]\)|[a-z]\))\s+"#)
    static let terminalPunctuation: Set<Character> = [".", "!", "?", "。", "！", "？", "…", "”", "\"", "’", "」", "』", ":", "："]

    /// The body's line height: the most common one, by characters.
    static func bodyHeight(_ pages: [[Line]]) -> CGFloat {
        var heights: [CGFloat: Int] = [:]
        for line in pages.joined() { heights[(line.rect.height * 2).rounded() / 2, default: 0] += line.text.count }
        return heights.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 12
    }

    static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// The left and right edges a line is measured against: its column's, or the page's.
    struct Measure: Equatable {
        var left: CGFloat
        var right: CGFloat
        var width: CGFloat { max(right - left, 1) }

        /// The median start (the body's edge, not the indented first lines; of an even count the
        /// upper middle for a page, the lower for a column, which may have two lines only) and the
        /// 90th percentile end (justified ends, not the odd long line).
        init(_ lines: [Line], column: Bool = false) {
            let starts = lines.map(\.rect.minX).sorted()
            left = starts.isEmpty ? 0 : starts[column ? (starts.count - 1) / 2 : starts.count / 2]
            let ends = lines.map(\.rect.maxX).sorted()
            right = ends.isEmpty ? left : ends[min(ends.count - 1, Int(Double(ends.count) * 0.9))]
        }
    }

    /// The narrowest vertical gap between two columns, in points.
    static let minimumGutter: CGFloat = 8

    /// The text columns of a page, left to right: the x ranges between gutters, vertical bands at
    /// least `minimumGutter` wide that at most one line in twenty crosses (at least one) with two
    /// or more lines wholly on each side. Only lines up to 60% of the text's width count, as a
    /// title or a full-width abstract crosses the gutter. Each column is at least a fifth of that
    /// width and its lines' median width at least half the column's, and the lines inside columns
    /// are at least half the page's; else (also for one column) the result is empty.
    static func columns(_ lines: [Line]) -> [ClosedRange<CGFloat>] {
        guard lines.count >= 4, let minX = lines.map(\.rect.minX).min(), let maxX = lines.map(\.rect.maxX).max() else { return [] }
        let extent = maxX - minX
        guard extent >= 4 * minimumGutter else { return [] }
        let narrow = lines.filter { $0.rect.width <= 0.6 * extent }
        guard narrow.count >= 4 else { return [] }
        let crossings = max(1, narrow.count / 20)
        let bins = Int(extent.rounded(.up)) + 1
        var coverage = [Int](repeating: 0, count: bins)
        for line in narrow {
            let start = max(0, Int((line.rect.minX - minX).rounded(.down)))
            let end = min(bins - 1, Int((line.rect.maxX - minX).rounded(.up)))
            if start <= end { for bin in start...end { coverage[bin] += 1 } }
        }
        var gutters: [ClosedRange<CGFloat>] = []
        var bin = 0
        while bin < bins {
            guard coverage[bin] <= crossings else {
                bin += 1
                continue
            }
            var last = bin
            while last + 1 < bins, coverage[last + 1] <= crossings { last += 1 }
            // The widest stretch no line crosses, when it is wide enough (else a column of a few
            // lines, crossed by one, would seem part of the gutter); otherwise the whole run, which
            // a line or two cross.
            var band = (bin, last)
            var clear: Int?
            for index in bin...last + 1 {
                if index <= last, coverage[index] == 0 {
                    if clear == nil { clear = index }
                } else if let start = clear {
                    if index - 1 - start >= Int(minimumGutter), band == (bin, last) || index - 1 - start > band.1 - band.0 {
                        band = (start, index - 1)
                    }
                    clear = nil
                }
            }
            let low = minX + CGFloat(band.0), high = minX + CGFloat(band.1)
            if high - low >= minimumGutter, narrow.filter({ $0.rect.maxX <= low + 0.5 }).count >= 2,
               narrow.filter({ $0.rect.minX >= high - 0.5 }).count >= 2 {
                gutters.append(low...high)
            }
            bin = last + 1
        }
        guard !gutters.isEmpty else { return [] }
        var columns: [ClosedRange<CGFloat>] = []
        var start = minX
        for gutter in gutters {
            columns.append(start...gutter.lowerBound)
            start = gutter.upperBound
        }
        columns.append(start...maxX)
        var inside = 0
        for column in columns {
            let members = lines.filter { contains(column, $0) }
            inside += members.count
            let span = column.upperBound - column.lowerBound
            guard members.count >= 2, span >= 0.2 * extent,
                  let width = median(members.map(\.rect.width)), width >= 0.5 * span else { return [] }
        }
        return 2 * inside >= lines.count ? columns : []
    }

    /// `line` lies within `column` (it crosses no gutter).
    static func contains(_ column: ClosedRange<CGFloat>, _ line: Line) -> Bool {
        line.rect.minX >= column.lowerBound - 0.5 && line.rect.maxX <= column.upperBound + 0.5
    }

    static func paragraphs(_ pages: [[Line]]) -> [MarkdownCleaner.Block] {
        let body = bodyHeight(pages)
        var blocks: [MarkdownCleaner.Block] = []
        var current: [Line] = []
        // The last line's measure and column (nil: the page's, a page in one column or a line
        // across columns).
        var previousMeasure = Measure([])
        var previousColumn: Int?

        func flush() {
            guard !current.isEmpty else { return }
            blocks.append(block(current, bodyHeight: body))
            current = []
        }

        for lines in pages {
            guard !lines.isEmpty else { continue }
            let steps = zip(lines, lines.dropFirst()).map { $0.rect.midY - $1.rect.midY }.filter { $0 > 0 }
            let step = median(steps) ?? body * 1.2
            let page = Measure(lines)
            let columns = columns(lines)
            let measures = columns.map { column in Measure(lines.filter { contains(column, $0) }, column: true) }
            for line in lines {
                let column = columns.firstIndex { contains($0, line) }
                let measure = column.map { measures[$0] } ?? page
                if let previous = current.last {
                    let samePage = previous.page == line.page
                    let nextColumn = samePage && column != nil && previousColumn != nil && column != previousColumn
                    if startsParagraph(line, after: previous, samePage: samePage, step: step, measure: measure,
                                       previousMeasure: previousMeasure, nextColumn: nextColumn) {
                        flush()
                    }
                }
                current.append(line)
                previousMeasure = measure
                previousColumn = column
            }
        }
        flush()
        return blocks
    }

    /// Whether `line` starts a paragraph after `previous`. `measure` is the line's column (or the
    /// page), `previousMeasure` the previous line's: a line is short for its own column.
    /// `nextColumn`: the line is at the top of the column after the previous line's.
    static func startsParagraph(_ line: Line, after previous: Line, samePage: Bool, step: CGFloat, measure: Measure,
                                previousMeasure: Measure, nextColumn: Bool = false) -> Bool {
        let height = max(previous.rect.height, line.rect.height, 1)
        if listMarker.matches(line.text) { return true }
        if abs(line.rect.height - previous.rect.height) > 0.25 * height { return true }
        let ended = previous.text.last.map(terminalPunctuation.contains) ?? false
        let short = previous.rect.maxX < previousMeasure.left + 0.75 * previousMeasure.width
        let indented = line.rect.minX > measure.left + 0.8 * height
        if !samePage { return ended || short || line.rect.minX > measure.left + 1.5 * height }
        let gap = previous.rect.midY - line.rect.midY
        if gap > step * 1.45 + 1 { return true }
        if gap < 0 {
            // Up. To the top of the next column a paragraph runs on unless it ended there (a short
            // last line, or an indented new one); else it is another block of text.
            return nextColumn ? ended && (short || indented) : ended || short
        }
        if line.rect.minX > previous.rect.minX + 0.8 * height, indented { return true }
        return short && (ended || isCJK(previous.text.last)
            || previous.rect.maxX < previousMeasure.left + 0.5 * previousMeasure.width)
    }

    static func isCJK(_ character: Character?) -> Bool {
        MarkdownCleaner.Inline.isCJK(character?.unicodeScalars.first)
    }

    static func block(_ lines: [Line], bodyHeight: CGFloat) -> MarkdownCleaner.Block {
        var text = ""
        for line in lines {
            text = join(text, line.text)
        }
        let height = median(lines.map(\.rect.height)) ?? bodyHeight
        let ratio = height / max(bodyHeight, 1)
        if lines.count <= 2, text.count <= 120, ratio >= 1.3 {
            return MarkdownCleaner.Block(kind: .heading(ratio >= 1.8 ? 1 : ratio >= 1.5 ? 2 : 3), text: text)
        }
        if let marker = listMarker.firstMatch(in: text)?.first {
            return MarkdownCleaner.Block(kind: .listItem, text: String(text.dropFirst(marker.count)))
        }
        return MarkdownCleaner.Block(kind: .paragraph, text: text)
    }

    /// `text` + `next` across a line break: a hyphen before a lowercase letter and a soft hyphen
    /// go, unless the next line's first word has a hyphen of its own (a compound, "text-" +
    /// "to-speech", keeps it); CJK on both sides joins directly, anything else gets one space.
    static func join(_ text: String, _ next: String) -> String {
        guard let last = text.last else { return next }
        guard let first = next.first else { return text }
        if last == "\u{00AD}" { return String(text.dropLast()) + next }
        if last == "-", first.isLowercase, text.dropLast().last?.isLetter == true {
            let word = next.prefix { $0.isLetter || $0 == "-" }
            return word.contains("-") ? text + next : String(text.dropLast()) + next
        }
        if isCJK(last), isCJK(first) { return text + next }
        return text + " " + next
    }
}
