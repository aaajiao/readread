import Foundation

/// Which word of the playing unit is being spoken: the engine's token timings placed on the
/// unit's display text, for the reading view's word highlight.
///
/// Tokens come in synthesized time, the time `AudioOutput.currentTime` runs in, so a unit played
/// time-stretched needs no conversion. Their text is what the front end read, which is not always
/// what is shown: numbers come back spelled out ("2024年" → 二零二 四年), abbreviations expanded
/// ("Dr." → Doctor), Traditional Chinese as Simplified. Matching is sequential on the surface: the
/// chain of tokens found in order in the display text with the most matched characters wins (case,
/// width and accents ignored, Traditional folded to Simplified, a Latin token only on word
/// boundaries). Tokens in between are spread proportionally over the words of the display text
/// left between their matched neighbours. No tokens (the system voice) → no words, and the reading
/// view highlights the sentence alone.
struct WordTimeline: Equatable, Sendable {
    struct Word: Equatable, Sendable {
        /// Character offsets in the unit's display text.
        let range: Range<Int>
        let start: Double
        let end: Double
        /// Found on the surface; false = placed proportionally between found neighbours.
        let matched: Bool
    }

    /// In speaking order; a word with nothing on the surface to show is left out.
    let words: [Word]

    /// The last word stays highlighted this long after its end (the unit's pause follows).
    static let lastWordHold = 0.25

    /// Per character of gap between consecutive matches: prefers the nearest of equal chains.
    private static let gapPenalty = 0.001

    init(words: [Word]) {
        self.words = words
    }

    init(tokens: [TimedSpan], displayText: String) {
        let timed = tokens.enumerated()
            .filter { $0.element.start.isFinite && $0.element.end.isFinite && $0.element.end >= $0.element.start }
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        guard !timed.isEmpty, !displayText.isEmpty else {
            self.init(words: [])
            return
        }
        let display = Array(displayText)
        let surface = Self.foldedSurface(displayText)
        let folded = timed.map { Self.foldedToken($0.text) }
        let matches = Self.longestChain(tokens: folded, surface: surface, display: display)

        var ranges = [Range<Int>?](repeating: nil, count: timed.count)
        for (index, range) in matches { ranges[index] = range }
        // Runs of unmatched tokens share the display text between their matched neighbours.
        var index = 0
        while index < timed.count {
            guard ranges[index] == nil else {
                index += 1
                continue
            }
            var end = index
            while end < timed.count, ranges[end] == nil { end += 1 }
            let gapStart = index > 0 ? ranges[index - 1]!.upperBound : 0
            let gapEnd = end < timed.count ? ranges[end]!.lowerBound : display.count
            let placed = Self.spread(weights: folded[index..<end].map { max(1, $0.count) },
                                     over: Self.segments(display, gapStart..<max(gapStart, gapEnd)))
            for (offset, range) in placed.enumerated() { ranges[index + offset] = range }
            index = end
        }

        var words: [Word] = []
        let matched = Set(matches.map(\.token))
        for (index, token) in timed.enumerated() {
            guard let range = ranges[index], !range.isEmpty else { continue }
            words.append(Word(range: range, start: token.start, end: token.end, matched: matched.contains(index)))
        }
        self.init(words: words)
    }

    /// The word being spoken `time` seconds into the unit's audio (synthesized time): the last one
    /// that started, until the next one starts; nil before the first and after the last.
    func word(at time: Double) -> Word? {
        guard let first = words.first, time >= first.start else { return nil }
        var low = 0
        var high = words.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if words[mid].start <= time { low = mid } else { high = mid - 1 }
        }
        if low == words.count - 1, time > words[low].end + Self.lastWordHold { return nil }
        return words[low]
    }

    // MARK: - Folding

    /// One folded string per display Character (so offsets stay Character offsets).
    static func foldedSurface(_ text: String) -> [String] {
        let characters = Array(text)
        // The engine reads Traditional Chinese as Simplified; fold per character when the
        // transform keeps the length (it does for single characters).
        let simplified = text.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false).map(Array.init)
        let source = simplified?.count == characters.count ? simplified! : characters
        return source.map(fold)
    }

    static func foldedToken(_ text: String) -> [String] {
        Array(text.trimmingCharacters(in: .whitespacesAndNewlines)).map(fold)
    }

    static func fold(_ character: Character) -> String {
        switch character {
        case "’", "‘", "ʼ", "′": return "'"
        case "“", "”", "″": return "\""
        case "‐", "‑", "‒", "–", "—", "−": return "-"
        default:
            return String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                             locale: nil)
        }
    }

    // MARK: - Surface matching

    /// A letter or digit of a script that separates words with spaces (not Han, kana, Hangul).
    static func isWordCharacter(_ character: Character) -> Bool {
        guard character.isLetter || character.isNumber else { return false }
        return !isCJK(character)
    }

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x2FDF, 0x3005...0x3007, 0x3021...0x3029, 0x3040...0x30FF, 0x3100...0x312F, 0x31A0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x3134F:
            return true
        default:
            return false
        }
    }

    /// Where `token` occurs on the surface; a token starting (ending) with a Latin letter or digit
    /// only where no such character comes right before (after) it.
    static func occurrences(of token: [String], in surface: [String], display: [Character]) -> [Int] {
        guard !token.isEmpty, token.count <= surface.count else { return [] }
        let checksStart = token.first.flatMap(\.first).map(isWordCharacter) ?? false
        let checksEnd = token.last.flatMap(\.last).map(isWordCharacter) ?? false
        var starts: [Int] = []
        for start in 0...(surface.count - token.count) {
            guard surface[start] == token[0] else { continue }
            var equal = true
            for offset in 1..<token.count where surface[start + offset] != token[offset] {
                equal = false
                break
            }
            guard equal else { continue }
            let end = start + token.count
            if checksStart, start > 0, isWordCharacter(display[start - 1]) { continue }
            if checksEnd, end < display.count, isWordCharacter(display[end]) { continue }
            starts.append(start)
        }
        return starts
    }

    /// The chain of (token, occurrence) pairs, in token order and left to right without overlap,
    /// with the most matched characters (the nearest chain of equal ones). A prefix-maximum tree
    /// over end positions keeps it O(occurrences · log length).
    static func longestChain(tokens: [[String]], surface: [String], display: [Character]) -> [(token: Int, range: Range<Int>)] {
        struct Node {
            let token: Int
            let range: Range<Int>
            let previous: Int?
        }
        var nodes: [Node] = []
        var tree = PrefixMaximum(size: surface.count + 1)
        tree.update(at: 0, value: 0, node: nil)  // the start of the text
        for (index, token) in tokens.enumerated() {
            let weight = Double(token.count)
            var found: [(end: Int, value: Double, node: Int)] = []
            for start in occurrences(of: token, in: surface, display: display) {
                let (best, previous) = tree.maximum(through: start)
                let end = start + token.count
                // score + gapPenalty * end, so the next match's gap costs gapPenalty per character.
                let value = best + weight - gapPenalty * Double(start) + gapPenalty * Double(end)
                nodes.append(Node(token: index, range: start..<end, previous: previous))
                found.append((end, value, nodes.count - 1))
            }
            // A token's own occurrences never chain onto each other.
            for match in found { tree.update(at: match.end, value: match.value, node: match.node) }
        }
        var chain: [(token: Int, range: Range<Int>)] = []
        var cursor = tree.maximum(through: surface.count).node
        while let index = cursor {
            chain.append((nodes[index].token, nodes[index].range))
            cursor = nodes[index].previous
        }
        return chain.reversed()
    }

    /// Prefix maximum (with the node holding it) over positions 0...size-1 (a Fenwick tree).
    private struct PrefixMaximum {
        private var values: [Double]
        private var nodes: [Int?]

        init(size: Int) {
            values = Array(repeating: -.infinity, count: size + 1)
            nodes = Array(repeating: nil, count: size + 1)
        }

        mutating func update(at position: Int, value: Double, node: Int?) {
            var i = position + 1
            while i < values.count {
                if value > values[i] {
                    values[i] = value
                    nodes[i] = node
                }
                i += i & -i
            }
        }

        /// The maximum over positions 0...position.
        func maximum(through position: Int) -> (value: Double, node: Int?) {
            var best = -Double.infinity
            var node: Int?
            var i = min(position + 1, values.count - 1)
            while i > 0 {
                if values[i] > best {
                    best = values[i]
                    node = nodes[i]
                }
                i -= i & -i
            }
            return (best, node)
        }
    }

    // MARK: - Proportional fallback

    /// The words of `range` in `display`: runs of letters and digits (with . , - ' : / inside, as
    /// in 3.5, 4:30, e-book), and each Han, kana or Hangul character or symbol on its own;
    /// whitespace and punctuation separate them.
    static func segments(_ display: [Character], _ range: Range<Int>) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var runStart: Int?
        var index = range.lowerBound
        func closeRun(at end: Int) {
            if let start = runStart { result.append(start..<end) }
            runStart = nil
        }
        while index < range.upperBound {
            let character = display[index]
            if isWordCharacter(character) {
                if runStart == nil { runStart = index }
            } else if runStart != nil, ".,-'’:/_".contains(character), index + 1 < range.upperBound,
                      isWordCharacter(display[index + 1]) {
                // Inside a run: 3.5, e-book, don't.
            } else {
                closeRun(at: index)
                if isCJK(character) || character.unicodeScalars.contains(where: {
                    $0.properties.generalCategory == .mathSymbol || $0.properties.generalCategory == .currencySymbol
                        || $0.properties.generalCategory == .otherSymbol
                }) {
                    result.append(index..<index + 1)
                }
            }
            index += 1
        }
        closeRun(at: range.upperBound)
        return result
    }

    /// Each weighted token gets the segments whose middle falls in its share of the total; a token
    /// whose share holds no middle gets the segment under the middle of its share.
    static func spread(weights: [Int], over segments: [Range<Int>]) -> [Range<Int>?] {
        guard !segments.isEmpty else { return Array(repeating: nil, count: weights.count) }
        let tokenTotal = Double(weights.reduce(0, +))
        let segmentWeights = segments.map { Double($0.count) }
        let segmentTotal = segmentWeights.reduce(0, +)
        var middles: [Double] = []
        var running = 0.0
        for weight in segmentWeights {
            middles.append((running + weight / 2) / segmentTotal)
            running += weight
        }
        var result: [Range<Int>?] = []
        var shareStart = 0.0
        for (index, weight) in weights.enumerated() {
            let shareEnd = index == weights.count - 1 ? 1.0 : shareStart + Double(weight) / tokenTotal
            var chosen = middles.indices.filter { middles[$0] >= shareStart && middles[$0] < shareEnd }
            if index == weights.count - 1 { chosen = middles.indices.filter { middles[$0] >= shareStart } }
            if chosen.isEmpty {
                let middle = (shareStart + shareEnd) / 2
                var cumulative = 0.0
                var under = segments.count - 1
                for (segment, weight) in segmentWeights.enumerated() {
                    cumulative += weight / segmentTotal
                    if middle < cumulative {
                        under = segment
                        break
                    }
                }
                chosen = [under]
            }
            result.append(segments[chosen.first!].lowerBound..<segments[chosen.last!].upperBound)
            shareStart = shareEnd
        }
        return result
    }
}
