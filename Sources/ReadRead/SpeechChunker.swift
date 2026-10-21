import Foundation

/// Splits a block's text into speech units (R3-03): sentences, with long ones cut at clause
/// punctuation, then at whitespace, so the first audio comes fast and no request is long.
/// Ranges are Character offsets into the block text (for highlighting); the text between
/// units (spaces, newlines) belongs to none.
enum SpeechChunker {
    /// The server rejects text over 4000 characters; a unit's speak text never exceeds this.
    static let maxSpeakCharacters = 3000
    /// About 23 s of Chinese and 14 s of English audio (measured 5.2 and 15.4 characters/s).
    static let chineseCap = 120
    static let englishCap = 220

    struct Piece: Equatable, Sendable {
        /// Character offsets into the block text.
        let range: Range<Int>
        let text: String
    }

    // MARK: - Sentence ends

    static let chineseEnds: Set<Character> = ["。", "！", "？", "；", "…", "‼", "⁇", "⁈", "⁉"]
    static let latinEnds: Set<Character> = [".", "!", "?"]
    static let closers: Set<Character> = ["”", "’", "\"", "'", "」", "』", "）", ")", "】", "》", "〉", "］", "]", "〕"]
    static let clauseBreaks: Set<Character> = ["，", "、", "；", "：", ",", ";", ":", "—", "–", "﹐", "､"]

    /// Abbreviations after which a period never ends a sentence (a name follows).
    static let titles: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "gen", "col", "lt", "sgt", "capt", "cmdr", "adm",
        "rev", "hon", "mt", "messrs", "mme", "mlle",
    ]
    /// Abbreviations after which a period ends a sentence only before a capital letter.
    static let abbreviations: Set<String> = [
        "etc", "cf", "vs", "al", "inc", "ltd", "co", "corp", "no", "nos", "fig", "figs", "vol", "vols", "pp",
        "p", "ed", "eds", "approx", "est", "dept", "univ", "jan", "feb", "mar", "apr", "jun", "jul", "aug",
        "sep", "sept", "oct", "nov", "dec", "viz", "ca", "ch", "sec", "eq", "eqs", "ref", "refs", "ibid", "op",
        "min", "max", "avg", "incl", "b", "c", "d", "fl",  // born, circa, died, floruit: "(d. 1003 AD)"
    ]

    /// The sentences of `text`, each at most `cap` characters (see `cap(for:)`), trimmed.
    /// Fragments with nothing to say ("……", a lone dash) belong to no unit.
    static func pieces(of text: String) -> [Piece] {
        let characters = Array(text)
        var result: [Piece] = []
        for sentence in sentenceRanges(characters) {
            let cap = cap(for: characters[sentence])
            for range in split(sentence, in: characters, cap: cap) {
                guard let trimmed = trim(range, in: characters) else { continue }
                let piece = Piece(range: trimmed, text: String(characters[trimmed]))
                if MarkdownCleaner.Inline.isSpeakable(piece.text) { result.append(piece) }
            }
        }
        return result
    }

    static func cap<C: Collection<Character>>(for characters: C) -> Int {
        let census = LanguageDetector.census(String(characters))
        return census.han > 0 && Double(census.han) >= Double(census.letters) * LanguageDetector.hanShare
            ? chineseCap : englishCap
    }

    static func sentenceRanges(_ characters: [Character]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\n" {
                if start < index { ranges.append(start..<index) }
                index += 1
                start = index
                continue
            }
            guard chineseEnds.contains(character) || latinEnds.contains(character) else {
                index += 1
                continue
            }
            // The run of end marks ("?!", "……", "...") and the closing quotes after it.
            var end = index + 1
            while end < characters.count, chineseEnds.contains(characters[end]) || latinEnds.contains(characters[end]) {
                end += 1
            }
            while end < characters.count, closers.contains(characters[end]) { end += 1 }
            if endsSentence(characters, markStart: index, runEnd: end) {
                ranges.append(start..<end)
                start = end
            }
            index = end
        }
        if start < characters.count { ranges.append(start..<characters.count) }
        return ranges
    }

    /// Whether the end marks at `markStart..<runEnd` close a sentence.
    static func endsSentence(_ characters: [Character], markStart: Int, runEnd: Int) -> Bool {
        let marks = characters[markStart..<runEnd]
        let following = characters[runEnd...].first { !$0.isWhitespace }
        let lowercaseFollows = following.map { $0.isLowercase && $0.isASCII } ?? false
        if marks.contains(where: chineseEnds.contains) {
            // Chinese marks need no space after them; only "…" before a lowercase word
            // continues an English sentence.
            return !(marks.allSatisfy { $0 == "…" } && lowercaseFollows)
        }
        // After . ! ?: the end of the text, a space, or CJK text. A letter or digit right
        // after the mark means 3.14, e.g., example.com, Yahoo!Japan.
        if runEnd < characters.count, !characters[runEnd].isWhitespace, !isCJK(characters[runEnd]) {
            return false
        }
        guard marks.first == "." else { return true }  // ! and ?
        if lowercaseFollows { return false }
        let word = wordBefore(characters, at: markStart)
        if word.count == 1, word.first?.isUppercase == true, word.first?.isASCII == true {
            return false  // an initial: J. R. R. Tolkien
        }
        let key = word.lowercased()
        // Titles precede a name; dotted abbreviations (U.S., e.g., Ph.D.) rarely end one.
        if titles.contains(key) || key.contains(".") { return false }
        if abbreviations.contains(key) {
            guard let following else { return true }
            return following.isUppercase || isCJK(following)
        }
        return true
    }

    /// Latin letters and inner periods right before `index` ("e.g" for "e.g.", "G" in
    /// "语言学家G."): Han characters are letters too, but no part of an abbreviation.
    static func wordBefore(_ characters: [Character], at index: Int) -> String {
        var start = index
        while start > 0, (characters[start - 1].isLetter && !isCJK(characters[start - 1])) || characters[start - 1] == "." {
            start -= 1
        }
        return String(characters[start..<index])
    }

    static func isCJK(_ character: Character) -> Bool {
        MarkdownCleaner.Inline.isCJK(character.unicodeScalars.first)
    }

    // MARK: - Long sentences

    /// Cut `range` into pieces of at most `cap` characters, as even as the text allows (no
    /// stub of a word left at the end): each cut goes at the clause break nearest an even
    /// share, else at the nearest whitespace, else at any clause break, else hard.
    static func split(_ range: Range<Int>, in characters: [Character], cap: Int) -> [Range<Int>] {
        guard range.count > cap else { return [range] }
        var result: [Range<Int>] = []
        var start = range.lowerBound
        while range.upperBound - start > cap {
            let remaining = range.upperBound - start
            let target = start + remaining / ((remaining + cap - 1) / cap)
            var clause: Int?
            var space: Int?
            // A piece is start..<cut; it holds at least a quarter of the cap.
            for cut in (start + max(1, cap / 4))...(start + cap) {
                let character = characters[cut - 1]
                if clauseBreaks.contains(character), !isBetweenDigits(characters, cut - 1) {
                    if clause.map({ abs($0 - target) > abs(cut - target) }) ?? true { clause = cut }
                } else if character.isWhitespace {
                    if space.map({ abs($0 - target) > abs(cut - target) }) ?? true { space = cut }
                }
            }
            let end: Int
            if let clause, abs(clause - target) <= cap / 3 {
                end = clause
            } else {
                end = space ?? clause ?? target
            }
            result.append(start..<end)
            start = end
        }
        result.append(start..<range.upperBound)
        return result
    }

    /// 1,000 and 12:30 are not clause breaks.
    static func isBetweenDigits(_ characters: [Character], _ index: Int) -> Bool {
        index > 0 && index + 1 < characters.count
            && characters[index - 1].isNumber && characters[index + 1].isNumber
    }

    static func trim(_ range: Range<Int>, in characters: [Character]) -> Range<Int>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, characters[lower].isWhitespace { lower += 1 }
        while upper > lower, characters[upper - 1].isWhitespace { upper -= 1 }
        return lower < upper ? lower..<upper : nil
    }

    // MARK: - Script runs

    /// `piece` cut into its CJK runs (Han or kana with the CJK punctuation, spaces and digits
    /// between and attached to them: "（鲁迅）", "1881年") and the text around them, trimmed;
    /// runs with nothing to say ("(", "; ") are left out. Ranges stay block offsets.
    static func scriptRuns(of piece: Piece) -> [(piece: Piece, isCJK: Bool)] {
        let characters = Array(piece.text)
        func isLetter(_ index: Int) -> Bool { characters[index].unicodeScalars.contains(where: LanguageDetector.isCJKLetter) }
        func isAttached(_ index: Int) -> Bool {
            let character = characters[index]
            return !character.isWhitespace && (isCJK(character) || (character.isASCII && character.isNumber))
        }
        var spans: [Range<Int>] = []
        var index = 0
        while index < characters.count {
            guard isLetter(index) else {
                index += 1
                continue
            }
            var start = index
            var end = index + 1
            var probe = end
            // On through CJK marks, spaces and digits as long as another CJK letter follows.
            while probe < characters.count, isAttached(probe) || characters[probe].isWhitespace {
                if isLetter(probe) { end = probe + 1 }
                probe += 1
            }
            while start > (spans.last?.upperBound ?? 0), isAttached(start - 1) { start -= 1 }
            while end < characters.count, isAttached(end) { end += 1 }
            spans.append(start..<end)
            index = end
        }
        var runs: [(piece: Piece, isCJK: Bool)] = []
        func add(_ range: Range<Int>, isCJK: Bool) {
            guard let trimmed = trim(range, in: characters) else { return }
            let text = String(characters[trimmed])
            guard MarkdownCleaner.Inline.isSpeakable(text) else { return }
            let offset = piece.range.lowerBound
            runs.append((Piece(range: (trimmed.lowerBound + offset)..<(trimmed.upperBound + offset), text: text), isCJK))
        }
        var cursor = 0
        for span in spans {
            add(cursor..<span.lowerBound, isCJK: false)
            add(span, isCJK: true)
            cursor = span.upperBound
        }
        add(cursor..<characters.count, isCJK: false)
        return runs
    }

    // MARK: - Speak text

    /// A ○ used as zero in a Chinese number (二○二四年, 一九○○年) and 〇 are read 零: the server
    /// drops ○ as a symbol and has no reading for 〇. Placeholders (○○公司) stay as they are.
    static func speechForm(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value == 0x3007 || $0.value == 0x25CB || $0.value == 0x25EF }) else {
            return text
        }
        let zeros = circleZeros.replace(in: text) { groups in String(repeating: "零", count: groups[0].count) }
        return zeros.replacingOccurrences(of: "〇", with: "零")
    }

    static let circleZeros = TextPattern(#"(?<=[零〇一二三四五六七八九十两])[○◯]+|[○◯]+(?=[零〇一二三四五六七八九十两])"#)

    static let terminalMarks: Set<Character> = ["。", "！", "？", "；", "…", ".", "!", "?", ";", "：", ":"]

    /// A heading or the title gets a stop when it has none, so it is read as a phrase of
    /// its own (the display text is unchanged).
    static func withTerminalStop(_ text: String, language: SpeechLanguage?) -> String {
        guard let last = text.last else { return text }
        if terminalMarks.contains(last) { return text }
        if closers.contains(last), text.dropLast().last.map(terminalMarks.contains) == true { return text }
        return text + (language == .zh ? "。" : ".")
    }

    /// The server counts code points; clamp pathological combining sequences.
    static func clamp(_ text: String) -> String {
        guard text.unicodeScalars.count > maxSpeakCharacters else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(maxSpeakCharacters))
        return String(scalars)
    }
}
