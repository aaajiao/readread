import AppKit
import XCTest

@testable import ReadRead

/// Every `ReadableFileType` through `DocumentReader` and `DocumentLoader` (Fixtures/formats,
/// made by make_formats.sh; Fixtures/html). Without Defuddle here (the system's HTML reader for
/// .html); LocalExtractorTests runs Defuddle on the same pages.
final class DocumentReaderTests: XCTestCase {
    private func reader(defuddle: String? = nil, limits: DocumentReader.Limits = .init(), unpack: URL? = nil) throws -> DocumentReader {
        DocumentReader(defuddleScript: { defuddle },
                       webKitOptions: LocalExtractor.Options(rulesDirectory: try makeTemporaryDirectory()),
                       unpackDirectory: try unpack ?? makeTemporaryDirectory().appending(path: "epub"), limits: limits)
    }

    private func load(_ fixture: String, with reader: DocumentReader) async throws -> ReadingDocument {
        let loader = DocumentLoader(fetchPage: { _ in throw URLError(.notConnectedToInternet) },
                                    readFile: { try await reader.read($0) })
        return try await loader.load(.file(Fixtures.url(fixture)))
    }

    private func speech(_ document: ReadingDocument) -> [String] { document.units.map(\.speakText) }

    private func assertFails(_ fixture: String, with reader: DocumentReader, file: StaticString = #filePath, line: UInt = #line,
                             _ expected: DocumentReadError) async {
        do {
            _ = try await load(fixture, with: reader)
            XCTFail("\(fixture): expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DocumentReadError, expected, "\(fixture)", file: file, line: line)
        }
    }

    /// RTF, RTFD, Word (.doc, .docx) and OpenDocument made by textutil from one page: the same
    /// document from each, headings, lists (Word's markers dropped), table cells, the References
    /// section dropped.
    /// What every textutil document made from source.html says.
    private static let sampleSpeech = [
        "A Short History of Talking Machines.", "Speech synthesis is the artificial production of human speech.",
        "A computer system used for this purpose is called a speech synthesizer.", "Early machines.",
        "Long before electronic signal processing, inventors built machines that imitated the human voice with bellows, reeds and leather tubes.",
        "The acoustic-mechanical speech machine of the eighteenth century.", "The Voder, shown at the 1939 World's Fair.",
        "语音合成。", "语音合成是通过机械的、电子的方法产生人造语音的技术。", "它把文字转换成可以听懂的声音。", "第一步，分析文本。", "第二步，生成波形。",
        "Concatenative synthesis joins recorded units.", "Neural synthesis generates the waveform.",
    ]

    func testTextDocumentsReadTheSameFromEveryFormat() async throws {
        let reader = try reader()
        let expected = Self.sampleSpeech
        for name in ["sample.rtf", "sample.rtfd", "sample.doc", "sample.docx", "sample.odt"] {
            let document = try await load("formats/\(name)", with: reader)
            XCTAssertEqual(speech(document), expected, name)
            XCTAssertEqual(document.title, "A Short History of Talking Machines", name)
            XCTAssertEqual(document.sourceLabel, name)
            XCTAssertEqual(document.blocks.map(\.kind).filter { $0 == .listItem }.count, 4, name)
            XCTAssertEqual(document.blocks.map(\.kind).filter { $0 == .heading }.count, 3, name)
            XCTAssertEqual(Set(document.units.compactMap(\.language)), [.en, .zh], name)
        }
    }

    /// A .doc that holds HTML or RTF (office suites' and web sites' "Word" exports) is read as
    /// what it holds (F19).
    func testADocFileIsReadAsWhatItHolds() async throws {
        let reader = try reader()
        for name in ["html_inside.doc", "rtf_inside.doc"] {
            let document = try await load("formats/\(name)", with: reader)
            XCTAssertEqual(speech(document), Self.sampleSpeech, name)
            XCTAssertEqual(document.blocks.map(\.kind).filter { $0 == .listItem }.count, 4, name)
        }
        XCTAssertEqual(AttributedTextReader.docContent(of: Fixtures.url("formats/sample.doc")), .word)
        XCTAssertEqual(AttributedTextReader.docContent(of: Fixtures.url("formats/html_inside.doc")), .html)
        XCTAssertEqual(AttributedTextReader.docContent(of: Fixtures.url("formats/rtf_inside.doc")), .rtf)
        XCTAssertEqual(AttributedTextReader.docContent(of: Fixtures.url("formats/sample.docx")), .officeOpenXML)
        func content(_ text: String, bom: [UInt8] = []) -> AttributedTextReader.DocContent {
            AttributedTextReader.docContent(Data(bom) + Data(text.utf8))
        }
        XCTAssertEqual(content("  \n<html><body>x</body></html>"), .html)
        XCTAssertEqual(content("<!DOCTYPE html><p>x</p>", bom: [0xEF, 0xBB, 0xBF]), .html)
        XCTAssertEqual(content("{\\rtf1\\ansi x}"), .rtf)
        XCTAssertEqual(content(#"<?xml version="1.0"?><w:wordDocument xmlns:w="http://schemas.microsoft.com/office/word/2003/wordml">"#),
                       .wordML)
        XCTAssertEqual(content(#"<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml">"#), .html)
        XCTAssertEqual(content("Plain words, nothing else."), .unknown)
        let utf16 = Data([0xFF, 0xFE]) + "<html><body>x</body></html>".data(using: .utf16LittleEndian)!
        XCTAssertEqual(AttributedTextReader.docContent(utf16), .html)
    }

    /// A document's own "Notes" and "注释" are the author's and are read; its References go. On a
    /// web page both are boilerplate (F15).
    func testADocumentKeepsItsOwnNotes() async throws {
        let blocks: [MarkdownCleaner.Block] = [
            .init(kind: .heading(1), text: "Report"), .init(kind: .paragraph, text: "The report's first paragraph."),
            .init(kind: .heading(2), text: "Notes"), .init(kind: .listItem, text: "一个中文列表项"),
            .init(kind: .paragraph, text: "The closing paragraph ends the section."),
            .init(kind: .heading(2), text: "注释"), .init(kind: .paragraph, text: "作者自己的注释。"),
            .init(kind: .heading(2), text: "References"), .init(kind: .paragraph, text: "A cited work, not read."),
        ]
        XCTAssertEqual(DocumentReader.finish(blocks, characterLimit: 10_000, headings: MarkdownCleaner.citationHeadings).map(\.text), [
            "Report", "The report's first paragraph.", "Notes", "一个中文列表项", "The closing paragraph ends the section.", "注释", "作者自己的注释。",
        ])
        XCTAssertEqual(DocumentReader.finish(blocks, characterLimit: 10_000).map(\.text), ["Report", "The report's first paragraph."])

        // Through the reader: an RTF document whose headings are known only by their size.
        let heading = [NSAttributedString.Key.font: NSFont.boldSystemFont(ofSize: 24)]
        let body = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 12)]
        let text = NSMutableAttributedString()
        for (line, attributes) in [("Report\n", heading), ("The report's first paragraph.\n", body), ("Notes\n", heading),
                                   ("The author's own note is read.\n", body), ("References\n", heading),
                                   ("A cited work, not read.\n", body)] {
            text.append(NSAttributedString(string: line, attributes: attributes))
        }
        let data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let file = try makeTemporaryDirectory().appending(path: "report.rtf")
        try data.write(to: file)
        let read = try await reader().read(file)
        XCTAssertEqual(read.blocks?.map(\.text), ["Report", "The report's first paragraph.", "Notes", "The author's own note is read."])
    }

    /// HTML beyond the importer's limit, not well-formed, without Defuddle: libxml2's HTML parser
    /// reads it with its structure, off the main thread, which the importer would hold for about a
    /// second a megabyte (F11).
    @MainActor
    func testALargeHTMLFileIsReadOffTheMainThread() async throws {
        var html = "<html><head><title>Large Page</title></head><body>\n"
        for section in 1...100 {
            html += "<h2>Section \(section)</h2>\n"
            for paragraph in 1...80 {
                html += "<p>Paragraph \(paragraph) of section \(section) is long enough to make this page large, <b>bold & open\n"
            }
        }
        XCTAssertGreaterThan(html.utf8.count, 2 * AttributedTextReader.importerLimit)
        let file = try makeTemporaryDirectory().appending(path: "large.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        let reader = try reader()
        let meter = Task { @MainActor () -> Duration in
            var longest = Duration.zero
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ContinuousClock.now
                longest = max(longest, now - last)
                last = now
            }
            return longest
        }
        let loader = DocumentLoader(fetchPage: { _ in throw URLError(.notConnectedToInternet) }, readFile: { try await reader.read($0) })
        let document = try await loader.load(.file(file))
        meter.cancel()
        let longest = await meter.value
        XCTAssertEqual(document.title, "Large Page")
        XCTAssertEqual(document.blocks.filter { $0.kind == .heading }.count, 100)
        XCTAssertEqual(document.blocks.filter { $0.kind == .paragraph }.count, 8_000)
        XCTAssertTrue(document.blocks.contains { $0.text == "Paragraph 80 of section 100 is long enough to make this page large, bold & open" })
        XCTAssertLessThan(longest, .milliseconds(300), "the main actor was held for \(longest)")
    }

    /// Running header and "Page N of 3" gone, hyphenated line ends joined, a paragraph running on
    /// across a page break, headings by font size, a bulleted list, References dropped.
    func testAPDFBecomesParagraphs() async throws {
        let document = try await load("formats/paper.pdf", with: try reader())
        XCTAssertEqual(document.title, "Talking Machines: A Fixture Paper")
        XCTAssertEqual(document.units.count, 19)
        XCTAssertEqual(Array(speech(document).prefix(5)), [
            "Talking Machines: A Fixture Paper.", "1.", "Introduction.", "Speech synthesis is the artificial production of human speech.",
            "A computer system used for this purpose is called a speech synthesizer, and it can be implemented in software or in hardware.",
        ])
        let text = document.blocks.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("other systems render symbolic linguistic representations"), "de-hyphenated")
        XCTAssertTrue(text.contains("Alternatively, a synthesizer can incorporate a model"), "one paragraph across the page break")
        XCTAssertFalse(text.contains("ReadRead Fixtures"), "the running header")
        XCTAssertFalse(text.contains("Page 2"), "the page numbers")
        XCTAssertFalse(text.contains("must not be read"), "the References section")
        XCTAssertEqual(document.blocks.filter { $0.kind == .listItem }.map(\.text), [
            "The acoustic-mechanical speech machine of Wolfgang von Kempelen.", "The Voder, exhibited at the 1939 New York World's Fair.",
        ])
        XCTAssertEqual(document.blocks.filter { $0.kind == .heading }.map(\.text), ["1. Introduction", "2. History", "3. Conclusion"])
    }

    /// CJK lines join without a space, also across the page break; a word processor's title
    /// ("Microsoft Word - ….docx") is not used.
    func testAChinesePDFJoinsItsLines() async throws {
        let document = try await load("formats/zh.pdf", with: try reader())
        XCTAssertEqual(document.title, "语音合成简介", "the first heading, not the metadata title")
        XCTAssertEqual(speech(document), [
            "语音合成简介。", "语音合成是通过机械的、电子的方法产生人造语音的技术。",
            "文语转换技术隶属于语音合成，它是将计算机自己产生的或外部输入的文字信息转变为可以听得懂的、流利的汉语口语输出的技术。",
            "语音合成和语音识别技术是实现人机语音通信、建立一个有听和讲能力的口语系统所必需的两项关键技术。",
            "使电脑具有类似于人一样的说话能力，是当今时代信息产业的重要竞争市场。", "发展历史。", "早在电子信号处理出现之前，就有人尝试用机械装置模仿人的声音。",
        ])
        XCTAssertEqual(document.detectedLanguage, .zh)
    }

    /// Two justified columns: each line is measured against its own column (else every left-column
    /// line is "short" for the page and its own paragraph), a paragraph runs on from the foot of the
    /// left column to the top of the right one, and one that ends at a column's foot is followed
    /// by the indented next (also over the page); "con-" + "catenating" joins, "text-" +
    /// "to-speech" keeps its hyphen.
    func testATwoColumnPDFReadsWholeParagraphs() async throws {
        let document = try await load("formats/columns.pdf", with: try reader())
        XCTAssertEqual(document.blocks.map(\.text), [
            "Neural Speech Synthesis: A Review",
            "Speech synthesis is the artificial production of human speech. A computer system used for this purpose is called a speech synthesizer, and it can be implemented in software or hardware products. A text-to-speech system converts normal language text into speech; other systems render symbolic linguistic representations like phonetic transcriptions into speech.",
            "Synthesized speech can be created by concatenating pieces of recorded speech that are stored in a database. Systems differ in the size of the stored speech units; a system that stores phones or diphones provides the largest output range, but may lack clarity.",
            "For specific usage domains, the storage of entire words or sentences allows for high-quality output. Alternatively, a synthesizer can incorporate a model of the vocal tract and other human voice characteristics to create a completely synthetic voice output.",
            "The quality of a speech synthesizer is judged by its similarity to the human voice and by its ability to be understood clearly. An intelligible text-to-speech program allows people with visual impairments or reading disabilities to listen to written words on a home computer.",
            "Long before the invention of electronic signal processing, some people tried to build machines to emulate human speech. Some early legends of the existence of speaking heads involved Gerbert of Aurillac, Albertus Magnus and Roger Bacon.",
            "In 1779 the German-Danish scientist Christian Gottlieb Kratzenstein built models of the human vocal tract that could produce the five long vowel sounds.",
        ])
        XCTAssertEqual(document.blocks.first?.kind, .title)
        XCTAssertEqual(document.units.count, 13, "whole sentences only: \(speech(document))")
    }

    /// The same in Chinese: full lines broken inside words join across the column break.
    func testATwoColumnChinesePDFJoinsAcrossTheColumns() async throws {
        let document = try await load("formats/zh_columns.pdf", with: try reader())
        XCTAssertEqual(document.blocks.map(\.text), [
            "语音合成简介",
            "语音合成是通过机械的、电子的方法产生人造语音的技术。文语转换技术隶属于语音合成，它是将计算机自己产生的或外部输入的文字信息转变为可以听得懂的、流利的汉语口语输出的技术。",
            "语音合成和语音识别技术是实现人机语音通信、建立一个有听和讲能力的口语系统所必需的两项关键技术。使电脑具有类似于人一样的说话能力，是当今时代信息产业的重要竞争市场。",
            "早在电子信号处理出现之前，就有人尝试用机械装置模仿人的声音。十八世纪末，人们已经能够用风箱和簧片做出发出元音的机器。到了二十世纪，电子合成器第一次让机器说出了完整的句子。",
        ])
    }

    /// Lines placed by hand: a page in two columns is found (a title across both does not hide the
    /// gutter), one in a single column with short lines is not.
    func testColumnsAreFoundOnlyWhereTheyAre() {
        func line(_ x: CGFloat, _ width: CGFloat, _ y: CGFloat) -> PDFTextReader.Line {
            PDFTextReader.Line(text: "words", rect: CGRect(x: x, y: y, width: width, height: 10), page: 0)
        }
        var twoColumns = [line(72, 305, 720)]
        for row in 0..<10 {
            twoColumns.append(line(72, 222, 690 - CGFloat(row) * 13))
            twoColumns.append(line(318, 222, 690 - CGFloat(row) * 13))
        }
        XCTAssertEqual(PDFTextReader.columns(twoColumns).count, 2)
        var oneColumn: [PDFTextReader.Line] = []
        for row in 0..<20 { oneColumn.append(line(72, row % 4 == 3 ? 180 : 468, 690 - CGFloat(row) * 13)) }
        oneColumn.append(line(400, 140, 400))  // a right-aligned signature
        oneColumn.append(line(420, 120, 387))
        XCTAssertEqual(PDFTextReader.columns(oneColumn), [], "mostly full lines")
        var poem: [PDFTextReader.Line] = []
        for row in 0..<12 { poem.append(line(72, CGFloat(120 + (row * 37) % 180), 690 - CGFloat(row) * 13)) }
        XCTAssertEqual(PDFTextReader.columns(poem), [], "short lines, all from the left margin")
    }

    /// A compound keeps its hyphen at a line end; a hyphenated word and a soft hyphen join.
    func testHyphensAtLineEnds() {
        XCTAssertEqual(PDFTextReader.join("A text-", "to-speech system"), "A text-to-speech system")
        XCTAssertEqual(PDFTextReader.join("a speech synthe-", "sizer, and"), "a speech synthesizer, and")
        XCTAssertEqual(PDFTextReader.join("Chapter 3 -", "the end"), "Chapter 3 - the end")
        XCTAssertEqual(PDFTextReader.join("con\u{00AD}", "catenating"), "concatenating")
    }

    func testPDFsThatCannotBeRead() async throws {
        let reader = try reader()
        await assertFails("formats/encrypted.pdf", with: reader, .passwordProtected)
        await assertFails("formats/scan.pdf", with: reader, .noTextLayer)
        let restricted = try await load("formats/owner_password.pdf", with: reader)
        XCTAssertEqual(speech(restricted), ["Restricted but readable.", "Anyone may open this file; only printing and copying are restricted."])

        let directory = try makeTemporaryDirectory()
        let fake = directory.appending(path: "fake.pdf")
        try Data("not a PDF at all".utf8).write(to: fake)
        do {
            _ = try await reader.read(fake)
            XCTFail("expected unreadable")
        } catch {
            guard case .unreadable("PDF", _)? = error as? DocumentReadError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(DocumentReadError.passwordProtected.errorDescription?.contains("password") ?? false)
        XCTAssertTrue(DocumentReadError.noTextLayer.errorDescription?.contains("OCR") ?? false)
    }

    /// The spine in order (cover linear="no", the navigation document and the endnotes skipped),
    /// footnotes and their markers gone, ruby readings and scripts dropped, a poem's line breaks
    /// kept, CJK text wrapped in the source joined, the ideographic space kept.
    func testAnEPUBIsReadInSpineOrder() async throws {
        let unpack = try makeTemporaryDirectory().appending(path: "epub")
        let reader = try reader(unpack: unpack)
        let document = try await load("formats/book.epub", with: reader)
        XCTAssertEqual(document.title, "The Fixture Book")
        XCTAssertEqual(document.units.count, 17)
        XCTAssertEqual(Array(speech(document).prefix(4)), [
            "The Fixture Book.", "Chapter One: The Voice.",
            "The machine spoke its first sentence in a quiet room, and everybody listened—even the cat…",
            "Its maker wrote the words in a notebook, which is kept in a museum today.",
        ])
        let text = document.blocks.map(\.text).joined(separator: "\n")
        for absent in ["COVER", "NAVIGATION", "FOOTNOTE", "ENDNOTE", "SCRIPT", "SVG", "kanji", "[2]", "Notes"] {
            XCTAssertFalse(text.contains(absent), absent)
        }
        XCTAssertTrue(text.contains("A short poem:\nthe first line,\nthe second line."))
        XCTAssertTrue(text.contains("Water is H2O"))
        XCTAssertTrue(text.contains("第二章　声音"))
        XCTAssertTrue(text.contains("语音合成是通过机械的、电子的方法产生人造语音的技术。"), "no space where the source wrapped")
        XCTAssertEqual(document.blocks.filter { $0.kind == .quote }.map(\.text), ["A voice without a body is still a voice."])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: unpack.path(percentEncoded: false))
        XCTAssertEqual(leftovers, [], "the unpacked book is removed")
    }

    func testEPUBsThatCannotBeRead() async throws {
        let reader = try reader()
        await assertFails("formats/drm.epub", with: reader, .drmProtected)
        await assertFails("formats/unsafe.epub", with: reader, .invalidEPUB("unsafe entry name: ../escape.txt"))
        await assertFails("formats/symlink.epub", with: reader, .invalidEPUB("it holds a symbolic link: OEBPS/link.xhtml"))
        await assertFails("formats/no_container.epub", with: reader, .invalidEPUB("META-INF/container.xml is missing"))
        await assertFails("formats/missing_spine.epub", with: reader,
                          .invalidEPUB("none of the documents its spine lists are in the file"))
        // Fonts obfuscated the IDPF way are no DRM; a chapter that is not XML is read by the HTML reader.
        let fonts = try await load("formats/fonts.epub", with: reader)
        XCTAssertEqual(fonts.units.count, 17)
        let malformed = try await load("formats/malformed.epub", with: reader)
        XCTAssertTrue(malformed.blocks.contains { $0.text == "Broken Markup" })
        XCTAssertTrue(malformed.blocks.contains { $0.text.hasPrefix("This chapter is not well-formed XML") })

        // Too much content unpacked (the file itself is small): a message of its own.
        var small = DocumentReader.Limits()
        small.epubExpandedBytes = 2_000
        await assertFails("formats/book.epub", with: try self.reader(limits: small), .unpackedTooLarge(2_000))
        XCTAssertEqual(DocumentReadError.unpackedTooLarge(1_000_000_000).errorDescription,
                       "This EPUB is too large to read: its content unpacks to more than 1000 MB.")
        var few = DocumentReader.Limits()
        few.epubEntries = 5
        await assertFails("formats/book.epub", with: try self.reader(limits: few), .invalidEPUB("it has more than 5 entries"))
        XCTAssertFalse(EPUBReader.isSafeName("/etc/passwd"))
        XCTAssertFalse(EPUBReader.isSafeName("OEBPS/../../x"))
        XCTAssertFalse(EPUBReader.isSafeName("C:/x"))
        XCTAssertFalse(EPUBReader.isSafeName("a\\b"))
        XCTAssertTrue(EPUBReader.isSafeName("OEBPS/Text/chapter 1.xhtml"))
    }

    /// The central directory is read before anything is unpacked: ZIP64 and damaged archives stop there.
    func testTheZipDirectoryIsCheckedFirst() throws {
        let directory = try makeTemporaryDirectory()
        func write(_ bytes: [UInt8], _ name: String) throws -> URL {
            let url = directory.appending(path: name)
            try Data(bytes).write(to: url)
            return url
        }
        // An end record that says "see the ZIP64 record": 0xFFFF entries.
        let zip64: [UInt8] = [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF] + [UInt8](repeating: 0, count: 10)
        XCTAssertThrowsError(try ZipDirectory.entries(of: write(zip64, "zip64.epub"), maximumEntries: 100)) {
            XCTAssertEqual($0 as? ZipDirectory.Problem, .init(message: "ZIP64 archives are not supported"))
        }
        XCTAssertThrowsError(try ZipDirectory.entries(of: write(Array("plain text, no archive".utf8), "text.epub"), maximumEntries: 100))
        let entries = try ZipDirectory.entries(of: Fixtures.url("formats/book.epub"), maximumEntries: 100)
        XCTAssertEqual(entries.first?.name, "mimetype")
        XCTAssertEqual(entries.count, 9)
        XCTAssertFalse(entries.contains { $0.isSymlink || $0.isEncrypted })
    }

    /// Without Defuddle: the system's HTML reader, with nothing that loads or runs, the site's
    /// name dropped from the title; a page saved in GBK.
    func testHTMLWithoutDefuddle() async throws {
        let reader = try reader()
        let article = try await load("html/article.html", with: reader)
        XCTAssertEqual(article.title, "The Talking Machine")
        XCTAssertFalse(speech(article).contains { $0.contains("SCRIPT RAN") })
        XCTAssertTrue(article.blocks.contains { $0.kind == .heading && $0.text == "Early machines" })
        XCTAssertTrue(article.blocks.contains { $0.kind == .listItem && $0.text == "The Voder, shown at the 1939 World's Fair." })
        let chinese = try await load("html/zh_article.html", with: reader)
        XCTAssertEqual(chinese.title, "语音合成简史")
        XCTAssertFalse(chinese.blocks.contains { $0.text.contains("不应该被朗读") }, "参考资料 is dropped")
        let gbk = try await load("formats/gbk.html", with: reader)
        XCTAssertEqual(speech(gbk), ["编码测试。", "这个网页用国标扩展编码保存，读的时候要先转换成统一码。"])
        for name in ["formats/utf8_nometa.html", "formats/gbk_nometa.html"] {
            let page = try await load(name, with: reader)
            XCTAssertEqual(page.title, "没有声明编码的网页", name)
            XCTAssertTrue(speech(page).contains("语音合成是通过机械的、电子的方法产生人造语音的技术。"), "\(name): \(speech(page))")
        }
        XCTAssertEqual(AttributedTextReader.sanitizedHTML(
            #"<p style="background:url(http://x/y.png)">a<img src="http://x/p.png">b</p><script>evil()</script>"#), "<p>ab</p>")
    }

    /// With Defuddle (gated like LocalExtractorTests): the article only; pages saved without a
    /// charset in their own encoding.
    func testHTMLWithDefuddle() async throws {
        let script = try WebKitTestGate.defuddleScript()
        let reader = try reader(defuddle: script)
        let document = try await load("html/article.html", with: reader)
        XCTAssertEqual(document.title, "The Talking Machine")
        XCTAssertEqual(speech(document).first, "The Talking Machine.")
        XCTAssertFalse(speech(document).contains { $0.contains("Archive") || $0.contains("All rights reserved") || $0.contains("SCRIPT") })
        XCTAssertTrue(document.blocks.contains { $0.kind == .heading && $0.text == "Modern systems" })
        for name in ["formats/utf8_nometa.html", "formats/gbk_nometa.html", "formats/gbk.html"] {
            let page = try await load(name, with: reader)
            XCTAssertEqual(page.detectedLanguage, .zh, "\(name): \(speech(page))")
            XCTAssertFalse(speech(page).joined().contains { "ÃÂÓÒ".contains($0) }, "\(name) read as Latin-1: \(speech(page))")
        }
    }

    func testEveryFormatHasASizeLimit() async throws {
        var limits = DocumentReader.Limits()
        for type in ReadableFileType.allCases where type != .plainText && type != .markdown {
            XCTAssertNotNil(limits.bytes[type], "\(type)")
        }
        limits.bytes[.pdf] = 10_000
        limits.bytes[.rtfd] = 100
        let reader = try reader(limits: limits)
        let pdfSize = try XCTUnwrap(Fixtures.url("formats/paper.pdf").resourceValues(forKeys: [.fileSizeKey]).fileSize)
        await assertFails("formats/paper.pdf", with: reader, .tooLarge("PDF", pdfSize, 10_000))
        do {
            _ = try await load("formats/sample.rtfd", with: reader)
            XCTFail("expected tooLarge")
        } catch {
            guard case .tooLarge("RTFD", let size, 100)? = error as? DocumentReadError else { return XCTFail("\(error)") }
            XCTAssertGreaterThan(size, 100, "the package's files add up")
        }
        XCTAssertEqual(DocumentReadError.tooLarge("PDF", 300_000_000, 256_000_000).errorDescription,
                       "The PDF file is too large to read (300 MB; the limit is 256 MB).")
    }

    /// Text, Markdown and unknown extensions stay on the text path (.log is plain text, .mkdn Markdown).
    func testTextFilesStayText() async throws {
        let directory = try makeTemporaryDirectory()
        let log = directory.appending(path: "server.log")
        try "First line of the log.\nSecond line.".write(to: log, atomically: true, encoding: .utf8)
        let markdown = directory.appending(path: "notes.mkdn")
        try "---\ntitle: Notes\n---\n# Notes\n\nSome **bold** text.".write(to: markdown, atomically: true, encoding: .utf8)
        let reader = try reader()
        let logFile = try await reader.read(log)
        XCTAssertNil(logFile.blocks)
        XCTAssertFalse(logFile.isMarkdown)
        let notes = try await reader.read(markdown)
        XCTAssertTrue(notes.isMarkdown)
        XCTAssertEqual(notes.title, "Notes")
    }

    func testPlausibleTitles() {
        XCTAssertEqual(DocumentReader.plausibleTitle("  The Fixture Book \n"), "The Fixture Book")
        for junk in ["", "   ", "Untitled", "Microsoft Word - draft3.docx", "report_final.pdf", "无标题", "----"] {
            XCTAssertNil(DocumentReader.plausibleTitle(junk), junk)
        }
    }

    /// Writes the unit count and the first units of every fixture to $READREAD_TEST_SUMMARY.
    func testSummary() async throws {
        guard let path = ProcessInfo.processInfo.environment["READREAD_TEST_SUMMARY"], !path.isEmpty else {
            throw XCTSkip("set READREAD_TEST_SUMMARY to a file to write the summary")
        }
        let defuddle = WebKitTestGate.enabled ? try WebKitTestGate.defuddleScript() : nil
        let reader = try reader(defuddle: defuddle)
        var lines: [String] = []
        let fixtures = ["sample.rtf", "sample.rtfd", "sample.doc", "sample.docx", "sample.odt", "paper.pdf", "zh.pdf",
                        "owner_password.pdf", "encrypted.pdf", "scan.pdf", "book.epub", "fonts.epub", "malformed.epub", "drm.epub",
                        "unsafe.epub", "symlink.epub", "no_container.epub", "gbk.html", "korean_euckr.txt", "korean_cp949.txt",
                        "japanese_short.txt", "japanese_cp932.txt", "gbk_short.txt", "gb18030_short.txt",
                        "big5_short.txt"].map { "formats/\($0)" }
            + ["html/article.html", "html/zh_article.html"]
        for fixture in fixtures {
            let started = ContinuousClock.now
            do {
                let document = try await load(fixture, with: reader)
                let first = document.units.prefix(3).map(\.speakText).joined(separator: " | ")
                lines.append("\(fixture): \(document.units.count) units, title \"\(document.title)\", \(ContinuousClock.now - started); \(first)")
            } catch {
                lines.append("\(fixture): \(error.localizedDescription)")
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
