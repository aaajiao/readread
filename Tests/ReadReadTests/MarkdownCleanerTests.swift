import XCTest

@testable import ReadRead

/// Markdown → speakable blocks (R3-02, R3-04, R3-05, R2-07, R3-08). The first group is the
/// old WebExtractor.stripMarkdown suite, ported to blocks.
final class MarkdownCleanerTests: XCTestCase {
    private func texts(_ markdown: String) -> [String] { MarkdownCleaner.blocks(markdown).map(\.text) }
    private func text(_ markdown: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let blocks = texts(markdown)
        XCTAssertEqual(blocks.count, 1, "\(blocks)", file: file, line: line)
        return blocks.first ?? ""
    }
    private typealias Block = MarkdownCleaner.Block

    // MARK: - The old stripMarkdown cases

    func testImagesGoAndLinksBecomeTheirText() {
        XCTAssertEqual(text("Before ![alt text](https://example.com/img.png) after"), "Before after")
        XCTAssertEqual(text("Click [here](https://example.com) for more"), "Click here for more")
    }

    func testFencedCodeIsSkippedAndInlineCodeKeepsItsContent() {
        XCTAssertEqual(texts("Intro\n```swift\nlet x = 1\n```\nOutro"), ["Intro", "Outro"])
        XCTAssertEqual(text("Use `print()` to output"), "Use print() to output")
        XCTAssertEqual(text("Run `ls -la` then ``a `b` c`` and a stray ` tick"), "Run ls -la then a `b` c and a stray tick")
    }

    func testHeadingsAtEveryLevel() {
        XCTAssertEqual(MarkdownCleaner.blocks("# Heading One"), [Block(kind: .heading(1), text: "Heading One")])
        XCTAssertEqual(MarkdownCleaner.blocks("## Heading Two ##"), [Block(kind: .heading(2), text: "Heading Two")])
        XCTAssertEqual(MarkdownCleaner.blocks("###### Heading Six"), [Block(kind: .heading(6), text: "Heading Six")])
        XCTAssertEqual(MarkdownCleaner.blocks("Title\n=====\n\nSub\n---"),
                       [Block(kind: .heading(1), text: "Title"), Block(kind: .heading(2), text: "Sub")])
        XCTAssertEqual(texts("#hashtag is not a heading"), ["#hashtag is not a heading"])
    }

    func testEmphasisWithAsterisksAndUnderscores() {
        for input in ["This is *italic* text", "This is **italic** text", "This is ***italic*** text",
                      "This is _italic_ text", "This is __italic__ text", "This is ___italic___ text"] {
            XCTAssertEqual(text(input), "This is italic text", input)
        }
        XCTAssertEqual(text("This is **bold** and *italic* text."), "This is bold and italic text.")
    }

    func testBlockquotes() {
        XCTAssertEqual(MarkdownCleaner.blocks("> This is a quote"), [Block(kind: .quote, text: "This is a quote")])
        XCTAssertEqual(MarkdownCleaner.blocks("> Line one\n> Line two"), [Block(kind: .quote, text: "Line one Line two")])
        XCTAssertEqual(MarkdownCleaner.blocks("> [!NOTE]\n> Mind the gap."), [Block(kind: .quote, text: "NOTE: Mind the gap.")])
    }

    func testHorizontalRulesBreakParagraphs() {
        XCTAssertEqual(texts("Above\n***\nBelow"), ["Above", "Below"])
        XCTAssertEqual(texts("Above\n\n___\n\nBelow"), ["Above", "Below"])
        XCTAssertEqual(texts("Above\n\n---\n\nBelow"), ["Above", "Below"])
        XCTAssertEqual(MarkdownCleaner.blocks("Above\n---\nBelow").first, Block(kind: .heading(2), text: "Above"),
                       "a dash line right under a paragraph line underlines a heading (CommonMark)")
    }

    func testListItems() {
        for input in ["- item one\n- item two", "* item one\n* item two", "+ item one\n+ item two", "1. item one\n2) item two",
                      "- [ ] item one\n- [x] item two"] {
            XCTAssertEqual(MarkdownCleaner.blocks(input),
                           [Block(kind: .listItem, text: "item one"), Block(kind: .listItem, text: "item two")], input)
        }
        XCTAssertEqual(MarkdownCleaner.blocks("- item\n\n  More about the item."),
                       [Block(kind: .listItem, text: "item"), Block(kind: .listItem, text: "More about the item.")])
    }

    func testHTMLTagsAreStrippedAndBreaksAreNewlines() {
        XCTAssertEqual(text("Hello <b>world</b> and <br/> more"), "Hello world and\nmore")
        XCTAssertEqual(text("Line one<br>Line two"), "Line one\nLine two")
        XCTAssertEqual(text("A <span class=\"x\">styled</span> word<!-- hidden -->."), "A styled word.")
    }

    func testBlankLinesAndWhitespace() {
        XCTAssertEqual(texts("First\n\n\n\nSecond"), ["First", "Second"])
        XCTAssertEqual(texts("   \n  Hello world  \n   "), ["Hello world"])
        XCTAssertEqual(texts(""), [])
        XCTAssertEqual(texts("![only](an-image.png)\n\n---\n\n<br>"), [], "markup only")
    }

    // MARK: - Citations, footnotes, boilerplate sections

    func testFootnoteAndCitationMarkersGo() {
        XCTAssertEqual(text("Speech.[^1] More text.[^note]"), "Speech. More text.")
        XCTAssertEqual(text("就像音标转换至语音一样[^1] 。下一句[2] ，接着"), "就像音标转换至语音一样。下一句，接着")
        XCTAssertEqual(text("Fact.[12] Other.[3, 4] Range.[5–7] Disputed.[citation needed] 中文。[来源请求]"),
                       "Fact. Other. Range. Disputed. 中文。")
        XCTAssertEqual(text("Keep [a] and [v2] and [link text]."), "Keep [a] and [v2] and [link text].",
                       "only numeric and known citation markers")
    }

    func testFootnoteDefinitionsGoWithTheirContinuationLines() {
        XCTAssertEqual(texts("Text.\n\n[^1]: The note.\n    More of the note.\n\nAfter."), ["Text.", "After."])
        XCTAssertEqual(texts("Text.[^1]\n\n[^1]: First line of note\nlazy continuation of the note.\n\nAfter."), ["Text.", "After."],
                       "a lazy (unindented) continuation line")
        XCTAssertEqual(texts("- item\n\n[^1]: Note.\n\n    Note para two.\n\n    And three.\n\nAfter."), ["item", "After."],
                       "the note's further paragraphs, indented by 4")
        XCTAssertEqual(texts("[^1]: One.\n[^2]: Two.\n## Next\n\nBody."), ["Next", "Body."], "a block start ends the note")
    }

    func testConsecutiveAndNumericReferenceCitationsGo() {
        XCTAssertEqual(text("Fact.[1][2] Next."), "Fact. Next.")
        XCTAssertEqual(text("第一[1][2][3]，第二[4–6][7]。"), "第一，第二。")
        XCTAssertEqual(texts("This is true [1].\n\n[1]: https://example.com/a"), ["This is true."],
                       "a defined numeric label is a citation, not a link")
        XCTAssertEqual(texts("Read [the docs][1] and [2](https://example.com/2).\n\n[1]: https://docs.example.com"),
                       ["Read the docs and 2."], "a numeric reference label and a link whose text is a number stay links")
    }

    func testBoilerplateSectionsGoUpToTheNextHeadingOfTheSameLevel() {
        let markdown = """
        # Title

        Body.

        ## References

        1. Ref one

        ### Inside the references

        Still references.

        ## Next section

        Kept.

        ## See also:

        - Another page

        ## 参考文献

        - 某书
        """
        XCTAssertEqual(texts(markdown), ["Title", "Body.", "Next section", "Kept."])
    }

    func testBoilerplateHeadingsInMixedFormsAndNumbered() {
        XCTAssertEqual(MarkdownCleaner.headingKey("八、参考資料："), "参考资料")
        XCTAssertEqual(MarkdownCleaner.headingKey("（一）參考來源"), "参考来源")
        XCTAssertEqual(MarkdownCleaner.headingKey("8. References"), "references")
        XCTAssertEqual(MarkdownCleaner.headingKey("2.3 Notes and references"), "notes and references")
        XCTAssertEqual(MarkdownCleaner.headingKey("外部連結"), "外部连结")
        let markdown = "# 标题\n\n正文。\n\n## 参考資料\n\n- 某书\n\n## 八、参考链接\n\n- [A](https://a.com)\n\n## 參考來源\n\n1. 某文"
        XCTAssertEqual(texts(markdown), ["标题", "正文。"])
        XCTAssertEqual(texts("# 一、简介\n\n正文。"), ["一、简介", "正文。"], "the number is only dropped from the key")
    }

    func testAPageThatIsOnlyAReadingListKeepsIt() {
        XCTAssertEqual(texts("## Further reading\n\n- Book one\n- Book two"), ["Further reading", "Book one", "Book two"])
    }

    // MARK: - URLs, code, tables, dropped elements

    func testBareURLsAutolinksAndEmptyLinksGo() {
        XCTAssertEqual(text("Visit https://example.com/a?b=1 today."), "Visit today.")
        XCTAssertEqual(text("See https://en.wikipedia.org/wiki/Phone_(phonetics). Next."), "See . Next.")
        XCTAssertEqual(text("Mail <me@example.com> or see <https://x.org/>."), "Mail or see .")
        XCTAssertEqual(text("A [![badge](b.svg)](https://ci.example.com) badge."), "A badge.")
        XCTAssertEqual(text("Phones: [phones](https://en.wikipedia.org/wiki/Phone_\\(phonetics\\) \"Phone (phonetics)\") here."),
                       "Phones: phones here.")
    }

    /// A URL ends where CJK text or punctuation starts; the Chinese after it is read (it used
    /// to be deleted up to the next space, often the whole paragraph).
    func testBareURLsEndAtCJKText() {
        XCTAssertEqual(text("项目地址：[https://github.com/foo/bar](https://github.com/foo/bar)，欢迎star。如果有问题请提交issue。"),
                       "项目地址：，欢迎star。如果有问题请提交issue。")
        XCTAssertEqual(text("详见 https://example.com/docs。下一句会丢失吗？会的。"), "详见。下一句会丢失吗？会的。")
        XCTAssertEqual(text("访问https://example.com了解更多。"), "访问了解更多。", "right after a Han character too")
        XCTAssertEqual(text("原文：https://mp.weixin.qq.com/s/AbCdEf（转载请注明出处）谢谢大家的支持。"),
                       "原文：（转载请注明出处）谢谢大家的支持。")
        XCTAssertEqual(text("链接「https://example.com/a」和“https://example.com/b”。"), "链接「」和“”。")
        XCTAssertEqual(text("not xhttps://example.com here"), "not xhttps://example.com here", "inside a word it is no URL")
    }

    func testReferenceLinksResolveToTheirText() {
        let markdown = "Read [the docs][1], [Swift][] and [Swift].\n\n[1]: https://docs.example.com\n[swift]: https://swift.org \"Swift\""
        XCTAssertEqual(texts(markdown), ["Read the docs, Swift and Swift."])
    }

    func testCodeTablesScriptsAndStylesAreSkipped() {
        XCTAssertEqual(texts("A\n~~~\ncode\n~~~\nB"), ["A", "B"])
        XCTAssertEqual(texts("A\n\n```\nunclosed code runs to the end"), ["A"])
        XCTAssertEqual(texts("Para.\n\n    let x = 1\n    let y = 2\n\nAfter."), ["Para.", "After."])
        XCTAssertEqual(texts("Intro.\n\n| a | b |\n|---|:-:|\n| 1 | 2 |\n\nAfter."), ["Intro.", "After."])
        XCTAssertEqual(text("Text <script>alert(1)</script> more <style>p { color: red }</style> end"), "Text more end")
    }

    // MARK: - Escapes, entities, emphasis rules

    func testEscapesBecomeTheCharacters() {
        XCTAssertEqual(text(#"\*not emphasis\* and \[not a link\](x) and 5 \> 3"#), "*not emphasis* and [not a link](x) and 5 > 3")
    }

    func testEntitiesNamedAndNumeric() {
        XCTAssertEqual(text("Fish &amp; chips &lt;3 &#8212; &#x4E2D;&nbsp;文 &copy; &bogus;"), "Fish & chips <3 — 中 文 © &bogus;")
    }

    func testComparisonsAreNotTags() {
        XCTAssertEqual(text("if a < b and b > c then a<b"), "if a < b and b > c then a<b")
        XCTAssertEqual(text("Check x<y and y>z here."), "Check x<y and y>z here.")
        XCTAssertEqual(text("if (a<b && c>d) { return x<y; }"), "if (a<b && c>d) { return x<y; }")
        XCTAssertEqual(text("so a<b and c>d holds"), "so a<b and c>d holds", "attributes without a value must be boolean ones")
        XCTAssertEqual(text("Press <kbd>Ctrl</kbd> <img src=\"a.png\" alt='x' /> x<sup>2</sup> <details open>more</details>"
                            + " <my-widget data-a=1>w</my-widget><o:p></o:p> <H2 class=x>Head</H2>"),
                       "Press Ctrl x2 more w Head")
    }

    func testAsterisksBetweenLettersOrDigitsAreNotEmphasis() {
        XCTAssertEqual(text("The 2*3*4 product and a*b*c."), "The 2*3*4 product and a*b*c.")
        XCTAssertEqual(text("**特价**199元，**Note**: x and *one* more"), "特价199元，Note: x and one more")
        XCTAssertEqual(text("**bold *italic* bold** and ***both***"), "bold italic bold and both")
    }

    /// The spans are bounded: one long line of unmatched markers is linear, not quadratic.
    func testLongLinesOfUnmatchedMarkersAreFast() {
        for unit in ["*a ", " _a", "[a", "~~a ", "==a ", "[^a", "![a", "<http://a", "$a "] {
            let line = String(repeating: unit, count: 60_000 / unit.count)
            let start = ContinuousClock.now
            _ = MarkdownCleaner.Inline.clean([line], references: [])
            let elapsed = ContinuousClock.now - start
            XCTAssertLessThan(elapsed, .seconds(3), "\(unit): \(elapsed)")
        }
    }

    func testTeXMathGoesButPricesStay() {
        XCTAssertEqual(texts("Euler: $e^{i\\pi} + 1 = 0$ and display:\n\n$$\n\\int_0^1 x^2 \\, dx = \\frac{1}{3}\n$$\n\nAfter."),
                       ["Euler: and display:", "After."])
        XCTAssertEqual(texts("Text.\n$$ a_1 + a_2 $$\nMore."), ["Text.", "More."], "one-line display math interrupts a paragraph")
        XCTAssertEqual(text("It costs $5 and $10, or US$5,$10; $HOME/$PATH and $x$."),
                       "It costs $5 and $10, or US$5,$10; $HOME/$PATH and $x$.")
        XCTAssertEqual(text("Area $$r^2$$ here."), "Area here.")
        XCTAssertEqual(texts("$$5 for two$$\n\nAfter."), ["$$5 for two$$", "After."], "no TeX, no math")
        XCTAssertEqual(texts("$$\nnot closed\n\nAfter."), ["$$ not closed", "After."])
    }

    func testUnderscoresInsideWordsAreNotEmphasis() {
        XCTAssertEqual(text("Call snake_case_name or __init__ with file_name_here."),
                       "Call snake_case_name or init with file_name_here.")
        XCTAssertEqual(text("这是**重要**的内容"), "这是重要的内容", "asterisks work inside CJK text")
        XCTAssertEqual(text("a * b * c"), "a * b * c")
        XCTAssertEqual(text("~~old~~ new and ==marked=="), "old new and marked")
        XCTAssertEqual(text("Code `a_b*c*` stays"), "Code a_b*c* stays")
    }

    func testSoftLineBreaks() {
        XCTAssertEqual(text("line one\nline two"), "line one line two")
        XCTAssertEqual(text("第一行\n第二行"), "第一行第二行", "no space between CJK lines")
        XCTAssertEqual(text("line one  \nline two"), "line one\nline two", "a hard break")
    }

    // MARK: - Emoji and separators (R2-07)

    func testEmojiGo() {
        XCTAssertEqual(text("Hello 👋🏽 world ❤️ 👨‍👩‍👧 🇨🇳 #️⃣ done 🎉"), "Hello world done")
        XCTAssertEqual(text("今天天气很好☀️！"), "今天天气很好！")
    }

    func testKeycapsKeepTheirDigit() {
        XCTAssertEqual(text("Step 1️⃣ open, step 2️⃣ close, 🔟 ten, #️⃣ and *️⃣ go."), "Step 1 open, step 2 close, 10 ten, and go.")
        XCTAssertEqual(text("1️⃣打开 2⃣关闭"), "1打开 2关闭", "with or without U+FE0F")
        XCTAssertEqual(text("苹果 • 3️⃣ 香蕉"), "苹果，3 香蕉")
    }

    func testWhiteCirclesAreZerosNotSeparators() {
        XCTAssertEqual(text("二○二四年十月，一九◯◯年。"), "二○二四年十月，一九◯◯年。")
        XCTAssertEqual(text("苹果 ● 香蕉 □ 橘子"), "苹果，香蕉，橘子", "other shapes still separate")
    }

    func testIndentedBlocksArePargraphsWhenAsked() {
        let markdown = "Para.\n\n    Indented by four.\n\n\tBy a tab.\n\n```\ncode\n```\n\nAfter."
        XCTAssertEqual(texts(markdown), ["Para.", "After."])
        XCTAssertEqual(MarkdownCleaner.blocks(markdown, keepsIndentedText: true).map(\.text),
                       ["Para.", "Indented by four.", "By a tab.", "After."])
    }

    func testBulletsArrowsStarsAndChecksBecomeSeparators() {
        XCTAssertEqual(text("苹果 • 香蕉 • 橘子"), "苹果，香蕉，橘子")
        XCTAssertEqual(text("Fast → simple → done"), "Fast, simple, done")
        XCTAssertEqual(text("★★★ Great ✓"), "Great")
        XCTAssertEqual(text("Done ✓, next."), "Done , next.")
        XCTAssertEqual(text("列夫·托尔斯泰 and A · B"), "列夫·托尔斯泰 and A, B", "a middle dot between names stays")
    }

    /// TextPattern compiles with try!: touch every pattern so a bad one fails here, not in the app.
    func testEveryPatternCompiles() {
        typealias P = MarkdownCleaner.Patterns
        typealias I = MarkdownCleaner.Inline
        let patterns = [
            P.htmlComment, P.droppedElements, P.fence, P.atxHeading, P.setextUnderline, P.horizontalRule, P.quoteMarkers,
            P.listItem, P.footnoteDefinition, P.referenceDefinition, P.tableSeparator, P.callout,
            I.image, I.referenceImage, I.emptyLink, I.inlineLink, I.referenceLink, I.shortcutLink, I.footnoteReference,
            I.citation, I.codeSpan, I.autolink, I.bareURL, I.strongEmphasis, I.underscoreEmphasis, I.strike, I.highlight,
            I.lineBreakTag, I.htmlTag, I.entity, I.decoration, I.codePlaceholder, I.spaceRun, I.spaceBeforeCJKPunctuation,
            I.inlineMath, P.headingNumber, P.displayMath,
        ]
        XCTAssertEqual(patterns.count, 37)
        XCTAssertEqual(I.spaceRun.replace(in: "a \u{00A0}\u{2009} b", with: " "), "a b")
        XCTAssertEqual(I.codePlaceholder.replace(in: "x\u{E100}12\u{E101}y", with: "<$1>"), "x<12>y")
    }

    // MARK: - Real pages

    func testTheWikipediaFixtureLosesItsReferences() throws {
        let page = Frontmatter.split(try Fixtures.text("pages/en_wikipedia.md")).body
        let blocks = MarkdownCleaner.blocks(page)
        XCTAssertGreaterThan(blocks.count, 100)
        let all = blocks.map(\.text).joined(separator: "\n")
        XCTAssertTrue(all.hasPrefix("Speech synthesis is the artificial production of human speech."), String(all.prefix(80)))
        for leftover in ["[^", "](", "http", "**", "| ---", "References"] {
            XCTAssertFalse(all.contains(leftover), leftover)
        }
    }
}
