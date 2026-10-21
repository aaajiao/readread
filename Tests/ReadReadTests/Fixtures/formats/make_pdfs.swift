// Writes the PDF fixtures (swift make_pdfs.swift <directory>): every line is placed by hand
// with Core Text, so the tests know where the paragraphs, headings, running headers, footers,
// page numbers and hyphenated line ends are. The expected texts are in DocumentReaderTests.swift.
import CoreGraphics
import CoreText
import Foundation

struct Line {
    var text: String
    var size: CGFloat = 11
    var indent: CGFloat = 0
    /// Extra space above the line (a paragraph break).
    var gap: CGFloat = 0
}

let pageBox = CGRect(x: 0, y: 0, width: 612, height: 792)

func draw(_ text: String, font: String, size: CGFloat, at point: CGPoint, in context: CGContext) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = point
    CTLineDraw(line, context)
}

/// Pages of lines from the top margin down, a header at the top and a footer at the bottom of each.
func writePDF(_ path: String, pages: [[Line]], font: String, title: String?, header: String?,
              footer: ((Int, Int) -> String)?, userPassword: String? = nil, ownerPassword: String? = nil,
              shapesOnly: Bool = false) {
    var info: [CFString: Any] = [kCGPDFContextCreator: "ReadRead fixtures"]
    if let title { info[kCGPDFContextTitle] = title }
    if let userPassword { info[kCGPDFContextUserPassword] = userPassword }
    if let ownerPassword { info[kCGPDFContextOwnerPassword] = ownerPassword }
    var box = pageBox
    guard let consumer = CGDataConsumer(url: URL(fileURLWithPath: path) as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary)
    else { fatalError("cannot write \(path)") }
    for (index, lines) in pages.enumerated() {
        context.beginPDFPage(nil)
        if shapesOnly {
            // A "scan": gray bars where text would be, no text at all.
            context.setFillColor(gray: 0.6, alpha: 1)
            for row in 0..<30 { context.fill(CGRect(x: 72, y: 700 - CGFloat(row) * 20, width: 400 + CGFloat(row % 3) * 20, height: 9)) }
        }
        if let header { draw(header, font: font, size: 9, at: CGPoint(x: 72, y: 752), in: context) }
        var y: CGFloat = 712
        for line in lines {
            y -= line.gap
            draw(line.text, font: font, size: line.size, at: CGPoint(x: 72 + line.indent, y: y), in: context)
            y -= line.size * 1.4
        }
        if let footer { draw(footer(index + 1, pages.count), font: font, size: 9, at: CGPoint(x: 280, y: 40), in: context) }
        context.endPDFPage()
    }
    context.closePDF()
    print(path)
}

let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func output(_ name: String) -> String { (directory as NSString).appendingPathComponent(name) }

// English: a title, numbered section headings, hyphenated line ends, a paragraph that runs on
// across a page break, a bulleted list, and a References section; running header, "Page N of 3".
let paper: [[Line]] = [
    [
        Line(text: "Talking Machines: A Fixture Paper", size: 20),
        Line(text: "1. Introduction", size: 15, gap: 14),
        Line(text: "Speech synthesis is the artificial production of human speech. A computer system used for", gap: 6),
        Line(text: "this purpose is called a speech synthesizer, and it can be implemented in software or in hard-"),
        Line(text: "ware. A text-to-speech system converts normal language text into speech; other systems ren-"),
        Line(text: "der symbolic linguistic representations like phonetic transcriptions into speech."),
        Line(text: "Synthesized speech can be created by concatenating pieces of recorded speech that are stored", gap: 9),
        Line(text: "in a database. Systems differ in the size of the stored speech units; a system that stores"),
        Line(text: "phones or diphones provides the largest output range, but may lack clarity. For specific usage"),
        Line(text: "domains, the storage of entire words or sentences allows for high-quality output. Alternatively, a"),
    ],
    [
        Line(text: "synthesizer can incorporate a model of the vocal tract and other human voice characteristics"),
        Line(text: "to create a completely synthetic voice output."),
        Line(text: "2. History", size: 15, gap: 14),
        Line(text: "Long before the invention of electronic signal processing, some people tried to build machines", gap: 6),
        Line(text: "to emulate human speech. Some early legends of the existence of speaking heads involved"),
        Line(text: "Gerbert of Aurillac, Albertus Magnus and Roger Bacon."),
        Line(text: "• The acoustic-mechanical speech machine of Wolfgang von Kempelen.", gap: 9),
        Line(text: "• The Voder, exhibited at the 1939 New York World's Fair."),
    ],
    [
        Line(text: "3. Conclusion", size: 15),
        Line(text: "Modern systems use neural networks to generate the waveform directly from text, and they", gap: 6),
        Line(text: "read news, books and screens aloud."),
        Line(text: "References", size: 15, gap: 14),
        Line(text: "[1] A reference entry that must not be read aloud.", gap: 6),
    ],
]
writePDF(output("paper.pdf"), pages: paper, font: "Helvetica", title: "Talking Machines: A Fixture Paper",
         header: "Talking Machines · ReadRead Fixtures", footer: { "Page \($0) of \($1)" })

// Chinese: lines broken inside words, first-line indents, a paragraph running on across the page
// break, a heading; header on every page, "第 N 页" footers; a title only a word processor would give.
let chinese: [[Line]] = [
    [
        Line(text: "语音合成简介", size: 22),
        Line(text: "语音合成是通过机械的、电子的方法产生人造语音的技术。文语转换技术隶属于语", size: 12, indent: 24, gap: 12),
        Line(text: "音合成，它是将计算机自己产生的或外部输入的文字信息转变为可以听得懂的、流利的", size: 12),
        Line(text: "汉语口语输出的技术。", size: 12),
        Line(text: "语音合成和语音识别技术是实现人机语音通信、建立一个有听和讲能力的口语系统所必需", size: 12, indent: 24),
        Line(text: "的两项关键技术。使电脑具有类似于人一样的说话能力，是当今时代信息产业的重要竞争", size: 12),
    ],
    [
        Line(text: "市场。", size: 12),
        Line(text: "发展历史", size: 16, gap: 12),
        Line(text: "早在电子信号处理出现之前，就有人尝试用机械装置模仿人的声音。", size: 12, indent: 24, gap: 6),
    ],
]
writePDF(output("zh.pdf"), pages: chinese, font: "PingFangSC-Regular", title: "Microsoft Word - 语音合成.docx",
         header: "语音合成测试文档", footer: { page, _ in "第 \(page) 页" })

let secret: [[Line]] = [[Line(text: "This text is behind a password.")]]
writePDF(output("encrypted.pdf"), pages: secret, font: "Helvetica", title: "Locked", header: nil, footer: nil,
         userPassword: "secret", ownerPassword: "owner")
writePDF(output("owner_password.pdf"), pages: [[Line(text: "Anyone may open this file; only printing and copying are restricted.")]],
         font: "Helvetica", title: "Restricted but readable", header: nil, footer: nil, ownerPassword: "owner")
writePDF(output("scan.pdf"), pages: [[]], font: "Helvetica", title: "Scanned pages", header: nil, footer: nil, shapesOnly: true)

// MARK: - Two columns

/// A typeset line of a column: its text, where it starts in the column, and whether it is
/// stretched to the column's width (every line of a justified paragraph but its last).
struct SetLine {
    var text: String
    var indent: CGFloat
    var justified: Bool
}

func width(_ text: String, font: CTFont) -> CGFloat {
    let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

/// Greedy line breaking as a typesetter would: English at spaces, at the hyphen of a compound
/// ("text-|to-speech") and at a soft hyphen (U+00AD, drawn as "-" at a line end); Chinese between
/// any two characters, never before closing punctuation. The first line of a paragraph is indented.
func setParagraph(_ paragraph: String, font: CTFont, columnWidth: CGFloat, indent: CGFloat, cjk: Bool) -> [SetLine] {
    // The pieces a line may end after.
    var pieces: [String] = []
    if cjk {
        pieces = paragraph.map(String.init)
    } else {
        for (index, word) in paragraph.split(separator: " ").enumerated() {
            var parts: [String] = []
            var current = ""
            for character in word {
                current.append(character)
                if character == "-" || character == "\u{AD}" {
                    parts.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { parts.append(current) }
            if index > 0 { parts[0] = " " + parts[0] }
            pieces += parts
        }
    }
    let closing: Set<Character> = ["，", "。", "、", "；", "：", "！", "？", "”", "」", "）"]
    func drawn(_ text: String, atEnd: Bool) -> String {
        var text = text.trimmingCharacters(in: .whitespaces)
        if atEnd, text.hasSuffix("\u{AD}") { text = String(text.dropLast()) + "-" }
        return text.replacingOccurrences(of: "\u{AD}", with: "")
    }
    var lines: [SetLine] = []
    var current = ""
    var index = 0
    while index < pieces.count {
        let available = columnWidth - (lines.isEmpty ? indent : 0)
        let candidate = current + pieces[index]
        if current.isEmpty || width(drawn(candidate, atEnd: true), font: font) <= available {
            current = candidate
            index += 1
            continue
        }
        if cjk, let first = pieces[index].first, closing.contains(first), current.count > 1 {
            // Never start a line with closing punctuation: the line's last character moves down.
            index -= 1
            current = String(current.dropLast())
        }
        lines.append(SetLine(text: drawn(current, atEnd: true), indent: lines.isEmpty ? indent : 0, justified: true))
        current = ""
    }
    if !current.isEmpty { lines.append(SetLine(text: drawn(current, atEnd: false), indent: lines.isEmpty ? indent : 0, justified: false)) }
    return lines
}

/// A paragraph that is only this ends the column: the next paragraph starts at the top of the next.
let columnBreak = "\u{000C}"

/// Pages of two justified columns, as journals set them: a title across both columns on the first
/// page, then the paragraphs (first lines indented, no space between them) running down the left
/// column, on into the right one and over the page. Prints where every line went.
func writeColumnsPDF(_ path: String, title: String, paragraphs: [String], font name: String, size: CGFloat,
                     indent: CGFloat, rows: Int, cjk: Bool) {
    let font = CTFontCreateWithName(name as CFString, size, nil)
    let columns: [CGFloat] = [72, 318]
    let columnWidth: CGFloat = 222
    let leading = size * 1.3
    var lines: [SetLine?] = []
    for paragraph in paragraphs {
        if paragraph == columnBreak {
            while lines.count % rows != 0 { lines.append(nil) }
        } else {
            lines += setParagraph(paragraph, font: font, columnWidth: columnWidth, indent: indent, cjk: cjk).map { $0 }
        }
    }
    var box = pageBox
    guard let consumer = CGDataConsumer(url: URL(fileURLWithPath: path) as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: title] as CFDictionary)
    else { fatalError("cannot write \(path)") }
    let perPage = rows * columns.count
    for start in stride(from: 0, to: lines.count, by: perPage) {
        context.beginPDFPage(nil)
        var top: CGFloat = 690
        if start == 0 {
            draw(title, font: name, size: 18, at: CGPoint(x: 72, y: 720), in: context)
        } else {
            top = 720
        }
        for (offset, line) in lines[start..<min(lines.count, start + perPage)].enumerated() {
            guard let line else { continue }
            let column = offset / rows
            let point = CGPoint(x: columns[column] + line.indent, y: top - CGFloat(offset % rows) * leading)
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            var set = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: attributes))
            if line.justified, let justified = CTLineCreateJustifiedLine(set, 1.0, Double(columnWidth - line.indent)) {
                set = justified
            }
            context.textPosition = point
            CTLineDraw(set, context)
            print("  page \(start / perPage + 1) column \(column + 1) row \(offset % rows + 1): \(line.text)")
        }
        context.endPDFPage()
    }
    context.closePDF()
    print(path)
}

// English in two justified columns over two pages: a paragraph running on from the left column
// into the right one (its last left line ends mid-sentence), paragraphs ending at the foot of a
// column before an indented one at the top of the next (also over the page), a compound
// hyphenated at a line end ("text-" / "to-speech": the hyphen stays) and a word hyphenated at a
// line end ("concate-" / "nating": it goes).
writeColumnsPDF(output("columns.pdf"), title: "Neural Speech Synthesis: A Review", paragraphs: [
    "Speech synthesis is the artificial production of human speech. A computer system used for this purpose is called a speech synthesizer, and it can be implemented in software or hardware products. A text-to-speech system converts normal language text into speech; other systems render symbolic linguistic representations like phonetic transcriptions into speech.",
    "Synthesized speech can be created by con\u{AD}cate\u{AD}nating pieces of recorded speech that are stored in a database. Systems differ in the size of the stored speech units; a system that stores phones or diphones provides the largest output range, but may lack clarity.",
    "For specific usage domains, the storage of entire words or sentences allows for high-quality output. Alternatively, a synthesizer can incorporate a model of the vocal tract and other human voice characteristics to create a completely synthetic voice output.",
    "The quality of a speech synthesizer is judged by its similarity to the human voice and by its ability to be understood clearly. An intelligible text-to-speech program allows people with visual impairments or reading disabilities to listen to written words on a home computer.",
    columnBreak,
    "Long before the invention of electronic signal processing, some people tried to build machines to emulate human speech. Some early legends of the existence of speaking heads involved Gerbert of Aurillac, Albertus Magnus and Roger Bacon.",
    columnBreak,
    "In 1779 the German-Danish scientist Christian Gottlieb Kratzenstein built models of the human vocal tract that could produce the five long vowel sounds.",
], font: "Helvetica", size: 10, indent: 12, rows: 18, cjk: false)

// Chinese in two justified columns: lines broken inside words, two-character first-line indents,
// a paragraph running on from the left column into the right one.
writeColumnsPDF(output("zh_columns.pdf"), title: "语音合成简介", paragraphs: [
    "语音合成是通过机械的、电子的方法产生人造语音的技术。文语转换技术隶属于语音合成，它是将计算机自己产生的或外部输入的文字信息转变为可以听得懂的、流利的汉语口语输出的技术。",
    "语音合成和语音识别技术是实现人机语音通信、建立一个有听和讲能力的口语系统所必需的两项关键技术。使电脑具有类似于人一样的说话能力，是当今时代信息产业的重要竞争市场。",
    "早在电子信号处理出现之前，就有人尝试用机械装置模仿人的声音。十八世纪末，人们已经能够用风箱和簧片做出发出元音的机器。到了二十世纪，电子合成器第一次让机器说出了完整的句子。",
], font: "PingFangSC-Regular", size: 10, indent: 20, rows: 7, cjk: true)
