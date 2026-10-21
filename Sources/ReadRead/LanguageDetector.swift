import Foundation

/// Which pipeline reads a piece of text, from a census of its letters by script (R3-09,
/// replacing NLLanguageRecognizer, which labels short or mixed Chinese lines French or
/// English). Han vs Latin decides between zh and en; kana, Hangul, Cyrillic, Arabic, Thai
/// and other scripts ReadRead cannot read make a unit unsupported when they dominate it.
enum LanguageDetector {
    struct Census: Equatable, Sendable {
        var han = 0
        var latin = 0
        /// Hiragana and katakana; `hiragana` counts the first again.
        var kana = 0
        var hiragana = 0
        /// Letters of every other script (Hangul, Cyrillic, Greek, Arabic, Hebrew, Thai, Devanagari, …).
        var other = 0
        var digits = 0

        var letters: Int { han + latin + kana + other }
    }

    enum Verdict: Equatable, Sendable {
        case zh
        case en
        /// Some Han, but under `hanShare` of the letters: read in the document's language.
        case mixed
        /// Only digits: read in the document's language.
        case digitsOnly
        /// Nothing to say, or a script ReadRead does not read.
        case unsupported
    }

    /// A unit whose letters are at least this share Han is Chinese: the zh pipeline reads
    /// embedded English words, the en pipeline cannot read Han.
    static let hanShare = 0.3

    static func census<S: StringProtocol>(_ text: S) -> Census {
        var census = Census()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x30...0x39:
                census.digits += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
                if value != 0xD7, value != 0xF7 { census.latin += 1 }
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF, 0x3007:
                census.han += 1
            case 0x3040...0x309F:
                census.kana += 1
                census.hiragana += 1
            case 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                if value != 0x30FB, value != 0x30FC { census.kana += 1 }  // ・ and ー are shared punctuation
            default:
                if scalar.properties.isAlphabetic, value > 0x24F { census.other += 1 }
                else if scalar.properties.numericType == .decimal { census.digits += 1 }
            }
        }
        return census
    }

    static func verdict<S: StringProtocol>(_ text: S) -> Verdict {
        verdict(census(text))
    }

    static func verdict(_ census: Census) -> Verdict {
        if census.letters == 0 { return census.digits > 0 ? .digitsOnly : .unsupported }
        if isJapanese(census) { return .unsupported }
        if census.other + census.kana > census.han + census.latin { return .unsupported }
        if census.han == 0 { return census.latin > 0 ? .en : .unsupported }
        let share = Double(census.han) / Double(census.letters)
        return share >= hanShare ? .zh : .mixed
    }

    /// Japanese: hiragana (particles, okurigana) in a fifth or more of the CJK characters, or
    /// kana outnumbering Han where CJK outnumbers Latin (a katakana title). Katakana alone in a
    /// Chinese sentence is a loanword (我喜欢玩ポケモン游戏): the zh pipeline reads the Han
    /// characters and drops the kana. Two or fewer kana ("我の世界") never decide.
    static func isJapanese(_ census: Census) -> Bool {
        guard census.kana >= 3 else { return false }
        if census.hiragana >= 2, census.hiragana * 5 >= census.han + census.kana { return true }
        return census.kana >= census.han && census.kana + census.han >= census.latin
    }

    /// Han or kana: what the en pipeline cannot read (espeak says "Chinese letter" for each).
    static func hasCJKLetters<S: StringProtocol>(_ text: S) -> Bool {
        text.unicodeScalars.contains { isCJKLetter($0) }
    }

    static func isCJKLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF, 0x3007,
             0x3040...0x309F, 0x30A0...0x30FA, 0x30FD...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
            return true
        default:
            return false
        }
    }

    /// The character-weighted majority of the decided units (zh when there are none):
    /// `weights` are (language, character count) pairs.
    static func documentLanguage(_ weights: [(SpeechLanguage, Int)]) -> SpeechLanguage {
        var zh = 0
        var en = 0
        for (language, count) in weights {
            switch language {
            case .zh: zh += count
            case .en: en += count
            }
        }
        return en > zh ? .en : .zh
    }

    /// A unit's language once the document's is known.
    static func language(of verdict: Verdict, document: SpeechLanguage) -> SpeechLanguage? {
        switch verdict {
        case .zh: .zh
        case .en: .en
        case .mixed, .digitsOnly: document
        case .unsupported: nil
        }
    }
}
