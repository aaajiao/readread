import CryptoKit
import XCTest

@testable import ReadRead

/// Seeded property tests of the text pipeline (R3-15): generated Markdown and plain text, Chinese
/// and English mixed, through MarkdownCleaner (or PlainTextCleaner) → SpeechChunker →
/// DocumentBuilder, checked against the invariants every ReadingDocument keeps
/// (`PipelineInvariants`). Each property runs a few hundred inputs; a failure names its seed, and
/// `PipelineInputGenerator(seed:)` rebuilds that input.
final class TextPipelinePropertyTests: XCTestCase {
    // MARK: - Properties

    func testGeneratedMarkdownKeepsEveryInvariant() {
        checkSeeds(1...400) { seed in
            var generator = PipelineInputGenerator(seed: seed)
            let input = generator.markdownDocument()
            let document = DocumentBuilder.fromMarkdown(input.markdown, title: input.title, source: .text, sourceLabel: "")
            return (input.markdown, PipelineInvariants.violations(of: document, title: input.title))
        }
    }

    /// Pasted text: an indented block is a paragraph (a first-line indent), not code.
    func testGeneratedPastedMarkdownKeepsEveryInvariant() {
        checkSeeds(5001...5200) { seed in
            var generator = PipelineInputGenerator(seed: seed)
            let input = generator.markdownDocument(pasted: true)
            let document = DocumentBuilder.fromMarkdown(
                input.markdown, title: input.title, source: .text, sourceLabel: "", keepsIndentedText: true)
            return (input.markdown, PipelineInvariants.violations(of: document, title: input.title))
        }
    }

    func testGeneratedPlainTextKeepsEveryInvariant() {
        checkSeeds(1...250) { seed in
            var generator = PipelineInputGenerator(seed: seed)
            let text = generator.plainTextDocument()
            let document = DocumentBuilder.fromPlainText(text, title: nil, source: .text, sourceLabel: "")
            return (text, PipelineInvariants.violations(of: document, title: nil))
        }
    }

    /// Sentences far over the caps (no punctuation, commas only, one unbreakable word, a digit run,
    /// letters under stacks of combining marks): cut to the caps, clamped to 3000 scalars, nothing
    /// speakable lost.
    func testLongAndUnbreakableSentencesKeepTheCaps() {
        var longest = 0
        var clamped = 0
        checkSeeds(1...300) { seed in
            var generator = PipelineInputGenerator(seed: seed)
            let markdown = generator.longParagraphs()
            let document = DocumentBuilder.fromMarkdown(markdown, title: nil, source: .text, sourceLabel: "")
            longest = max(longest, document.units.map(\.range.count).max() ?? 0)
            clamped += document.units.filter { $0.speakText.unicodeScalars.count == SpeechChunker.maxSpeakCharacters }.count
            return (markdown, PipelineInvariants.violations(of: document, title: nil))
        }
        XCTAssertGreaterThan(longest, SpeechChunker.chineseCap, "the inputs reach the caps")
        XCTAssertGreaterThan(clamped, 0, "some unit is clamped to the server's limit")
    }

    /// The same Markdown with CRLF or CR line ends, a BOM, more blank lines between its blocks, or
    /// another source builds the same blocks, units and content hash, and so does building it again.
    func testLineEndsByteOrderMarkBlankLinesAndSourceChangeNothing() throws {
        let page = try XCTUnwrap(URL(string: "https://example.com/post"))
        checkSeeds(2001...2100) { seed in
            var generator = PipelineInputGenerator(seed: seed)
            let input = generator.markdownDocument()
            func build(_ markdown: String, _ source: DocumentSource = .text, _ label: String = "") -> ReadingDocument {
                DocumentBuilder.fromMarkdown(markdown, title: input.title, source: source, sourceLabel: label)
            }
            let reference = build(input.markdown)
            let variants = [
                ("built again", build(input.markdown)),
                ("CRLF", build(input.markdown.replacingOccurrences(of: "\n", with: "\r\n"))),
                ("CR", build(input.markdown.replacingOccurrences(of: "\n", with: "\r"))),
                ("BOM", build("\u{FEFF}" + input.markdown)),
                ("blank lines", build("\n\n" + input.chunks.joined(separator: "\n\n\n\n") + "\n\n\n")),
                ("URL source", build(input.markdown, .url(page), "example.com")),
                ("file source", build(input.markdown, .file(URL(fileURLWithPath: "/tmp/post.md")), "post.md")),
            ]
            var problems: [String] = []
            for (name, variant) in variants {
                if variant.blocks != reference.blocks { problems.append("\(name): the blocks differ") }
                if variant.units != reference.units { problems.append("\(name): the units differ") }
                if variant.contentHash != reference.contentHash { problems.append("\(name): the content hash differs") }
            }
            return (input.markdown, problems)
        }
    }

    /// The real pages and files of the golden tests keep the same invariants (the markup list is
    /// the contract's: their text may hold `==`, rsync:// or, in a .txt file, a backslash of its own).
    func testFixturesKeepEveryInvariant() throws {
        for path in Self.markdownFixtures {
            let split = Frontmatter.split(try Fixtures.text(path))
            let title = split.metadata["title"]
            let document = DocumentBuilder.fromMarkdown(split.body, title: title, source: .text, sourceLabel: "")
            XCTAssertFalse(document.units.isEmpty, path)
            XCTAssertEqual(PipelineInvariants.violations(of: document, title: title, generated: false), [], path)
        }
        for path in Self.textFixtures {
            let document = DocumentBuilder.fromPlainText(try Fixtures.text(path), title: nil, source: .text, sourceLabel: "")
            XCTAssertFalse(document.units.isEmpty, path)
            XCTAssertEqual(PipelineInvariants.violations(of: document, title: nil, generated: false, markdown: false), [], path)
        }
    }

    /// The generator is deterministic, and its inputs hold every construct the invariants are
    /// about, so a change to it cannot quietly stop testing one.
    func testTheGeneratorIsDeterministicAndCoversTheMarkup() {
        var first = PipelineInputGenerator(seed: 7)
        var again = PipelineInputGenerator(seed: 7)
        XCTAssertEqual(first.markdownDocument().markdown, again.markdownDocument().markdown)
        XCTAssertEqual(first.plainTextDocument(), again.plainTextDocument())

        var text = ""
        for seed in UInt64(1)...400 {
            var generator = PipelineInputGenerator(seed: seed)
            text += generator.markdownDocument().markdown + "\n"
        }
        let corpus = NSString(string: text)  // one UTF-16 copy for the searches
        let constructs = [
            "[^", "]: ", "&amp;", "|---", "| --- |", "\\*", "\\[", "https://", "ftp://", "](", "![", "][", "<https://",
            "```", "~~~", "    ", "**", "__", "~~", "==", "`", "$$", "$x^2$", "<b>", "<br>", "<!--", "<table>", "[!NOTE]",
            "> > ", "- [x] ", "1. ", "2) ", "\n===", "\n---", "## ", "😀", "🇨🇳", "1️⃣", "，", "。", "……", "二○二四年", "一九○○年", "二〇二四年",
            "これは", "References", "参考资料", "  \n", "\\\n",
        ]
        for construct in constructs {
            var found = 0
            var rest = NSRange(location: 0, length: corpus.length)
            while found < 3 {
                let hit = corpus.range(of: construct, options: .literal, range: rest)
                guard hit.location != NSNotFound else { break }
                found += 1
                rest = NSRange(location: NSMaxRange(hit), length: corpus.length - NSMaxRange(hit))
            }
            XCTAssertEqual(found, 3, "fewer than 3 of \(construct.debugDescription)")
        }
    }

    // MARK: - Helpers

    static let markdownFixtures = [
        "pages/en_wikipedia.md", "pages/zh_wikipedia.md", "pages/hn.md", "pages/zh_tech_blog.md",
        "pages/en_article.md",
    ]
    static let textFixtures = [
        "text/en_crlf.txt", "text/en_hardwrap.txt", "text/zh_novel_singlenl.txt", "text/zh_dialogue.txt", "text/en_notes.txt",
    ]

    /// Runs `property` for every seed and reports the first failures with their seed and input.
    private func checkSeeds(
        _ seeds: ClosedRange<UInt64>, file: StaticString = #filePath, line: UInt = #line,
        _ property: (UInt64) -> (input: String, violations: [String])
    ) {
        var failures = 0
        for seed in seeds {
            let (input, violations) = property(seed)
            guard !violations.isEmpty else { continue }
            failures += 1
            if failures <= 3 {
                XCTFail("seed \(seed):\n  \(violations.prefix(6).joined(separator: "\n  "))\n--- input ---\n\(input.prefix(3000))",
                        file: file, line: line)
            }
        }
        if failures > 3 { XCTFail("\(failures) of \(seeds.count) seeds failed", file: file, line: line) }
    }
}

// MARK: - Invariants

/// What every ReadingDocument keeps, whatever its input (R3-15).
enum PipelineInvariants {
    /// Never left in a display or speak text (contract P7): footnote markers, double-escaped
    /// entities, table rules, URLs as MarkdownCleaner removes them (http, https or ftp, not inside
    /// a word: "rsync://" is prose) and the cleaner's private-use placeholders.
    static let contractLeftovers = #"\[\^|&amp;|\|---|(?<![A-Za-z0-9])(?i:https?|ftp)://|[\x{E000}-\x{F8FF}]"#
    /// In Markdown, also a backslash escape (a backslash before ASCII punctuation).
    static let markdownLeftovers = TextPattern(contractLeftovers + #"|\\[!-/:-@\[-`{-~]"#)
    static let plainTextLeftovers = TextPattern(contractLeftovers)
    /// In the text of a generated input, which has none of these of its own: any backslash or
    /// "://", link and image syntax, fences, emphasis runs, HTML and the entities it writes.
    static let generatedLeftovers = TextPattern(contractLeftovers + #"|\\|://|"# + [
        "](", "\")", "![", "```", "~~~", "**", "__", "~~", "==", "<!--", "-->", "<b>", "</b>", "<em>", "</em>", "<span", "</span>",
        "<kbd>", "</kbd>", "<sup>", "</sup>", "<br", "<a ", "</a>", "<div", "</div>", "<p>", "</p>", "<table", "<script",
        "<svg", "<details", "<summary", "&lt;", "&gt;", "&quot;", "&nbsp;", "&mdash;", "&hellip;", "&copy;", "&rsquo;",
        "&ldquo;", "&middot;", "&euro;", "&#",
    ].map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|"))

    /// Everything wrong with `document`, built with `title`; empty when it keeps every invariant.
    /// `generated`: the input came from `PipelineInputGenerator` (the stricter markup checks);
    /// `markdown`: it was Markdown, where a backslash before punctuation is an escape.
    static func violations(of document: ReadingDocument, title: String?, generated: Bool = true, markdown: Bool = true) -> [String] {
        func leftover(in text: String) -> String? {
            Self.leftover(in: text, generated: generated, markdown: markdown)
        }
        var problems: [String] = []
        func fail(_ message: String) {
            if problems.count < 12 { problems.append(message) }
        }

        // Blocks: their unit ranges tile the units in order; each block is tidy text.
        var nextUnit = 0
        for (blockIndex, block) in document.blocks.enumerated() {
            let label = "block \(blockIndex) (\(block.kind.rawValue)) \(String(block.text.prefix(70)).debugDescription)"
            if block.units.lowerBound != nextUnit {
                fail("\(label): its units start at \(block.units.lowerBound), not \(nextUnit)")
            }
            nextUnit = max(nextUnit, block.units.upperBound)
            if let problem = leftover(in: block.text) { fail("\(label): \(problem)") }
            if block.kind != .title, !MarkdownCleaner.Inline.isSpeakable(block.text) { fail("\(label): nothing to say") }
            let lines = block.text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.contains(where: { $0.isEmpty || $0.first!.isWhitespace || $0.last!.isWhitespace || $0.contains("  ") }) {
                fail("\(label): an empty or untrimmed line, or a run of spaces")
            }

            // Units: in order, inside the block, trimmed, within their sentence's cap.
            let characters = Array(block.text)
            let sentences = SpeechChunker.sentenceRanges(characters)
            var covered = [Bool](repeating: false, count: characters.count)
            var previousEnd = 0
            for index in block.units {
                guard document.units.indices.contains(index) else {
                    fail("\(label): unit \(index) does not exist")
                    continue
                }
                let unit = document.units[index]
                let range = unit.range
                if unit.id != index { fail("unit \(index) has the id \(unit.id)") }
                if unit.block != blockIndex { fail("unit \(index) names block \(unit.block), not \(blockIndex)") }
                if unit.endsBlock != (index == block.units.upperBound - 1) { fail("unit \(index): endsBlock is \(unit.endsBlock)") }
                guard range.lowerBound >= previousEnd, !range.isEmpty, range.upperBound <= characters.count else {
                    fail("\(label): unit \(index) at \(range) overlaps the one before (ending at \(previousEnd)) or leaves the block")
                    continue
                }
                previousEnd = range.upperBound
                for offset in range { covered[offset] = true }
                let display = String(characters[range])
                let excerpt = String(display.prefix(70)).debugDescription
                if document.displayText(of: unit) != display { fail("unit \(index): displayText is not its span") }
                if display.first!.isWhitespace || display.last!.isWhitespace { fail("unit \(index) is not trimmed: \(excerpt)") }
                if !MarkdownCleaner.Inline.isSpeakable(display) { fail("unit \(index) has nothing to say: \(excerpt)") }
                if let sentence = sentences.first(where: { $0.contains(range.lowerBound) }), range.upperBound <= sentence.upperBound {
                    let cap = SpeechChunker.cap(for: characters[sentence])
                    if range.count > cap { fail("unit \(index): \(range.count) characters, over its sentence's cap \(cap)") }
                } else {
                    fail("unit \(index) at \(range) crosses a sentence end: \(excerpt)")
                }

                // Speak text: the span (○ zeros read 零), a title or heading with its stop, at most
                // 3000 scalars; no markup.
                let spoken = SpeechChunker.speechForm(display)
                let allowed = unit.kind == .sentence ? [spoken] : [spoken, spoken + "。", spoken + "."]
                if !allowed.map(SpeechChunker.clamp).contains(unit.speakText) {
                    fail("unit \(index) speaks \(String(unit.speakText.prefix(70)).debugDescription) for \(excerpt)")
                }
                if unit.speakText.unicodeScalars.count > SpeechChunker.maxSpeakCharacters {
                    fail("unit \(index): \(unit.speakText.unicodeScalars.count) scalars")
                }
                if let problem = leftover(in: unit.speakText) { fail("unit \(index): \(problem)") }

                // Language: none only for a script ReadRead does not read; English never holds Han or kana.
                let unsupported = LanguageDetector.verdict(display) == .unsupported
                if (unit.language == nil) != unsupported {
                    fail("unit \(index): language \(unit.language?.rawValue ?? "none") for \(excerpt)")
                }
                if unit.language == .en, LanguageDetector.hasCJKLetters(unit.speakText) {
                    fail("unit \(index) is read in English but holds CJK letters: \(excerpt)")
                }
                let kind: SpeechUnit.Kind = switch block.kind {
                case .title: .title
                case .heading: .heading
                case .paragraph, .listItem, .quote: .sentence
                }
                if unit.kind != kind { fail("unit \(index) is a \(unit.kind.rawValue) in a \(block.kind.rawValue) block") }
            }
            // Every letter and digit is in some unit, and so is a ○ that is read as zero.
            if let lost = characters.indices.first(where: { !covered[$0] && (isSpeakable(characters[$0]) || isCircleZero(characters, at: $0)) }) {
                fail("\(label): \(String(characters[lost]).debugDescription) at \(lost) is in no unit")
            }
        }
        if nextUnit != document.units.count { fail("\(document.units.count) units, but the blocks hold \(nextUnit)") }

        // The title: block 0 when it has any content after cleaning, read once.
        let titleBlocks = document.blocks.indices.filter { document.blocks[$0].kind == .title }
        let cleanedTitle = title.map(DocumentBuilder.cleanTitle) ?? ""
        if cleanedTitle.isEmpty {
            if !titleBlocks.isEmpty { fail("title blocks \(titleBlocks) without a title") }
        } else {
            if titleBlocks != [0] { fail("title blocks \(titleBlocks), not [0]") }
            if document.title != cleanedTitle {
                fail("the document title is \(document.title.debugDescription), not \(cleanedTitle.debugDescription)")
            }
            let key = DocumentBuilder.comparable(cleanedTitle)
            if let first = document.blocks.first, DocumentBuilder.comparable(first.text) != key {
                fail("block 0 is not the title: \(first.text.prefix(70).debugDescription)")
            }
            if document.blocks.count > 1, document.blocks[1].kind != .listItem, DocumentBuilder.comparable(document.blocks[1].text) == key {
                fail("the title is read twice")
            }
        }

        // The content hash: sha256 of the speak texts joined by newlines.
        let joined = document.units.map(\.speakText).joined(separator: "\n")
        let hash = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
        if document.contentHash != hash { fail("the content hash is not the sha256 of the speak texts") }
        return problems
    }

    /// The first markup left in `text`, described; nil when there is none (one regex pass).
    static func leftover(in text: String, generated: Bool, markdown: Bool) -> String? {
        let pattern = generated ? generatedLeftovers : markdown ? markdownLeftovers : plainTextLeftovers
        guard let match = pattern.firstMatch(in: text)?.first else { return nil }
        let name = match.unicodeScalars.map { (0xE000...0xF8FF).contains($0.value) ? String(format: "U+%04X", $0.value) : String($0) }
        return "\(name.joined().debugDescription) left in \(excerpt(text, at: match))"
    }

    static func excerpt(_ text: String, at marker: String) -> String {
        guard let range = text.range(of: marker) else { return String(text.prefix(70)).debugDescription }
        let start = text.index(range.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 30, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end]).debugDescription
    }

    /// A letter or a digit (MarkdownCleaner.Inline.isSpeakable for one character).
    static func isSpeakable(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
    }

    /// A ○ or ◯ in a run of them next to a Chinese numeral (二○二四年, 一九○○年): a zero,
    /// which SpeechChunker.speechForm reads 零. A placeholder (○○公司) is not one.
    static func isCircleZero(_ characters: [Character], at index: Int) -> Bool {
        func isCircle(_ offset: Int) -> Bool { characters[offset] == "○" || characters[offset] == "◯" }
        guard isCircle(index) else { return false }
        var lower = index
        while lower > 0, isCircle(lower - 1) { lower -= 1 }
        var upper = index + 1
        while upper < characters.count, isCircle(upper) { upper += 1 }
        return (lower > 0 && chineseNumerals.contains(characters[lower - 1]))
            || (upper < characters.count && chineseNumerals.contains(characters[upper]))
    }

    static let chineseNumerals: Set<Character> = ["零", "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "两"]
}

// MARK: - Generator

/// SplitMix64: seeded, dependency-free, and the same on every run, machine and Swift version
/// (the standard library does not promise how `random(in:using:)` draws).
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    /// Uniform enough for test inputs (the modulo bias is negligible).
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func chance(_ percent: Int) -> Bool {
        int(1...100) <= percent
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[int(0...(items.count - 1))]
    }
}

/// Markdown and plain text the way pages, files and pasted text come: Chinese, English and both,
/// with the markup MarkdownCleaner removes. What the cleaner leaves alone by design (an emphasis
/// marker between two ASCII letters or digits, a URL glued to a word, `www.` hosts, escapes inside
/// code) is not generated.
struct PipelineInputGenerator {
    struct MarkdownInput {
        let title: String?
        /// Self-contained top-level pieces; `markdown` joins them with a blank line.
        let chunks: [String]

        var markdown: String { chunks.joined(separator: "\n\n") }
    }

    private var random: SeededRandom
    /// Off for plain text and titles, where a backslash and an HTML comment are text.
    private var markdown = true
    /// Between English words: where plain text may be hard-wrapped (never inside a link or a tag).
    private var wordBreak = " "
    private var footnotes: [String] = []
    private var references: [String] = []

    init(seed: UInt64) {
        random = SeededRandom(seed: seed)
    }

    // MARK: Documents

    mutating func markdownDocument(pasted: Bool = false) -> MarkdownInput {
        footnotes = []
        references = []
        let title = documentTitle()
        var chunks: [String] = []
        if let title, random.chance(40) { chunks.append("# " + title) }  // the page repeats its title
        for _ in 0..<random.int(2...12) { chunks.append(chunk(pasted: pasted)) }
        if random.chance(20) { chunks.append(boilerplateSection()) }
        // Definitions at the end, as defuddle.md writes them; the notes may cite further notes.
        var index = 0
        while index < footnotes.count, index < 12 {
            chunks.append(footnoteDefinition(footnotes[index]))
            index += 1
        }
        for label in references { chunks.append(referenceDefinition(label)) }
        return MarkdownInput(title: title, chunks: chunks)
    }

    /// A .txt file or pasted text: a novel with a paragraph per line, or blank-line paragraphs,
    /// some hard-wrapped; CRLF and Unicode paragraph separators now and then.
    mutating func plainTextDocument() -> String {
        markdown = false
        wordBreak = "\u{1F}"
        defer {
            markdown = true
            wordBreak = " "
        }
        let novel = random.chance(40)
        var paragraphs: [String] = []
        for _ in 0..<random.int(2...14) {
            switch random.int(0...19) {
            case 0: paragraphs.append(random.pick(["第一章　开始", "第二章 风起", "Chapter 1", "PART TWO", "一、引言"]))
            case 1: paragraphs.append(random.pick(["• ", "- ", "* "]) + (novel ? chineseSentence() : englishSentence()))
            case 2: paragraphs.append(longSentence())
            case 3: paragraphs.append(random.pick(Self.otherScripts))
            default:
                let indent = novel && random.chance(50) ? "\u{3000}\u{3000}" : ""
                paragraphs.append(indent + paragraph(chinese: novel ? !random.chance(10) : random.chance(20), softBreaks: false))
            }
        }
        var text = paragraphs.joined(separator: novel ? "\n" : "\n\n")
        if !novel, random.chance(40) { text = Self.hardWrap(text, column: random.int(60...78)) }
        text = text.replacingOccurrences(of: "\u{1F}", with: " ")
        switch random.int(0...9) {
        case 0: text = text.replacingOccurrences(of: "\n", with: "\r\n")
        case 1: text = text.replacingOccurrences(of: "\n\n", with: "\u{2029}")
        default: break
        }
        return text
    }

    /// One to three paragraphs, most of them one sentence far over the caps.
    mutating func longParagraphs() -> String {
        var paragraphs: [String] = []
        for _ in 0..<random.int(1...3) {
            paragraphs.append(random.chance(70) ? longSentence() : paragraph(chinese: random.chance(55)))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    // MARK: Blocks

    /// A page title: plain text (no escapes, no comments), sometimes with inline markup.
    mutating func documentTitle() -> String? {
        markdown = false
        defer { markdown = true }
        switch random.int(0...19) {
        case 0...4: return nil
        case 5...14: return headingText()
        case 15, 16:
            return random.pick(["**Bold** title &amp; more 🎉", "语音合成 - 维基百科", "  Spaced   title  ", "Title\nwith a newline",
                                "[Linked](https://example.com) title"])
        case 17: return random.pick(["🎉🎉", "👍", "   "])
        default: return random.pick(["???", "——", "…"])
        }
    }

    mutating func chunk(pasted: Bool) -> String {
        switch random.int(0...99) {
        case 0..<38: return paragraph(chinese: random.chance(55))
        case 38..<48: return heading()
        case 48..<60: return list()
        case 60..<67: return quote()
        case 67..<72: return fencedCode()
        case 72..<75:
            // Pasted text: a first-line indent; a page: a paragraph, then indented code.
            return pasted ? "    " + paragraph(chinese: random.chance(55)) : paragraph(chinese: false) + "\n\n" + indentedCode()
        case 75..<80: return table()
        case 80..<82: return random.pick(Self.displayMath)
        case 82..<86: return htmlBlock()
        case 86..<88: return random.pick(["***", "---", "___", "* * *", "- - -"])
        case 88..<91: return random.pick(Self.otherScripts)
        case 91..<93: return random.pick(["🎉🎉🎉", "👍", "★★★", "→ → →", "……", "——"])
        case 93..<96: return longSentence()
        default: return "\u{3000}\u{3000}" + paragraph(chinese: true)
        }
    }

    mutating func paragraph(chinese: Bool, softBreaks: Bool = true) -> String {
        var text = ""
        for index in 0..<random.int(1...5) {
            // ○ dates only in Markdown: plain text may join a line to an unfinished English one.
            let circleZero = markdown && random.chance(10)
            let sentence = random.chance(15) != chinese ? (circleZero ? circleZeroSentence() : chineseSentence()) : englishSentence()
            if index > 0 {
                switch softBreaks ? random.int(0...19) : 19 {
                case 0, 1: text += "\n"  // a soft line break
                case 2: text += "  \n"  // hard ones
                case 3: text += "\\\n"
                default: text += chinese ? "" : wordBreak
                }
            }
            text += sentence
        }
        if random.chance(8) { text += footnoteReference() }
        return text
    }

    mutating func heading() -> String {
        let text = headingText()
        switch random.int(0...11) {
        case 0: return text + "\n" + String(repeating: "=", count: random.int(3...9))
        case 1: return text + "\n" + String(repeating: "-", count: random.int(3...9))
        case 2: return "## " + text + " ##"
        default: return String(repeating: "#", count: random.int(1...6)) + " " + text
        }
    }

    mutating func headingText() -> String {
        if random.chance(15) {
            return random.pick(["1. 引言", "第一章 风起云涌", "二、方法", "(一) 背景", "Chapter 3", "2.1 Results", "Why it matters?",
                                "总结：", "Q&amp;A"])
        }
        return random.chance(55) ? chineseSentence(end: false, words: 1...4) : englishSentence(end: false, words: 1...6)
    }

    mutating func list() -> String {
        let ordered = random.chance(35)
        let marker = random.pick(["-", "*", "+", "•"])
        var lines: [String] = []
        for index in 0..<random.int(1...5) {
            var item = ordered ? "\(index + 1)\(random.pick([".", ")"])) " : marker + " "
            if !ordered, random.chance(15) { item += random.pick(["[ ] ", "[x] ", "[X] "]) }
            let indent = index > 0 && random.chance(20) ? "  " : ""
            lines.append(indent + item + anySentence())
            if random.chance(10) {
                lines.append("")
                lines.append("  " + anySentence())  // a continuation paragraph
            }
        }
        return lines.joined(separator: "\n")
    }

    mutating func quote() -> String {
        if random.chance(20) {
            return "> [!\(random.pick(["NOTE", "TIP", "WARNING", "IMPORTANT"]))]\n> " + anySentence()
        }
        var lines: [String] = []
        for _ in 0..<random.int(1...3) {
            var content = anySentence()
            if random.chance(10) { content = "- " + content }
            if random.chance(8) { content = "## " + headingText() }
            lines.append((random.chance(20) ? "> > " : "> ") + content)
        }
        return lines.joined(separator: "\n")
    }

    mutating func fencedCode() -> String {
        if random.chance(10) { return "````markdown\n```\ninner https://example.com [^1]\n```\n````" }
        let fence = random.pick(["```", "~~~", "````"])
        var lines = [fence + random.pick(["", "swift", "python", "bash", "json"])]
        for _ in 0..<random.int(1...4) { lines.append(random.pick(Self.codeLines)) }
        lines.append(fence)
        if random.chance(15) { return lines.map { "> " + $0 }.joined(separator: "\n") }  // in a quote
        return lines.joined(separator: "\n")
    }

    mutating func indentedCode() -> String {
        var lines: [String] = []
        for _ in 0..<random.int(1...3) { lines.append("    " + random.pick(Self.codeLines)) }
        return lines.joined(separator: "\n")
    }

    mutating func table() -> String {
        let columns = random.int(2...4)
        let outer = random.chance(70)
        func row(_ cells: [String]) -> String {
            let body = cells.joined(separator: " | ")
            return outer ? "| " + body + " |" : body
        }
        var lines: [String] = []
        lines.append(row((0..<columns).map { _ in random.pick(Self.cells) }))
        lines.append(row((0..<columns).map { _ in random.pick(["---", ":---", "---:", ":---:", "-"]) }))
        for _ in 0..<random.int(0...3) { lines.append(row((0..<columns).map { _ in random.pick(Self.cells) })) }
        return lines.joined(separator: "\n")
    }

    mutating func htmlBlock() -> String {
        switch random.int(0...7) {
        case 0: return "<table>\n<tr><td>Cell https://example.com</td><td>[^1] &amp;</td></tr>\n</table>"
        case 1: return "<script>\nvar a = \"**x** |---| [^1]\";\n</script>"
        case 2: return "<style>\np { color: red; }\n</style>"
        case 3: return "<div class=\"note\">\n" + englishSentence() + "\n</div>"
        case 4: return markdown ? "<!-- a comment\nover https://example.com lines -->" : englishSentence()
        case 5: return "<details>\n<summary>" + headingText() + "</summary>\n\n" + chineseSentence() + "\n\n</details>"
        case 6: return "<p>" + englishSentence() + "<br>" + chineseSentence() + "</p>"
        default: return "<svg width=\"10\"><text>SVG text https://example.com</text></svg>"
        }
    }

    mutating func boilerplateSection() -> String {
        var lines = [random.pick(["## References", "## 参考资料", "## See also", "## 外部链接", "## 參考來源", "## Notes", "## 注释"]), ""]
        for index in 1...random.int(1...4) {
            lines.append("\(index). " + random.pick(["[Source](https://example.com/src)", "https://example.com/a", "某书，某出版社，2020年。",
                                                     "Smith, J. (2020). *A Book*. Publisher."]))
        }
        return lines.joined(separator: "\n")
    }

    mutating func footnoteDefinition(_ label: String) -> String {
        var text = "[^\(label)]: " + anySentence()
        if random.chance(30) { text += "\n    " + anySentence() }  // an indented continuation
        if random.chance(20) { text += "\n" + englishSentence() }  // a lazy one
        if random.chance(20) { text += "\n\n    " + anySentence() }  // a second paragraph
        return text
    }

    mutating func referenceDefinition(_ label: String) -> String {
        "[\(label)]: " + random.pick(["https://example.com/ref", "<https://example.com/ref>", "/local/path"])
            + random.pick(["", " \"Title\"", " 'Title'", " (Title)"])
    }

    /// A sentence far over the caps.
    mutating func longSentence() -> String {
        switch random.int(0...6) {
        case 0: return joinedWords(Self.chinese, 40...120, separator: "")
        case 1: return joinedWords(Self.chinese, 40...120, separator: "，") + "。"
        case 2: return joinedWords(Self.english, 60...160, separator: " ")
        case 3: return joinedWords(Self.letters, 230...700, separator: "")  // one unbreakable word
        case 4: return joinedWords(Self.digits, 230...500, separator: "")
        case 5:
            // Letters under stacks of combining marks: more scalars than the server takes.
            var scalars = String.UnicodeScalarView()
            for _ in 0..<random.int(80...200) {
                scalars.append(contentsOf: random.pick(["a", "e", "o", "u"]).unicodeScalars)
                for _ in 0..<random.int(12...40) { scalars.append(Unicode.Scalar(UInt32(0x0300 + random.int(0...0x6F)))!) }
            }
            return String(scalars)
        default: return joinedWords(Self.chinese + Self.terms, 60...140, separator: " ")
        }
    }

    // MARK: Sentences

    mutating func anySentence() -> String {
        random.chance(55) ? chineseSentence() : englishSentence()
    }

    mutating func chineseSentence(end: Bool = true, words: ClosedRange<Int> = 2...9) -> String {
        var text = ""
        let count = random.int(words)
        for index in 0..<count {
            let word = random.chance(10) ? random.pick(Self.terms) : random.chance(6) ? random.pick(Self.english) : random.pick(Self.chinese)
            Self.append(decorated(word, spaced: false), to: &text)
            Self.append(attachment(spaced: false), to: &text)
            if index < count - 1, random.chance(22) { text += random.pick(["，", "、", "：", "——", "；"]) }
        }
        if end { text += random.pick(["。", "。", "。", "！", "？", "……", "。”", "？」", "！！"]) }
        return text
    }

    /// A date with ○ as its zero and Chinese words only, so the sentence is read in Chinese.
    mutating func circleZeroSentence() -> String {
        random.pick(Self.circleZeroDates) + "，" + joinedWords(Self.chinese, 2...6, separator: "") + "。"
    }

    mutating func englishSentence(end: Bool = true, words: ClosedRange<Int> = 3...22) -> String {
        var pieces: [String] = []
        let count = random.int(words)
        for index in 0..<count {
            var word = random.chance(10) ? random.pick(Self.terms) : random.chance(5) ? random.pick(Self.chinese) : random.pick(Self.english)
            if index == 0 { word = word.prefix(1).uppercased() + word.dropFirst() }
            var piece = decorated(word, spaced: true) + attachment(spaced: true)
            if index < count - 1, random.chance(12) { piece += random.pick([",", ";", ":", " —", " –"]) }
            pieces.append(piece)
        }
        var text = pieces.joined(separator: wordBreak)
        if end { text += random.pick([".", ".", ".", "!", "?", "...", "?!", ".\"", ".)", "…"]) }
        return text
    }

    /// A word as pages mark it up: emphasis, strike, highlight, links of every kind, inline HTML.
    /// `spaced`: English, where spaces surround the word (underscore emphasis needs them).
    mutating func decorated(_ word: String, spaced: Bool) -> String {
        guard random.chance(25) else { return word }
        switch random.int(0...12) {
        case 0: return "**\(word)**"
        case 1: return "*\(word)*"
        case 2: return "***\(word)***"
        case 3: return spaced ? "__\(word)__" : "**\(word)**"
        case 4: return spaced ? "_\(word)_" : "*\(word)*"
        case 5: return "~~\(word)~~"
        case 6: return "==\(word)=="
        case 7: return "[\(word)](\(random.pick(Self.linkTargets)))"
        case 8: return "[\(word)](\(random.pick(Self.linkTargets)) \"\(random.pick(["Title", "Phone (phonetics)", "标题"]))\")"
        case 9: return referenceLink(word)
        case 10:
            return random.pick(["<b>\(word)</b>", "<em>\(word)</em>", "<span class=\"x\">\(word)</span>", "<kbd>\(word)</kbd>",
                                "<a href=\"https://example.com\">\(word)</a>"])
        case 11: return "[**\(word)**](\(random.pick(Self.linkTargets)))"
        default: return "**[\(word)](\(random.pick(Self.linkTargets)))**"
        }
    }

    mutating func referenceLink(_ word: String) -> String {
        switch random.int(0...2) {
        case 0:
            let label = random.pick(["ref1", "Ref 2", "docs", "来源"])
            if !references.contains(label) { references.append(label) }
            return "[\(word)][\(label)]"
        case 1:
            if !references.contains(word) { references.append(word) }
            return "[\(word)][]"
        default:
            if !references.contains(word) { references.append(word) }
            return "[\(word)]"
        }
    }

    /// Markup that follows a word, bringing its own spaces: notes, citations, images, URLs,
    /// entities, escapes, emoji, math, inline HTML, code. Usually nothing.
    mutating func attachment(spaced: Bool) -> String {
        guard random.chance(14) else { return "" }
        let gap = spaced ? " " : ""
        switch random.int(0...13) {
        case 0, 1: return footnoteReference()
        case 2: return random.pick([" [1]", "[2][3]", " [4, 5]", "[6–8]", " [citation needed]", "[来源请求]", "[12]"])
        case 3: return gap + random.pick(Self.images) + gap
        case 4: return " " + random.pick(Self.bareURLs) + " "
        case 5: return spaced ? " (" + random.pick(Self.bareURLs) + ")" : "（" + random.pick(Self.bareURLs) + "）"
        case 6: return gap + random.pick(["<https://example.com/docs>", "<me@example.com>", "<http://localhost:8080/>"]) + gap
        case 7: return gap + entity(spaced: spaced) + gap
        case 8 where markdown: return gap + random.pick(Self.escapes) + gap
        case 9: return gap + random.pick(Self.emoji) + gap
        case 10: return " " + random.pick(["$x^2$", "$\\alpha + \\beta$", "$E = mc^2$", "$a_{i}$", "$$\\sum_{i=1}^{n} i$$"]) + " "
        case 11: return random.pick(markdown ? ["<br>", "<br/>", " <!-- note --> ", "<sup>[9]</sup>"] : ["<br>", "<sup>[9]</sup>"])
        case 12: return gap + random.pick(Self.codeSpans) + gap
        default: return spaced ? "" : random.pick(Self.bareURLs)  // glued to Chinese text: 访问https://a.com了解
        }
    }

    mutating func footnoteReference() -> String {
        let label = random.pick(["1", "2", "3", "note", "a-1", "注1", "ref_4"])
        if !footnotes.contains(label) { footnotes.append(label) }
        return "[^\(label)]"
    }

    mutating func entity(spaced: Bool) -> String {
        spaced
            ? random.pick(["&amp;", "AT&amp;T", "x &lt; y", "a &gt; b", "&quot;quoted&quot;", "&#39;tis", "&nbsp;", "&mdash;", "&hellip;",
                           "&copy; 2024", "it&rsquo;s", "&#8212;", "&#x2014;", "&euro;5"])
            : random.pick(["&amp;", "&#x4E2D;&#x6587;", "&#20013;&#25991;", "&ldquo;引号&rdquo;", "&middot;", "&hellip;", "&nbsp;"])
    }

    private mutating func joinedWords(_ vocabulary: [String], _ count: ClosedRange<Int>, separator: String) -> String {
        var result: [String] = []
        for _ in 0..<random.int(count) { result.append(random.pick(vocabulary)) }
        return result.joined(separator: separator)
    }

    /// Chinese glue: nothing between CJK text, a space between two ASCII characters (2024**iPhone**
    /// is no emphasis, and a URL must not run into the next word).
    private static func append(_ next: String, to text: inout String) {
        if let last = text.unicodeScalars.last, let first = next.unicodeScalars.first, last.isASCII, first.isASCII,
           !last.properties.isWhitespace, !first.properties.isWhitespace {
            text += " "
        }
        text += next
    }

    /// Wraps at the word breaks only (U+001F), so no link, tag or emphasis is cut.
    static func hardWrap(_ text: String, column: Int) -> String {
        text.components(separatedBy: "\n").map { line in
            var lines: [String] = []
            var current = ""
            for word in line.components(separatedBy: "\u{1F}") {
                if !current.isEmpty, current.count + 1 + word.count > column {
                    lines.append(current)
                    current = ""
                }
                current += (current.isEmpty ? "" : " ") + word
            }
            lines.append(current)
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: Vocabulary

    static let chinese = [
        "语音合成", "是一种", "把文字", "变成声音的技术", "我们", "今天", "讨论", "人工智能", "机器学习", "这个问题", "非常重要", "在北京",
        "上海的", "春天", "来了", "小明说", "老师和学生", "图书馆里", "一杯咖啡", "新的电脑", "手机", "城市", "历史", "文化", "经济发展",
        "模型", "数据", "系统", "用户", "程序", "网络", "研究人员", "发现", "因此", "然而", "例如", "但是", "所以", "可以", "已经", "开始",
        "朗读", "文章", "句子", "标点符号", "中文", "英文", "两种语言", "阅读器", "菜单栏", "声音", "速度", "第一次", "最后", "一九九八年",
        "二〇二四年", "十月一日", "三点五", "百分之五十", "很多人", "认为", "鲁迅", "《呐喊》", "「引号」", "（括号）", "龍與鳳", "臺灣的書",
    ]
    /// Dates with ○ as their zero, only ever in sentences of Chinese words: a piece read in
    /// English drops the ○ (TextPipelineKnownIssueTests.testACircleZeroInChineseInsideEnglishTextIsRead).
    static let circleZeroDates = ["二○二四年十月一日", "一九○○年", "二○○八年八月", "公元二○二○年"]
    static let english = [
        "speech", "synthesis", "the", "system", "converts", "written", "text", "into", "audio", "a", "model", "voice", "reader",
        "reads", "Mandarin", "and", "English", "of", "in", "to", "with", "for", "data", "time", "people", "world", "research",
        "language", "machine", "learning", "network", "neural", "every", "sentence", "paragraph", "page", "quickly", "slowly",
        "today", "first", "last", "small", "large", "Apple", "Silicon", "menu", "bar", "server", "client", "request", "token",
        "word", "clear", "café", "naïve", "résumé", "don't", "it's",
    ]
    /// Names, numbers and abbreviations: what sentence splitting must get right.
    static let terms = [
        "Kokoro", "ONNX", "macOS", "iPhone", "Python 3.12", "Swift 6", "GPT-4", "API", "HTTP/2", "C++", "Node.js", "Wi-Fi",
        "COVID-19", "the U.S.", "e.g. this", "i.e. that", "Dr. Smith", "Mr. Li", "No. 7", "St. Louis", "J. R. R. Tolkien",
        "a Ph.D.", "3.14", "1,000", "12:30", "v1.2.3", "2024", "50%", "¥199", "the 1990s", "example.com", "x < y", "a > b",
        "Yahoo!Japan", "etc.", "Fig. 3", "pp. 12–15",
    ]
    static let otherScripts = [
        "これは日本語の文章です。", "ひらがなとカタカナが混ざった文です。", "한국어 문장입니다.", "Это предложение на русском языке.",
        "Ελληνικά κείμενα εδώ.", "ภาษาไทย", "مرحبا بالعالم",
    ]
    static let emoji = ["😀", "👍🏽", "🇨🇳", "👨‍👩‍👧", "1️⃣", "✅", "★", "→", "•", "✓", "🎉", "❤️", "⭐", "#️⃣"]
    static let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)
    static let digits = "0123456789".map(String.init)
    static let linkTargets = [
        "https://example.com/page", "https://en.wikipedia.org/wiki/Speech_(disambiguation)", "/docs/intro", "#section-2",
        "https://example.com/search?q=a&amp;b=2", "<https://example.com/a b>", "https://zh.wikipedia.org/wiki/语音合成",
    ]
    static let bareURLs = [
        "https://example.com", "https://example.com/a?b=1&c=2", "https://en.wikipedia.org/wiki/Phone_(phonetics)",
        "http://localhost:8080/path", "https://mp.weixin.qq.com/s/AbCdEf", "ftp://files.example.com/a.zip",
        "https://example.com/a_b_c.html#part",
    ]
    static let images = [
        "![alt text](https://img.example.com/a.png)", "![图片](https://example.com/图.png \"标题\")",
        "[![badge](https://img.shields.io/badge/x.svg)](https://ci.example.com)", "![](https://example.com/empty.png)",
        "![ref image][logo]",
    ]
    static let escapes = [
        "\\*", "\\_", "\\#", "\\[note\\]", "\\(", "\\)", "\\!", "\\.", "\\-", "\\+", "\\>", "\\|", "\\`", "\\~", "\\=", "\\$5",
        "1\\. not a list", "\\*not emphasis\\*",
    ]
    static let codeSpans = [
        "`npm install`", "`git status`", "`rsync -av`", "`print()`", "`README.md`", "`user_id`", "`x + y`", "`` a`b ``",
        "`let x = 1`", "`--verbose`", "`数组`",
    ]
    static let codeLines = [
        "let url = \"https://example.com/api?a=1&amp;b=2\"", "print(\"**not bold** [^1] |---|\")",
        "// \\* escaped \\_ <b>tag</b> $x^2$", "for i in 0..<10 { total += i }", "    indented() ~~~ ==mark==",
        "SELECT * FROM t WHERE a = 1;", "中文注释：不读出来 https://example.com",
    ]
    static let cells = [
        "名称", "说明", "Name", "Value", "https://example.com", "**粗体**", "`code`", "a \\| b", "[link](https://x.com)", "&amp;",
        "1,000", "😀", "[^1]", "",
    ]
    static let displayMath = [
        "$$\n\\frac{a}{b} = c\n$$", "$$ x^2 + y^2 = z^2 $$", "$$\n\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}\n$$", "  $$\n  E = mc^2\n  $$",
    ]
}
