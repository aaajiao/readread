import Foundation

/// Bytes of a local text file → text (H10, R4-05). A byte-order mark decides first; then
/// UTF-16 by its NUL bytes; then UTF-8, strict or with a few bad sequences; then the legacy
/// encodings Chinese and Western files come in (GB18030, Big5, UTF-16 with few NULs,
/// Windows-1252), each scored so that the plausible reading wins. CRLF and CR become LF, the
/// BOM is dropped and control characters go (see `sanitize`).
enum TextDecoding {
    struct Decoded: Equatable, Sendable {
        let text: String
        /// Short encoding name, for diagnostics and tests: "utf-8", "gb18030", "big5",
        /// "utf-16le", "utf-16be", "utf-32le", "utf-32be", "windows-1252".
        let encoding: String
    }

    enum Failure: LocalizedError, Equatable {
        /// No candidate gives plausible text (binary data, or an encoding ReadRead doesn't know).
        case notText

        var errorDescription: String? {
            "This file is not text in an encoding ReadRead knows "
                + "(UTF-8, UTF-16, GB18030/GBK, Big5 or Windows-1252)."
        }
    }

    /// Below this score (see `score`) the best candidate is still not believable text.
    static let minimumScore = 0.3
    /// Characters scored per candidate; enough to tell encodings apart, cheap on 1 MB novels.
    static let scoreSample = 100_000
    /// UTF-8 with bad sequences is still UTF-8 while its valid multi-byte characters outnumber
    /// them this many times (a GBK line pasted into a UTF-8 novel).
    static let lossyUTF8Ratio = 50

    static func decode(_ data: Data) throws -> Decoded {
        if data.isEmpty { return Decoded(text: "", encoding: "utf-8") }
        if let (bom, encoding, name) = byteOrderMark(of: data),
           let text = String(data: data.dropFirst(bom), encoding: encoding) {
            return Decoded(text: sanitize(text), encoding: name)
        }
        // NUL bytes in a twentieth of the data: UTF-16 (every ASCII character has one), which
        // is also valid UTF-8 when it is mostly ASCII.
        if let decoded = utf16WithoutBOM(data) {
            return Decoded(text: sanitize(decoded.text), encoding: decoded.encoding)
        }
        // Valid UTF-8 is UTF-8: legacy encodings practically never produce valid multi-byte
        // UTF-8 by accident. A stray control character (a word processor's U+000B) is dropped,
        // not a reason to read the file as GB18030; mostly-control data scores too low.
        if let text = String(data: data, encoding: .utf8), score(text) >= minimumScore {
            return Decoded(text: sanitize(text), encoding: "utf-8")
        }
        if let text = mostlyUTF8(data) { return Decoded(text: sanitize(text), encoding: "utf-8") }
        var best: (decoded: Decoded, score: Double)?
        for (encoding, name) in candidates(for: data) {
            guard let text = String(data: data, encoding: encoding) else { continue }
            let value = score(text)
            // Ties keep the earlier candidate (the order above is the order of likelihood).
            if best == nil || value > best!.score {
                best = (Decoded(text: text, encoding: name), value)
            }
        }
        guard let best, best.score >= minimumScore else { throw Failure.notText }
        return Decoded(text: sanitize(best.decoded.text), encoding: best.decoded.encoding)
    }

    /// CRLF and lone CR → LF (R5-13: CRLF files otherwise break frontmatter and paragraphs).
    static func normalizeNewlines(_ text: String) -> String {
        // Not `text.contains("\r")`: that compares Characters, and "\r\n" is one Character.
        guard text.utf8.contains(UInt8(ascii: "\r")) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Decoded text as the cleaners expect it: LF newlines, no BOM, and no control characters
    /// but tab and newline (a vertical tab is a line break, a form feed a paragraph break; the
    /// others are dropped). Also for defuddle.md's UTF-8 responses.
    static func sanitize(_ text: String) -> String {
        var text = normalizeNewlines(text)
        if text.hasPrefix("\u{FEFF}") { text = String(text.unicodeScalars.dropFirst()) }
        guard text.utf8.contains(where: { ($0 < 0x20 && $0 != 0x09 && $0 != 0x0A) || $0 == 0x7F }) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0B: scalars.append("\n")
            case 0x0C: scalars.append(contentsOf: "\n\n".unicodeScalars)
            case 0x09, 0x0A: scalars.append(scalar)
            case 0x00...0x1F, 0x7F: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    // MARK: - Candidates

    static let gb18030 = encoding(.GB_18030_2000)
    /// CP950, the Big5 variant Windows writes (a superset of plain Big5).
    static let big5 = encoding(.dosChineseTrad)

    private static func encoding(_ cf: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
    }

    /// (BOM length, encoding, name). UTF-32 LE is checked before UTF-16 LE: FF FE 00 00 starts both.
    static func byteOrderMark(of data: Data) -> (Int, String.Encoding, String)? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return (4, .utf32LittleEndian, "utf-32le") }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return (4, .utf32BigEndian, "utf-32be") }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return (3, .utf8, "utf-8") }
        if bytes.starts(with: [0xFF, 0xFE]) { return (2, .utf16LittleEndian, "utf-16le") }
        if bytes.starts(with: [0xFE, 0xFF]) { return (2, .utf16BigEndian, "utf-16be") }
        return nil
    }

    /// GB18030 (unless the bytes are mostly GBK's rare-character area), Big5, UTF-16 when a
    /// few NUL bytes hint at it, Windows-1252.
    static func candidates(for data: Data) -> [(String.Encoding, String)] {
        var list: [(String.Encoding, String)] = []
        if !mostlyGBKExtension(data) { list.append((gb18030, "gb18030")) }
        list.append((big5, "big5"))
        list.append(contentsOf: utf16Candidates(data))
        list.append((.windowsCP1252, "windows-1252"))
        return list
    }

    /// GB18030 decodes nearly any bytes, Shift_JIS (Japanese) among them, into Han
    /// characters, which would then score as Chinese. Real GBK text is mostly GB2312 (lead
    /// bytes 0xA1–0xF7); Shift_JIS kana and common kanji land in GBK's extension area for
    /// rare characters (lead bytes 0x81–0xA0). Traditional Chinese in GBK stays well under
    /// the threshold: its common characters are shared with GB2312.
    static func mostlyGBKExtension(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(64 * 1024))
        var pairs = 0
        var extensionArea = 0
        var index = 0
        while index + 1 < bytes.count {
            let lead = bytes[index]
            guard (0x81...0xFE).contains(lead) else {
                index += 1
                continue
            }
            if (0x30...0x39).contains(bytes[index + 1]) {
                index += 4  // a four-byte GB18030 sequence
                continue
            }
            pairs += 1
            if lead <= 0xA0 { extensionArea += 1 }
            index += 2
        }
        return pairs >= 8 && extensionArea * 10 > pairs * 6
    }

    /// NUL bytes in the first 64 KB, at even and at odd offsets.
    private static func nulParity(_ data: Data) -> (even: Int, odd: Int) {
        var even = 0, odd = 0
        for (index, byte) in data.prefix(64 * 1024).enumerated() where byte == 0 {
            if index % 2 == 0 { even += 1 } else { odd += 1 }
        }
        return (even, odd)
    }

    static let utf16Orders: [(String.Encoding, String)] = [(.utf16LittleEndian, "utf-16le"), (.utf16BigEndian, "utf-16be")]

    /// Text files have no NUL bytes; UTF-16 text has one in every ASCII character (at least
    /// 5% of the bytes). Both byte orders are scored, the one with the NULs in the high byte
    /// first: in Chinese text U+3000 and U+4E00 put NULs in the low byte too.
    static func utf16WithoutBOM(_ data: Data) -> Decoded? {
        guard data.count >= 2, data.count % 2 == 0 else { return nil }
        let (even, odd) = nulParity(data)
        let sampled = min(data.count, 64 * 1024)
        guard (even + odd) * 20 >= sampled else { return nil }
        var best: (decoded: Decoded, score: Double)?
        for (encoding, name) in odd >= even ? utf16Orders : utf16Orders.reversed() {
            guard let text = String(data: data, encoding: encoding) else { continue }
            let value = score(text)
            if value >= minimumScore, best == nil || value > best!.score { best = (Decoded(text: text, encoding: name), value) }
        }
        return best?.decoded
    }

    /// Chinese UTF-16 has NUL bytes only in its few ASCII characters (newlines) and a few
    /// others (U+3000, 一 U+4E00), too few for `utf16WithoutBOM`: with any NUL bytes at all,
    /// both byte orders whose text has a newline or a space are candidates, and the score
    /// picks (the wrong order gives characters from all over Unicode).
    static func utf16Candidates(_ data: Data) -> [(String.Encoding, String)] {
        guard data.count >= 4, data.count % 2 == 0 else { return [] }
        let (even, odd) = nulParity(data)
        guard even + odd >= 2 else { return [] }
        return utf16Orders.filter { encoding, _ in
            guard let text = String(data: data, encoding: encoding) else { return false }
            return text.unicodeScalars.prefix(scoreSample).contains { $0 == "\n" || $0 == " " }
        }
    }

    /// UTF-8 but for a few bytes: a file cut off inside its last character, or one with a few
    /// bad sequences among many good multi-byte characters (a line pasted in from a GBK file).
    /// The bad sequences stay as U+FFFD (shown; the server drops them).
    static func mostlyUTF8(_ data: Data) -> String? {
        for cut in 1...3 where data.count > cut {
            let tail = data.suffix(cut)
            guard let lead = tail.first, lead >= 0xC2, tail.allSatisfy({ $0 >= 0x80 }),
                  let text = String(data: data.dropLast(cut), encoding: .utf8) else { continue }
            return score(text) >= minimumScore ? text : nil
        }
        let text = String(decoding: data, as: UTF8.self)
        var bad = 0
        var multibyte = 0
        for scalar in text.unicodeScalars {
            if scalar == "\u{FFFD}" { bad += 1 } else if scalar.value > 0x7F { multibyte += 1 }
        }
        guard multibyte >= 8, bad * lossyUTF8Ratio <= multibyte, score(text) >= minimumScore else { return nil }
        return text
    }

    // MARK: - Scoring

    /// −4…1 per character, averaged: replacement and control characters count heavily
    /// against, private-use characters and the symbols a wrong legacy decoding typically
    /// produces (Latin-1 symbols, kana, Greek, Cyrillic, box drawing, bopomofo) somewhat
    /// against; Han, ASCII, CJK and general punctuation for; accented Latin half for. A Han
    /// character on its own next to a Latin letter ("don抰", "Z黵ich": Windows-1252 read as
    /// GBK, every accented letter or curly quote taking the letter after it) counts against.
    static func score(_ text: String) -> Double {
        let scalars = Array(text.unicodeScalars.prefix(scoreSample))
        guard !scalars.isEmpty else { return 0 }
        var points = 0.0
        for (index, scalar) in scalars.enumerated() {
            switch scalar.value {
            case 0x09, 0x0A, 0x0C, 0x0D, 0x20...0x7E: points += 1
            case 0x00...0x1F, 0x7F...0x9F, 0xFFFD: points -= 4
            case 0xA0...0xBF: points -= 0.5
            case 0xC0...0x24F: points += 0.5
            case 0x4E00...0x9FFF: points += isStrayHan(scalars, at: index) ? -1 : 1
            case 0x2000...0x206F, 0x3000...0x303F, 0xFF00...0xFFEF: points += 1
            case 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x3FFFF: points += 0.5
            case 0xE000...0xF8FF, 0xF0000...0x10FFFF: points -= 2
            case 0x0370...0x04FF, 0x2500...0x257F, 0x3040...0x30FF, 0x3100...0x312F, 0x02B0...0x02FF: points -= 0.5
            default: break
            }
        }
        return points / Double(scalars.count)
    }

    /// No CJK neighbour on either side, and an ASCII letter on one: real Chinese text has its
    /// Han characters in runs ("用Swift写了" has 用 and 写 next to other Han characters).
    static func isStrayHan(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let before = index > 0 ? scalars[index - 1] : nil
        let after = index + 1 < scalars.count ? scalars[index + 1] : nil
        func latinLetter(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar, scalar.isASCII else { return false }
            return scalar.properties.isAlphabetic
        }
        guard !MarkdownCleaner.Inline.isCJK(before), !MarkdownCleaner.Inline.isCJK(after) else { return false }
        return latinLetter(before) || latinLetter(after)
    }
}
