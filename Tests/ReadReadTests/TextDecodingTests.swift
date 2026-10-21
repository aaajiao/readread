import XCTest

@testable import ReadRead

/// Local files in the encodings they come in (H10, R4-05). The fixtures are written by
/// Fixtures/encodings/make_encodings.py with Python's own codecs; these are its texts.
final class TextDecodingTests: XCTestCase {
    private let chinese = "第一章　风起\n　　天色渐暗，城门外的老槐树下站着一个少年。他叫林风，今年十六岁。\n"
        + "　　“你终于来了。”一个苍老的声音从身后传来。\n第二章　夜行\n　　夜色如墨，林风沿着山路一直向北走去。\n"
    private let traditional = "第一章　風起\n　　天色漸暗，城門外的老槐樹下站著一個少年。\n"
    private let traditionalLong = "第二章　夜行\n　　夜色如墨，林風沿著山路一直向北走去。他沒有回頭，因為他知道，身後的城門已經關上了。\n"
    private let western = "Café naïve résumé — “smart quotes” and €5.\n"
    private let apostrophes = "I don’t know. It’s fine.\n\nIt’s a long story—really. We’ll see what’s next.\n\nThe author didn’t say.\n"
    private let midword = "Die Brücke über den Fluss führt nach Zürich. Müller und Jürgen gehen hinüber.\n\nNotes on façade design.\n"

    private func decode(_ fixture: String) throws -> TextDecoding.Decoded {
        try TextDecoding.decode(try Fixtures.data("encodings/\(fixture)"))
    }

    func testByteOrderMarksDecideAndAreDropped() throws {
        XCTAssertEqual(try decode("utf8_bom.txt"), .init(text: chinese, encoding: "utf-8"))
        XCTAssertEqual(try decode("utf16le_bom.txt"), .init(text: chinese, encoding: "utf-16le"))
        XCTAssertEqual(try decode("utf16be_bom.txt"), .init(text: chinese, encoding: "utf-16be"))
        let utf32 = Data([0xFF, 0xFE, 0x00, 0x00]) + "Hi 你好".data(using: .utf32LittleEndian)!
        XCTAssertEqual(try TextDecoding.decode(utf32), .init(text: "Hi 你好", encoding: "utf-32le"))
        let utf32be = Data([0x00, 0x00, 0xFE, 0xFF]) + "Hi 你好".data(using: .utf32BigEndian)!
        XCTAssertEqual(try TextDecoding.decode(utf32be), .init(text: "Hi 你好", encoding: "utf-32be"))
    }

    func testStrictUTF8() throws {
        XCTAssertEqual(try decode("utf8.txt"), .init(text: chinese, encoding: "utf-8"))
        XCTAssertEqual(try TextDecoding.decode(Data()), .init(text: "", encoding: "utf-8"))
    }

    /// A control character is no reason to doubt valid UTF-8 (it made accented English GB18030
    /// mojibake, read with the Chinese voice); it is dropped, or a line break for VT and FF.
    func testValidUTF8WithControlCharactersStaysUTF8() throws {
        let text = "The café served crème brûlée to naïve résumé writers.\u{0B}Señor Müller agreed.\u{07}\u{1B}\u{0C}End\u{0}"
        XCTAssertEqual(try TextDecoding.decode(Data(text.utf8)),
                       .init(text: "The café served crème brûlée to naïve résumé writers.\nSeñor Müller agreed.\n\nEnd", encoding: "utf-8"))
        var page = Data(try Fixtures.text("pages/hn.md").utf8)
        page.insert(0x1B, at: try XCTUnwrap(page.firstIndex(of: 0x0A)) + 1)
        XCTAssertEqual(try TextDecoding.decode(page).encoding, "utf-8", "the HN page with an ESC in it")
        XCTAssertEqual(TextDecoding.sanitize("\u{FEFF}a\r\nb\u{7F}c"), "a\nbc")
    }

    /// UTF-8 but for a few bad bytes is UTF-8, the bad bytes U+FFFD: a file cut inside its
    /// last character, or a novel with one GBK line appended.
    func testMostlyValidUTF8IsUTF8() throws {
        let novel = try Fixtures.text("text/zh_novel_singlenl.txt")
        var cut = Data(novel.utf8)
        while let last = cut.last, last < 0x80 { cut.removeLast() }
        cut.removeLast()
        let truncated = try TextDecoding.decode(cut)
        XCTAssertEqual(truncated.encoding, "utf-8")
        XCTAssertTrue(novel.hasPrefix(truncated.text) && truncated.text.count + 3 >= novel.count, "only the cut character goes")
        var mixed = Data(novel.utf8)
        mixed.append(try XCTUnwrap("\n后记：这一行是 GBK。\n".data(using: TextDecoding.gb18030)))
        let decoded = try TextDecoding.decode(mixed)
        XCTAssertEqual(decoded.encoding, "utf-8")
        XCTAssertTrue(decoded.text.hasPrefix(novel))
        XCTAssertTrue(decoded.text.contains("\u{FFFD}"))
        let line = Data("天色渐暗，城门外的老槐树下站着一个少年。他叫林风，今年十六岁。".utf8)
        XCTAssertEqual(try TextDecoding.decode(line.dropLast()), .init(text: "天色渐暗，城门外的老槐树下站着一个少年。他叫林风，今年十六岁", encoding: "utf-8"))
        XCTAssertEqual(try TextDecoding.decode(Data("Résumé".utf8).dropLast()), .init(text: "Résum", encoding: "utf-8"))
        XCTAssertEqual(try decode("gbk.txt").encoding, "gb18030", "GBK has no valid multi-byte UTF-8 runs")
    }

    func testChineseLegacyEncodings() throws {
        XCTAssertEqual(try decode("gb18030.txt"), .init(text: chinese, encoding: "gb18030"))
        XCTAssertEqual(try decode("gbk.txt"), .init(text: chinese, encoding: "gb18030"), "GBK is a subset of GB18030")
        XCTAssertEqual(try decode("big5.txt"), .init(text: traditional, encoding: "big5"))
        XCTAssertEqual(try decode("big5_long.txt"), .init(text: traditional + traditionalLong, encoding: "big5"),
                       "Windows' Big5 (CP950)")
    }

    func testUTF16WithoutAByteOrderMarkByItsZeroBytes() throws {
        let text = "Plain ASCII heavy text, " + chinese
        XCTAssertEqual(try decode("utf16le.txt"), .init(text: text, encoding: "utf-16le"))
        XCTAssertEqual(try decode("utf16be.txt"), .init(text: text, encoding: "utf-16be"))
        // Chinese: its few NULs (newlines, U+3000, 一) do not tell the byte order; the score does.
        XCTAssertEqual(try decode("utf16le_zh.txt"), .init(text: chinese, encoding: "utf-16le"))
        XCTAssertEqual(try decode("utf16be_zh.txt"), .init(text: chinese, encoding: "utf-16be"))
        let fewZeros = try XCTUnwrap((String(repeating: "天色渐暗，城门外的老槐树下站着少年。", count: 8) + "\n结束。\n").data(using: .utf16LittleEndian))
        XCTAssertEqual(try TextDecoding.decode(fewZeros).encoding, "utf-16le", "two NUL bytes in 300")
    }

    func testWindows1252() throws {
        XCTAssertEqual(try decode("cp1252.txt"), .init(text: western, encoding: "windows-1252"))
        // Each curly quote or accented letter before a letter is a valid GBK pair: a lone Han
        // character between Latin letters ("don抰", "Br點ke") gives that reading away.
        XCTAssertEqual(try decode("cp1252_apostrophes.txt"), .init(text: apostrophes, encoding: "windows-1252"))
        XCTAssertEqual(try decode("cp1252_midword.txt"), .init(text: midword, encoding: "windows-1252"))
        for text in ["I don’t know. It’s fine.", "Notes on façade design", "Zürich", "Müller, Jürgen",
                     "Crème brûlée recipe\n\nMix the crème with sugar."] {
            let data = try XCTUnwrap(text.data(using: .windowsCP1252))
            XCTAssertEqual(try TextDecoding.decode(data), .init(text: text, encoding: "windows-1252"), text)
        }
        let document = DocumentBuilder.fromPlainText(apostrophes, title: nil, source: .text, sourceLabel: "")
        XCTAssertEqual(Set(document.units.map(\.language)), [.en])
    }

    func testNewlinesBecomeLF() throws {
        XCTAssertEqual(try decode("crlf_utf8.txt").text, "Para one line one.\nPara one line two.\n\nPara two.\n")
        XCTAssertEqual(try decode("cr_gbk.txt"), .init(text: "第一行。\n第二行。\n", encoding: "gb18030"))
        XCTAssertEqual(TextDecoding.normalizeNewlines("a\r\nb\rc\n"), "a\nb\nc\n")
        XCTAssertEqual(TextDecoding.normalizeNewlines("---\r\ntitle: x\r\n"), "---\ntitle: x\n",
                       "\"\\r\\n\" is one Character: the check looks at bytes")
        XCTAssertEqual(TextDecoding.normalizeNewlines("no returns"), "no returns")
    }

    func testShiftJISIsNotReadAsGarbageChinese() throws {
        // Shift_JIS is no candidate, and GB18030 would decode it into rare Han characters.
        XCTAssertTrue(TextDecoding.mostlyGBKExtension(try Fixtures.data("encodings/shift_jis.txt")))
        XCTAssertThrowsError(try decode("shift_jis.txt")) { error in
            XCTAssertEqual(error as? TextDecoding.Failure, .notText)
        }
        for fixture in ["gbk.txt", "gb18030.txt", "big5.txt", "big5_long.txt", "cr_gbk.txt"] {
            XCTAssertFalse(TextDecoding.mostlyGBKExtension(try Fixtures.data("encodings/\(fixture)")), fixture)
        }
        // Traditional Chinese written in GBK (old e-books) is still GB18030.
        let gbkTraditional = try XCTUnwrap((traditional + traditionalLong).data(using: TextDecoding.gb18030))
        XCTAssertFalse(TextDecoding.mostlyGBKExtension(gbkTraditional))
        XCTAssertEqual(try TextDecoding.decode(gbkTraditional).text, traditional + traditionalLong)
    }

    func testBinaryDataIsNotText() {
        let binary = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
        XCTAssertThrowsError(try TextDecoding.decode(binary)) { error in
            XCTAssertEqual(error as? TextDecoding.Failure, .notText)
        }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
            + Data(repeating: 0, count: 64) + Data((0..<512).map { UInt8($0 % 251) })
        XCTAssertThrowsError(try TextDecoding.decode(png))
    }

    func testScoringPrefersThePlausibleReading() {
        XCTAssertGreaterThan(TextDecoding.score("天色渐暗，城门外的老槐树下站着一个少年。"), 0.9)
        XCTAssertGreaterThan(TextDecoding.score("我们用Swift写了一个应用。"), 0.9, "Han next to Latin in a run is no stray")
        XCTAssertLessThan(TextDecoding.score("I don抰 know. It抯 fine."), TextDecoding.score("I don’t know. It’s fine."))
        XCTAssertGreaterThan(TextDecoding.score("Plain English text, nothing odd."), 0.9)
        XCTAssertLessThan(TextDecoding.score("\u{1}\u{2}\u{3}\u{FFFD}\u{FFFD}abc"), TextDecoding.minimumScore)
        XCTAssertLessThan(TextDecoding.score("Ã©Ã¨Ã¼Â«Â»"), TextDecoding.score("éèü«»"), "mojibake scores lower")
    }

    func testTheFailureExplainsItself() {
        XCTAssertEqual(TextDecoding.Failure.notText.errorDescription,
                       "This file is not text in an encoding ReadRead knows (UTF-8, UTF-16, GB18030/GBK, Big5 or Windows-1252).")
    }
}
