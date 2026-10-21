import Foundation

/// A compiled regular expression. NSRegularExpression is immutable once built, so one
/// instance is safely shared; it is also far faster than Swift Regex on 1 MB inputs.
struct TextPattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        // The patterns are literals in this file and covered by tests.
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func replace(in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Replace every match by `transform(groups)` (group 0 = the whole match; nil groups are "").
    func replace(in text: String, _ transform: ([String]) -> String) -> String {
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            result += transform(groups)
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }

    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The capture groups of the first match (group 0 = the whole match).
    func firstMatch(in text: String) -> [String]? {
        let source = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
    }
}

/// Markdown (defuddle.md output or a local .md file) → display blocks with the markup
/// removed (R3-02, R3-04, R3-05, R2-07 app side). Footnotes, citation markers, reference
/// sections, images, URLs, code, tables, HTML and emoji are dropped; links keep their text;
/// emphasis markers go only at word boundaries, so snake_case and `a < b` survive.
/// Expects LF newlines.
enum MarkdownCleaner {
    struct Block: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case heading(Int)
            case paragraph
            case listItem
            case quote
        }

        let kind: Kind
        let text: String
    }

    /// Section headings whose section (up to the next heading of the same or a higher level)
    /// is citation or navigation boilerplate, compared as `headingKey` makes them: lowercased,
    /// Simplified, without a leading number or a trailing colon.
    static let boilerplateHeadings: Set<String> = [
        "references", "reference", "notes", "footnotes", "citations", "bibliography", "sources",
        "further reading", "external links", "see also", "works cited", "notes and references",
        "references and notes",
        "参考文献", "参考资料", "参考来源", "参考链接", "参考连结", "参考书目", "注释", "脚注", "注脚",
        "外部链接", "外部连结", "延伸阅读", "扩展阅读", "相关条目", "参见", "另见",
    ]

    /// The citation sections among them, the only ones dropped from the user's own documents
    /// (Word, RTF, OpenDocument, PDF, EPUB): their "Notes" or "注释" are the author's and are read.
    static let citationHeadings: Set<String> = [
        "references", "reference", "citations", "bibliography", "works cited", "notes and references",
        "references and notes", "参考文献", "参考资料", "参考来源", "参考书目",
    ]

    /// The Traditional characters of those headings (zh.wikipedia mixes forms: 参考資料).
    static let simplifiedForms: [Character: Character] = [
        "參": "参", "資": "资", "獻": "献", "釋": "释", "鏈": "链", "結": "结", "閱": "阅", "讀": "读", "關": "关",
        "條": "条", "註": "注", "腳": "脚", "見": "见", "連": "连", "來": "来", "擴": "扩", "書": "书",
    ]

    /// `keepsIndentedText`: an indented block is a paragraph, not code (pasted text, where
    /// indentation is a paragraph's first-line indent; fenced code still goes).
    static func blocks(_ markdown: String, keepsIndentedText: Bool = false) -> [Block] {
        var text = TextDecoding.normalizeNewlines(markdown)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = Escapes.protect(text)
        text = Patterns.htmlComment.replace(in: text, with: "")
        text = Patterns.droppedElements.replace(in: text, with: "")
        var parser = BlockParser(keepsIndentedText: keepsIndentedText)
        let raw = parser.parse(text)
        let cleaned = Inline.clean(raw.map(\.text), references: parser.referenceLabels)
        var blocks: [Block] = []
        for (block, text) in zip(raw, cleaned) {
            var text = text
            if block.kind == .quote { text = Patterns.callout.replace(in: text, with: "$1: ") }
            blocks.append(Block(kind: block.kind, text: text))
        }
        return dropBoilerplateSections(blocks).filter { Inline.isSpeakable($0.text) }
    }

    /// Drop each boilerplate section (heading through the next heading of the same or a higher
    /// level), but only after some real content, so a page that is only a reading list stays.
    /// `headings`: the section titles that go (`boilerplateHeadings`, or `citationHeadings`).
    static func dropBoilerplateSections(_ blocks: [Block], headings: Set<String> = boilerplateHeadings) -> [Block] {
        var result: [Block] = []
        var droppingLevel: Int?
        var seenContent = false
        for block in blocks {
            if case .heading(let level) = block.kind {
                if let dropping = droppingLevel {
                    if level > dropping { continue }
                    droppingLevel = nil
                }
                if seenContent, headings.contains(headingKey(block.text)) {
                    droppingLevel = level
                    continue
                }
            } else {
                if droppingLevel != nil { continue }
                if Inline.isSpeakable(block.text) { seenContent = true }
            }
            result.append(block)
        }
        return result
    }

    /// "八、参考資料：" → "参考资料"; "8. References" → "references".
    static func headingKey(_ text: String) -> String {
        var key = Patterns.headingNumber.replace(in: text.trimmingCharacters(in: .whitespacesAndNewlines), with: "")
        key = String(key.lowercased().map { simplifiedForms[$0] ?? $0 })
        while let last = key.last, last == ":" || last == "：" { key.removeLast() }
        return key.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Patterns

    enum Patterns {
        static let htmlComment = TextPattern(#"<!--[\s\S]*?-->"#)
        static let droppedElements = TextPattern(
            #"<(script|style|noscript|table|svg|math)\b[^>]*>[\s\S]*?</\1\s*>"#, [.caseInsensitive])
        static let fence = TextPattern(#"^[ \t>]*(`{3,}|~{3,})"#)
        static let atxHeading = TextPattern(#"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$"#)
        static let setextUnderline = TextPattern(#"^ {0,3}(=+|-{2,})[ \t]*$"#)
        static let horizontalRule = TextPattern(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
        static let quoteMarkers = TextPattern(#"^[ \t]*((?:>[ \t]?)+)"#)
        static let listItem = TextPattern(#"^([ \t]*)(?:[-*+•]|\d{1,3}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?(.*)$"#)
        static let footnoteDefinition = TextPattern(#"^ {0,3}\[\^[^\]\n]+\]:"#)
        static let referenceDefinition = TextPattern(
            #"^ {0,3}\[([^\]\n]+)\]:[ \t]*<?\S+>?(?:[ \t]+(?:"[^"\n]*"|'[^'\n]*'|\([^)\n]*\)))?[ \t]*$"#)
        static let tableSeparator = TextPattern(#"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)+\|?[ \t]*$"#)
        static let callout = TextPattern(#"^\[!(\w+)\][-+]?[ \t]*"#)
        /// A heading's number: 八、 (一) 1. 2.3 8)
        static let headingNumber = TextPattern(
            #"^(?:[(（][0-9一二三四五六七八九十]{1,3}[)）]|[0-9]{1,3}(?:\.[0-9]{1,3})*[.)、．]?|[一二三四五六七八九十]{1,3}[、.．])\s*"#)
        /// A display formula on lines of its own: $$ … $$.
        static let displayMath = TextPattern(#"^[ \t]*\$\$"#)
    }

    // MARK: - Blocks

    struct RawBlock {
        let kind: Block.Kind
        let text: String
    }

    /// Line-based block structure: fences, indented code, display math and tables are skipped;
    /// footnote and reference definitions are dropped (the reference labels are kept for links).
    struct BlockParser {
        var keepsIndentedText = false
        private(set) var referenceLabels: Set<String> = []
        private var blocks: [RawBlock] = []
        private var open: (kind: Block.Kind, lines: [String], depth: Int)?

        init(keepsIndentedText: Bool = false) {
            self.keepsIndentedText = keepsIndentedText
        }

        mutating func parse(_ text: String) -> [RawBlock] {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var index = 0
            var afterBlank = true
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let lead = trimmed.first else {
                    flush()
                    afterBlank = true
                    index += 1
                    continue
                }
                let wasAfterBlank = afterBlank
                afterBlank = false
                // Cheap checks on the first character keep the regexes off most lines.
                let mayBeFence = lead == "`" || lead == "~" || (lead == ">" && (line.contains("```") || line.contains("~~~")))
                if mayBeFence, let fence = Patterns.fence.firstMatch(in: line)?[1] {
                    flush()
                    index = Self.indexAfterFence(lines, from: index, fence: fence)
                    continue
                }
                let indentation = Self.indentation(line)
                if wasAfterBlank, indentation >= 2, blocks.last?.kind == .listItem, open == nil {
                    // A continuation paragraph of the list item above.
                    open = (.listItem, [trimmed], 0)
                    index += 1
                    continue
                }
                if wasAfterBlank, indentation >= 4, open == nil, !keepsIndentedText {
                    index = Self.indexAfterIndentedCode(lines, from: index)
                    continue
                }
                if lead == "$", Patterns.displayMath.matches(line), let end = Self.indexAfterDisplayMath(lines, from: index) {
                    flush()
                    index = end
                    continue
                }
                if lead == "[" {
                    if Patterns.footnoteDefinition.matches(line) {
                        flush()
                        index = Self.indexAfterFootnote(lines, from: index)
                        continue
                    }
                    if open?.kind != .paragraph, let label = Patterns.referenceDefinition.firstMatch(in: line)?[1] {
                        flush()
                        referenceLabels.insert(Self.normalizedLabel(label))
                        index += 1
                        continue
                    }
                }
                if line.contains("|"), index + 1 < lines.count, lines[index + 1].contains("-"),
                   Patterns.tableSeparator.matches(lines[index + 1]) {
                    flush()
                    index += 2
                    while index < lines.count, lines[index].contains("|"),
                          !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        index += 1
                    }
                    continue
                }
                if lead == "#", let heading = Patterns.atxHeading.firstMatch(in: line) {
                    flush()
                    blocks.append(RawBlock(kind: .heading(heading[1].count), text: heading[2]))
                    index += 1
                    continue
                }
                if lead == "=" || lead == "-", let paragraph = open, paragraph.kind == .paragraph,
                   let underline = Patterns.setextUnderline.firstMatch(in: line) {
                    open = nil
                    let level = underline[1].hasPrefix("=") ? 1 : 2
                    blocks.append(RawBlock(kind: .heading(level), text: Self.join(paragraph.lines)))
                    index += 1
                    continue
                }
                if lead == "-" || lead == "*" || lead == "_", Patterns.horizontalRule.matches(line) {
                    flush()
                    index += 1
                    continue
                }
                if lead == ">", let markers = Patterns.quoteMarkers.firstMatch(in: line) {
                    let depth = markers[1].filter { $0 == ">" }.count
                    var content = String(line.dropFirst(markers[0].count)).trimmingCharacters(in: .whitespaces)
                    if let item = Patterns.listItem.firstMatch(in: content) { content = item[2] }
                    if content.hasPrefix("#"), let heading = Patterns.atxHeading.firstMatch(in: content) {
                        content = heading[2]
                    }
                    if content.isEmpty || Patterns.horizontalRule.matches(content) {
                        flush()
                    } else if let current = open, current.kind == .quote, current.depth == depth {
                        open?.lines.append(content)
                    } else {
                        flush()
                        open = (.quote, [content], depth)
                    }
                    index += 1
                    continue
                }
                if "-*+•".contains(lead) || lead.isASCII && lead.isNumber,
                   let item = Patterns.listItem.firstMatch(in: line) {
                    flush()
                    open = (.listItem, [item[2]], 0)
                    index += 1
                    continue
                }
                // Trailing spaces stay: two of them are a hard line break (see `join`).
                let content = String(line.drop { $0 == " " || $0 == "\t" })
                if open != nil {
                    open?.lines.append(content)  // a (lazy) continuation line
                } else {
                    open = (.paragraph, [content], 0)
                }
                index += 1
            }
            flush()
            return blocks
        }

        private mutating func flush() {
            guard let current = open else { return }
            open = nil
            blocks.append(RawBlock(kind: current.kind, text: Self.join(current.lines)))
        }

        /// Soft line breaks become a space (none between two CJK characters); a hard break
        /// (two trailing spaces or a backslash) becomes a newline.
        static func join(_ lines: [String]) -> String {
            var result = ""
            for raw in lines {
                var line = raw
                var hardBreak = false
                if line.hasSuffix("  ") || line.hasSuffix("\\") {
                    hardBreak = true
                }
                line = line.trimmingCharacters(in: .whitespaces)
                if line.hasSuffix("\\") { line.removeLast() }
                if !result.isEmpty, !result.hasSuffix("\n") {
                    let glue = Inline.isCJK(result.unicodeScalars.last) && Inline.isCJK(line.unicodeScalars.first)
                    result += glue ? "" : " "
                }
                result += line
                if hardBreak { result += "\n" }
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func indentation(_ line: String) -> Int {
            var width = 0
            for character in line {
                if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
            }
            return width
        }

        static func normalizedLabel(_ label: String) -> String {
            label.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        /// The closing fence is the same character, at least as long; an unclosed fence runs
        /// to the end of the document (CommonMark).
        static func indexAfterFence(_ lines: [String], from start: Int, fence: String) -> Int {
            guard let marker = fence.first else { return start + 1 }
            var index = start + 1
            while index < lines.count {
                let content = lines[index].drop { $0 == " " || $0 == "\t" || $0 == ">" }
                let run = content.prefix { $0 == marker }
                if run.count >= fence.count, content.dropFirst(run.count).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    return index + 1
                }
                index += 1
            }
            return index
        }

        /// A footnote definition runs on through its continuation lines, indented or lazy (any
        /// line that starts no other block), and through further paragraphs indented by 4.
        static func indexAfterFootnote(_ lines: [String], from start: Int) -> Int {
            var index = start + 1
            while true {
                while index < lines.count, !isBlank(lines[index]), indentation(lines[index]) >= 4 || !startsBlock(lines[index]) {
                    index += 1
                }
                var next = index
                while next < lines.count, isBlank(lines[next]) { next += 1 }
                guard next > index, next < lines.count, indentation(lines[next]) >= 4 else { return index }
                index = next
            }
        }

        /// Whether `line` opens a block of its own (and so ends a lazy continuation).
        static func startsBlock(_ line: String) -> Bool {
            guard let lead = line.first(where: { $0 != " " && $0 != "\t" }) else { return true }
            switch lead {
            case "#": return Patterns.atxHeading.matches(line)
            case ">", "|": return true
            case "`", "~": return Patterns.fence.matches(line)
            case "[": return Patterns.footnoteDefinition.matches(line) || Patterns.referenceDefinition.matches(line)
            case "$": return Patterns.displayMath.matches(line)
            default:
                if lead == "-" || lead == "*" || lead == "_", Patterns.horizontalRule.matches(line) { return true }
                return ("-*+•".contains(lead) || lead.isASCII && lead.isNumber) && Patterns.listItem.matches(line)
            }
        }

        static func isBlank(_ line: String) -> Bool {
            line.allSatisfy { $0 == " " || $0 == "\t" }
        }

        /// $$ … $$ (on one line or several, closed within `maxMathLines`) holding TeX: a
        /// backslash, ^, _ or a brace. nil when it is not one ("$$5 for two").
        static func indexAfterDisplayMath(_ lines: [String], from start: Int) -> Int? {
            let opening = lines[start].drop { $0 == " " || $0 == "\t" }.dropFirst(2)
            var body = String(opening)
            var end: Int?
            if let close = opening.range(of: "$$") {
                // One line, and nothing after it (else it is inline math in a paragraph).
                guard opening[close.upperBound...].allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
                body = String(opening[..<close.lowerBound])
                end = start + 1
            } else {
                for index in (start + 1)..<min(lines.count, start + maxMathLines) {
                    if let close = lines[index].range(of: "$$") {
                        body += "\n" + lines[index][..<close.lowerBound]
                        end = index + 1
                        break
                    }
                    body += "\n" + lines[index]
                }
            }
            guard let end, Inline.isTeX(body) else { return nil }
            return end
        }

        static let maxMathLines = 100

        static func indexAfterIndentedCode(_ lines: [String], from start: Int) -> Int {
            var index = start
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty || indentation(line) >= 4 {
                    index += 1
                } else {
                    break
                }
            }
            return index
        }
    }

    // MARK: - Inline

    enum Inline {
        static let blockSeparator = "\n\u{E0FF}\n"

        /// Clean every block's inline markup in one pass over the joined text (NSRegularExpression
        /// per block would be slow on long documents). Blocks never merge: no pattern crosses a
        /// newline.
        static func clean(_ texts: [String], references: Set<String>) -> [String] {
            guard !texts.isEmpty else { return [] }
            let cleaned = cleanJoined(texts.joined(separator: blockSeparator), references: references)
                .components(separatedBy: blockSeparator)
            guard cleaned.count == texts.count else {
                return texts.map { tidy(cleanJoined($0, references: references)) }
            }
            return cleaned.map(tidy)
        }

        // Spans are bounded ({1,500}, {0,200}): unbounded lazy spans made a long line with
        // unmatched markers quadratic (a 60,000-character line took 38 s).
        static let url = #"\((?:[^()\n]|\([^()\n]{0,500}\))*\)"#
        static let image = TextPattern(#"!\[(?:[^\[\]\n]|\[[^\]\n]{0,200}\])*\]"# + url)
        static let referenceImage = TextPattern(#"!\[[^\]\n]{0,500}\]\[[^\]\n]{0,200}\]"#)
        static let emptyLink = TextPattern(#"\[\s*\]"# + url)
        static let inlineLink = TextPattern(#"\[((?:[^\[\]\n]|\[[^\]\n]{0,200}\])+)\]"# + url)
        static let referenceLink = TextPattern(#"\[([^\[\]\n]+)\]\[([^\]\n]{0,200})\]"#)
        static let shortcutLink = TextPattern(#"\[([^\[\]\n]+)\](?![(\[])"#)
        /// With the space before it: "true [^1]." → "true.".
        static let footnoteReference = TextPattern(#"[ \t]*\[\^[^\]\s]{1,100}\]"#)
        /// Runs of numeric markers ([1][2], [3, 4], [5–7]) and the space before them; not a
        /// reference link's label ([the docs][1]), hence the lookbehind.
        static let citation = TextPattern(
            #"(?<!\])[ \t]*(?:\[(?:\d{1,3}(?:[ \t]*[,–-][ \t]*\d{1,3})*|(?:citation|clarification) needed|来源请求|來源請求|需要引用|需要来源|需要來源)\])+"#,
            [.caseInsensitive])
        static let codeSpan = TextPattern(#"(`{1,2})(?=[^`\n])(.+?)(?<=[^`\n])\1(?!`)"#)
        static let autolink = TextPattern(#"<(?:(?:https?|ftp)://|mailto:|www\.)[^<>\s]*>|<[^@\s<>]+@[^@\s<>]+\.[A-Za-z]{2,}>"#,
                                          [.caseInsensitive])
        /// A URL ends at whitespace, quotes, and CJK text or punctuation ("详见 https://a.com/b。下一句",
        /// "访问https://a.com了解更多"); losing a Chinese path segment is the price. Parentheses
        /// only in pairs: wiki/Phone_(phonetics) is one URL, "(see https://a.com)" ends before ")".
        static let bareURL = TextPattern(
            #"(?<![A-Za-z0-9])(?:https?|ftp)://(?:[^()\#(urlStop)]|\([^()\#(urlStop)]{0,200}\))*"#
                + #"(?:[^.,;:!?()\]\#(urlStop)]|\([^()\#(urlStop)]{0,200}\))"#, [.caseInsensitive])
        static let urlStop = #"\s<>"'\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\x{2000}-\x{206F}\x{3000}-\x{303F}\x{FF00}-\x{FFEF}"#
        /// `*` emphasis, but not between ASCII letters or digits on both sides of a marker
        /// (2*3*4, a*b*c); next to CJK text it still is (这是**重要**的, **特价**199元).
        static let strongEmphasis = TextPattern(
            #"(?<!\*)(?:(?<![A-Za-z0-9])|(?=\*{1,3}+[^\sA-Za-z0-9*]))(\*{1,3})(?=\S)(.{1,500}?)(?:(?<=[^\sA-Za-z0-9*])\1|(?<=\S)\1(?![A-Za-z0-9]))"#)
        static let underscoreEmphasis = TextPattern(
            #"(?<![\p{L}\p{N}_])(_{1,3})(?=\S)(.{1,500}?)(?<=\S)\1(?![\p{L}\p{N}_])"#)
        static let strike = TextPattern(#"~~(?=\S)(.{1,500}?)(?<=\S)~~"#)
        static let highlight = TextPattern(#"==(?=\S)(.{1,500}?)(?<=\S)=="#)
        /// $…$ and $$…$$ inside a paragraph; dropped only when it holds TeX (see `isTeX`), so
        /// "$5 and $10" stays.
        static let inlineMath = TextPattern(#"(?<![$\p{N}])(\$\$?)(?=[^\s$])([^$\n]{1,300}?)(?<=\S)\1(?![$\p{N}])"#)
        static let lineBreakTag = TextPattern(#"<br\s*/?>"#, [.caseInsensitive])
        /// Tags of known HTML elements (and custom ones, my-widget, o:p) only: "x<y and y>z" is
        /// text. An attribute without a value must be a known boolean one ("a<b and c>d" stays).
        static let htmlTag = TextPattern(
            #"</?(?:\#(htmlElements)|[a-z][a-z0-9]*-[-a-z0-9]*|[a-z]+:[a-z][-a-z0-9]*)(?![-a-z0-9:])"#
                + #"(?>\s+(?:[a-z_:][-a-z0-9_:.]*+\s*=\s*(?:"[^"\n]*+"|'[^'\n]*+'|[^\s"'=<>`]++)|(?:\#(booleanAttributes))(?![-a-z0-9_:.])))*+\s*/?>"#,
            [.caseInsensitive])
        static let htmlElements = [
            "a", "abbr", "acronym", "address", "area", "article", "aside", "audio", "b", "bdi", "bdo", "big", "blink",
            "blockquote", "body", "br", "button", "canvas", "caption", "center", "cite", "code", "col", "colgroup",
            "data", "datalist", "dd", "del", "details", "dfn", "dialog", "dir", "div", "dl", "dt", "em", "embed",
            "fieldset", "figcaption", "figure", "font", "footer", "form", "h[1-6]", "head", "header", "hgroup", "hr",
            "html", "i", "iframe", "img", "input", "ins", "kbd", "label", "legend", "li", "link", "main", "map", "mark",
            "marquee", "menu", "meta", "meter", "nav", "nobr", "object", "ol", "optgroup", "option", "output", "p",
            "param", "picture", "pre", "progress", "q", "rb", "rp", "rt", "rtc", "ruby", "s", "samp", "section",
            "select", "slot", "small", "source", "span", "strike", "strong", "sub", "summary", "sup", "tbody", "td",
            "template", "textarea", "tfoot", "th", "thead", "time", "title", "tr", "track", "tt", "u", "ul", "var",
            "video", "wbr",
        ].joined(separator: "|")
        static let booleanAttributes = [
            "allowfullscreen", "async", "autofocus", "autoplay", "checked", "controls", "default", "defer", "disabled",
            "hidden", "inert", "ismap", "itemscope", "loop", "multiple", "muted", "nomodule", "novalidate", "open",
            "playsinline", "readonly", "required", "reversed", "selected",
        ].joined(separator: "|")
        static let entity = TextPattern(#"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});"#)
        static let decoration = TextPattern(#"(?<![\p{L}\p{N}])[*=~#|_]{2,}|[*=~#|_]{2,}(?![\p{L}\p{N}])"#)

        static func cleanJoined(_ input: String, references: Set<String>) -> String {
            // Code spans keep their content verbatim (no emphasis, tag or entity processing).
            var codes: [String] = []
            var text = codeSpan.replace(in: input) { groups in
                codes.append(groups[2].trimmingCharacters(in: .whitespaces))
                return "\u{E100}\(codes.count - 1)\u{E101}"
            }
            if text.contains("$") {
                text = inlineMath.replace(in: text) { groups in isTeX(groups[2]) ? "" : groups[0] }
            }
            text = footnoteReference.replace(in: text, with: "")
            text = image.replace(in: text, with: "")
            text = referenceImage.replace(in: text, with: "")
            text = emptyLink.replace(in: text, with: "")
            for _ in 0..<2 { text = inlineLink.replace(in: text, with: "$1") }
            // Before the reference links: [1][2] is two markers, and a defined [1] is a citation too.
            text = citation.replace(in: text, with: "")
            text = referenceLink.replace(in: text) { groups in
                groups[1]
            }
            if !references.isEmpty {
                text = shortcutLink.replace(in: text) { groups in
                    references.contains(BlockParser.normalizedLabel(groups[1])) ? groups[1] : groups[0]
                }
            }
            text = autolink.replace(in: text, with: "")
            text = bareURL.replace(in: text, with: "")
            for _ in 0..<2 { text = strongEmphasis.replace(in: text, with: "$2") }
            text = underscoreEmphasis.replace(in: text, with: "$2")
            text = strike.replace(in: text, with: "$1")
            text = highlight.replace(in: text, with: "$1")
            text = lineBreakTag.replace(in: text, with: "\n")
            text = htmlTag.replace(in: text, with: "")
            text = decodeEntities(text)
            text = text.replacingOccurrences(of: "`", with: "")  // stray, unpaired backticks
            text = Escapes.restore(text)
            text = decoration.replace(in: text, with: " ")
            if !codes.isEmpty {
                text = codePlaceholder.replace(in: text) { groups in
                    Int(groups[1]).flatMap { codes.indices.contains($0) ? codes[$0] : nil } ?? ""
                }
            }
            return Symbols.clean(text)
        }

        // ICU spells a code point \x{…}; Swift's \u{…} inside a raw string is not one.
        static let codePlaceholder = TextPattern(#"\x{E100}(\d+)\x{E101}"#)
        static let spaceRun = TextPattern(#"[ \t\x{00A0}\x{2000}-\x{200A}\x{202F}\x{205F}]+"#)
        /// A space a removed marker left before CJK punctuation ("一样[^1] 。").
        static let spaceBeforeCJKPunctuation = TextPattern(#" ([，。！？；：、）」』】》])"#)

        /// Collapse spaces, trim every line, drop empty lines.
        static func tidy(_ text: String) -> String {
            text.split(separator: "\n")
                .map { line in
                    let collapsed = spaceRun.replace(in: String(line), with: " ")
                    return spaceBeforeCJKPunctuation.replace(in: collapsed, with: "$1").trimmingCharacters(in: .whitespaces)
                }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        /// TeX, not prices or shell variables: a backslash (also an escaped character), ^, _ or a brace.
        static func isTeX<S: StringProtocol>(_ text: S) -> Bool {
            text.unicodeScalars.contains { scalar in
                switch scalar.value {
                case 0x5C, 0x5E, 0x5F, 0x7B, 0x7D, 0xE021...0xE07E: true
                default: false
                }
            }
        }

        /// Something to say: a letter or a digit.
        static func isSpeakable(_ text: String) -> Bool {
            text.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
        }

        static func isCJK(_ scalar: Unicode.Scalar?) -> Bool {
            guard let value = scalar?.value else { return false }
            switch value {
            case 0x2E80...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0xFF00...0xFFEF, 0x20000...0x3FFFF:
                return true
            default:
                return false
            }
        }

        static let namedEntities: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ensp": " ", "emsp": " ",
            "thinsp": " ", "shy": "", "zwj": "", "zwnj": "", "mdash": "—", "ndash": "–", "hellip": "…",
            "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
            "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "middot": "·", "bull": "•",
            "copy": "©", "reg": "®", "trade": "™", "deg": "°", "times": "×", "divide": "÷", "plusmn": "±",
            "minus": "−", "frac12": "½", "frac14": "¼", "frac34": "¾", "euro": "€", "pound": "£", "yen": "¥",
            "cent": "¢", "sect": "§", "para": "¶", "micro": "µ", "prime": "′", "Prime": "″",
            "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "hearts": "♥", "star": "☆",
        ]

        static func decodeEntities(_ text: String) -> String {
            guard text.contains("&") else { return text }
            return entity.replace(in: text) { groups in
                let name = groups[1]
                if name.hasPrefix("#") {
                    let digits = name.dropFirst()
                    let value = digits.first == "x" || digits.first == "X"
                        ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                    guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return groups[0] }
                    return String(Character(scalar))
                }
                return namedEntities[name] ?? groups[0]
            }
        }
    }

    // MARK: - Escapes

    /// Backslash escapes of ASCII punctuation become private-use placeholders while the markup
    /// is parsed (so `\[v\]` is not a link and `\*` not emphasis), then the characters again.
    enum Escapes {
        static let punctuation = Array(##"!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~"##)

        static func protect(_ text: String) -> String {
            guard text.contains("\\") else { return text }
            var result = ""
            var iterator = text.makeIterator()
            while let character = iterator.next() {
                guard character == "\\" else {
                    result.append(character)
                    continue
                }
                guard let next = iterator.next() else {
                    result.append(character)
                    break
                }
                if let ascii = next.asciiValue, punctuation.contains(next) {
                    result.unicodeScalars.append(Unicode.Scalar(0xE000 + UInt32(ascii))!)
                } else {
                    result.append(character)
                    result.append(next)
                }
            }
            return result
        }

        static func restore(_ text: String) -> String {
            var result = String.UnicodeScalarView()
            for scalar in text.unicodeScalars {
                if (0xE021...0xE07E).contains(scalar.value), let ascii = Unicode.Scalar(scalar.value - 0xE000) {
                    result.append(ascii)
                } else {
                    result.append(scalar)
                }
            }
            return String(result)
        }
    }

    // MARK: - Emoji and separators

    /// Emoji are dropped, keycap digits keep their digit (1️⃣ → 1); runs of bullets, arrows,
    /// stars and check marks become a clause separator ("，" after CJK text, ", " otherwise),
    /// or nothing at the start or end of a line or next to punctuation (R2-07). A middle dot
    /// between two names (列夫·托尔斯泰) is kept, and so is ○, a zero in 二○二四年.
    enum Symbols {
        /// "1️⃣" → "1", "🔟" → "10"; nil for any other character (#️⃣ and *️⃣ are dropped).
        static func keycapDigits(_ character: Character) -> String? {
            let scalars = character.unicodeScalars
            guard let first = scalars.first else { return nil }
            if first.value == 0x1F51F, scalars.count == 1 { return "10" }
            guard scalars.count > 1, scalars.last?.value == 0x20E3, (0x30...0x39).contains(first.value) else { return nil }
            return String(first)
        }

        static func isEmoji(_ character: Character) -> Bool {
            let scalars = character.unicodeScalars
            guard let first = scalars.first else { return false }
            if first.properties.isEmojiPresentation { return true }
            if first.value >= 0x1F000, first.properties.isEmoji { return true }
            return scalars.contains { scalar in
                switch scalar.value {
                case 0xFE0F, 0x200D, 0x20E3, 0x1F3FB...0x1F3FF, 0x1F1E6...0x1F1FF, 0xE0020...0xE007F: true
                default: false
                }
            }
        }

        static func isSeparator(_ character: Character) -> Bool {
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
            switch scalar.value {
            case 0x25CB, 0x25EF:  // ○ ◯: a zero in Chinese numbers (二○二四年)
                return false
            case 0x2022, 0x2023, 0x2043, 0x2027, 0x2219, 0x25A0...0x25FF,  // bullets, geometric shapes
                 0x2190...0x21FF, 0x27F0...0x27FF, 0x2900...0x297F, 0x2794...0x27BF, 0x2B05...0x2B07,  // arrows
                 0x2605, 0x2606, 0x2726...0x2730, 0x2B50,  // stars
                 0x2713...0x2718, 0x2610...0x2612, 0x2705, 0x274C, 0x274E:  // check marks, ballot boxes
                return true
            default:
                return false
            }
        }

        static func clean(_ text: String) -> String {
            guard text.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return text }
            var result = ""
            var pendingSeparator = false
            let characters = Array(text)
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if let digits = keycapDigits(character) {
                    if pendingSeparator {
                        pendingSeparator = false
                        appendSeparator(to: &result, before: "0")
                    }
                    result += digits
                    index += 1
                    continue
                }
                if isEmoji(character) {
                    index += 1
                    continue
                }
                let spacedMiddleDot = character == "·"
                    && (index == 0 || characters[index - 1] == " ")
                    && (index + 1 == characters.count || characters[index + 1] == " ")
                if isSeparator(character) || spacedMiddleDot {
                    pendingSeparator = true
                    index += 1
                    continue
                }
                if pendingSeparator, !character.isWhitespace {
                    pendingSeparator = false
                    appendSeparator(to: &result, before: character)
                }
                result.append(character)
                index += 1
            }
            return result
        }

        private static func appendSeparator(to result: inout String, before next: Character) {
            while result.last == " " { result.removeLast() }
            guard let previous = result.last, previous != "\n" else { return }
            if previous.isPunctuation || next.isPunctuation {
                result.append(" ")
                return
            }
            result += Inline.isCJK(previous.unicodeScalars.first) ? "，" : ", "
        }
    }
}
