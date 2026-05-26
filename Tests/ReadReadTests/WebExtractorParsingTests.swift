import XCTest

@testable import ReadRead

final class WebExtractorParsingTests: XCTestCase {

    // MARK: - stripMarkdown: images

    func testStripMarkdownRemovesImages() {
        let input = "Before ![alt text](https://example.com/img.png) after"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "Before  after")
    }

    // MARK: - stripMarkdown: links

    func testStripMarkdownConvertsLinksToText() {
        let input = "Click [here](https://example.com) for more"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "Click here for more")
    }

    // MARK: - stripMarkdown: fenced code blocks

    func testStripMarkdownRemovesFencedCodeBlocks() {
        let input = "Intro\n```swift\nlet x = 1\n```\nOutro"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "Intro\n\nOutro")
    }

    // MARK: - stripMarkdown: inline code

    func testStripMarkdownUnwrapsInlineCode() {
        let input = "Use `print()` to output"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "Use print() to output")
    }

    // MARK: - stripMarkdown: ATX headings

    func testStripMarkdownStripsH1Marker() {
        let input = "# Heading One"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "Heading One")
    }

    func testStripMarkdownStripsH2Marker() {
        let input = "## Heading Two"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "Heading Two")
    }

    func testStripMarkdownStripsH6Marker() {
        let input = "###### Heading Six"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "Heading Six")
    }

    // MARK: - stripMarkdown: bold/italic with asterisks

    func testStripMarkdownUnwrapsItalicAsterisks() {
        let input = "This is *italic* text"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "This is italic text")
    }

    func testStripMarkdownUnwrapsBoldAsterisks() {
        let input = "This is **bold** text"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "This is bold text")
    }

    func testStripMarkdownUnwrapsBoldItalicAsterisks() {
        let input = "This is ***bold italic*** text"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "This is bold italic text")
    }

    // MARK: - stripMarkdown: bold/italic with underscores

    func testStripMarkdownUnwrapsItalicUnderscores() {
        let input = "This is _italic_ text"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "This is italic text")
    }

    func testStripMarkdownUnwrapsBoldUnderscores() {
        let input = "This is __bold__ text"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "This is bold text")
    }

    func testStripMarkdownUnwrapsBoldItalicUnderscores() {
        let input = "This is ___bold italic___ text"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "This is bold italic text")
    }

    // MARK: - stripMarkdown: blockquotes

    func testStripMarkdownStripsBlockquoteMarker() {
        let input = "> This is a quote"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "This is a quote")
    }

    func testStripMarkdownStripsMultilineBlockquote() {
        let input = "> Line one\n> Line two"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "Line one\nLine two")
    }

    // MARK: - stripMarkdown: horizontal rules

    func testStripMarkdownRemovesDashHorizontalRule() {
        let input = "Above\n---\nBelow"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "Above\n\nBelow")
    }

    func testStripMarkdownRemovesAsteriskHorizontalRule() {
        let input = "Above\n***\nBelow"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "Above\n\nBelow")
    }

    func testStripMarkdownRemovesUnderscoreHorizontalRule() {
        let input = "Above\n___\nBelow"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "Above\n\nBelow")
    }

    // Inline emphasis must still survive the (now earlier) horizontal-rule pass —
    // the rule regex is whole-line anchored, so `**bold**` is untouched by it.
    func testStripMarkdownKeepsInlineBoldAfterRuleReorder() {
        let input = "This is **bold** and *italic* text."
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "This is bold and italic text.")
    }

    // MARK: - stripMarkdown: unordered list markers

    func testStripMarkdownStripsDashListMarker() {
        let input = "- item one\n- item two"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "item one\nitem two")
    }

    func testStripMarkdownStripsAsteriskListMarker() {
        let input = "* item one\n* item two"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "item one\nitem two")
    }

    func testStripMarkdownStripsPlusListMarker() {
        let input = "+ item one\n+ item two"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "item one\nitem two")
    }

    // MARK: - stripMarkdown: ordered list markers

    func testStripMarkdownStripsOrderedListMarker() {
        let input = "1. First\n2. Second"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "First\nSecond")
    }

    // MARK: - stripMarkdown: HTML tags

    func testStripMarkdownRemovesHTMLTags() {
        let input = "Hello <b>world</b> and <br/> more"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "Hello world and  more")
    }

    // MARK: - stripMarkdown: newline collapsing

    func testStripMarkdownCollapsesExcessiveNewlines() {
        let input = "First\n\n\n\nSecond"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "First\n\nSecond")
    }

    func testStripMarkdownCollapsesFiveNewlinesToTwo() {
        let input = "A\n\n\n\n\nB"
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "A\n\nB")
    }

    // MARK: - stripMarkdown: leading/trailing whitespace

    func testStripMarkdownTrimsLeadingAndTrailingWhitespace() {
        let input = "   \n  Hello world  \n   "
        let result = WebExtractor.stripMarkdown(input)
        XCTAssertEqual(result, "Hello world")
    }

    // MARK: - parseFrontmatter: valid frontmatter

    func testParseFrontmatterExtractsKeyValuePairs() {
        let content = "---\ntitle: My Article\nauthor: Jane\n---\nBody text here"
        let (metadata, body) = WebExtractor.parseFrontmatter(content)
        XCTAssertEqual(metadata["title"], "My Article")
        XCTAssertEqual(metadata["author"], "Jane")
        XCTAssertEqual(body, "Body text here")
    }

    func testParseFrontmatterUnquotesDoubleQuotedValues() {
        let content = "---\ntitle: \"Quoted Title\"\n---\nBody"
        let (metadata, body) = WebExtractor.parseFrontmatter(content)
        XCTAssertEqual(metadata["title"], "Quoted Title")
        XCTAssertEqual(body, "Body")
    }

    func testParseFrontmatterReturnsRemainingBodyAfterClosingDelimiter() {
        let content = "---\nkey: value\n---\nFirst paragraph\n\nSecond paragraph"
        let (_, body) = WebExtractor.parseFrontmatter(content)
        XCTAssertEqual(body, "First paragraph\n\nSecond paragraph")
    }

    func testParseFrontmatterHandlesColonInValue() {
        let content = "---\nurl: https://example.com\n---\nBody"
        let (metadata, _) = WebExtractor.parseFrontmatter(content)
        XCTAssertEqual(metadata["url"], "https://example.com")
    }

    // MARK: - parseFrontmatter: no frontmatter

    func testParseFrontmatterWithoutLeadingDelimiterReturnsEmptyMetadata() {
        let content = "Just some plain text without frontmatter"
        let (metadata, body) = WebExtractor.parseFrontmatter(content)
        XCTAssertTrue(metadata.isEmpty)
        XCTAssertEqual(body, content)
    }

    func testParseFrontmatterWithoutLeadingDelimiterPreservesFullContent() {
        let content = "# Heading\n\nSome content here"
        let (metadata, body) = WebExtractor.parseFrontmatter(content)
        XCTAssertTrue(metadata.isEmpty)
        XCTAssertEqual(body, content)
    }

    // MARK: - parseFrontmatter: malformed frontmatter

    func testParseFrontmatterMalformedNoClosingDelimiterReturnsEmptyMetadataAndFullContent() {
        let content = "---\ntitle: No closing\nauthor: Jane\n"
        let (metadata, body) = WebExtractor.parseFrontmatter(content)
        XCTAssertTrue(metadata.isEmpty)
        XCTAssertEqual(body, content)
    }

    func testParseFrontmatterOpeningDelimiterButNoClosingDelimiterReturnsFullContent() {
        let content = "---\nkey: value\nmore text without closing delimiter"
        let (metadata, body) = WebExtractor.parseFrontmatter(content)
        XCTAssertTrue(metadata.isEmpty)
        XCTAssertEqual(body, content)
    }

    // MARK: - readFile: markdown with frontmatter

    func testReadFileMDWithFrontmatterReturnsTitleAsFilename() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("myarticle.md")
        let content = "---\ntitle: Ignored Title\n---\n# Hello\n\nThis is the body."
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let result = try await WebExtractor.readFile(fileURL)
        XCTAssertEqual(result.title, "myarticle")
        XCTAssertFalse(result.text.contains("#"), "heading markers should be stripped")
        XCTAssertTrue(result.text.contains("Hello"))
        XCTAssertTrue(result.text.contains("This is the body."))
    }

    func testReadFileMDStripsMarkdownSyntax() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("formatted.md")
        let content = "**Bold text** and *italic text* and `code`"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let result = try await WebExtractor.readFile(fileURL)
        XCTAssertEqual(result.text, "Bold text and italic text and code")
    }

    // MARK: - readFile: txt file

    func testReadFileTxtReturnsContentTrimmed() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("notes.txt")
        let content = "  Plain text content with **no** stripping.  \n"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let result = try await WebExtractor.readFile(fileURL)
        // txt files are not markdown-stripped, just trimmed
        XCTAssertEqual(result.text, "Plain text content with **no** stripping.")
        XCTAssertEqual(result.title, "notes")
    }

    // MARK: - readFile: .markdown extension

    func testReadFileMarkdownExtensionTreatedLikeMD() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("doc.markdown")
        let content = "## Section\n\nContent here."
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let result = try await WebExtractor.readFile(fileURL)
        XCTAssertFalse(result.text.contains("##"), ".markdown extension should strip heading markers")
        XCTAssertTrue(result.text.contains("Section"))
        XCTAssertTrue(result.text.contains("Content here."))
    }

    // MARK: - readFile: non-existent file

    func testReadFileNonExistentFileThrowsFileReadFailed() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("does_not_exist_xyz123.md")

        do {
            _ = try await WebExtractor.readFile(fileURL)
            XCTFail("expected WebExtractorError.fileReadFailed to be thrown")
        } catch let error as WebExtractorError {
            guard case .fileReadFailed = error else {
                return XCTFail("expected .fileReadFailed, got \(error)")
            }
        }
    }

    // MARK: - WebExtractorError.errorDescription

    func testErrorDescriptionInvalidURL() {
        let error = WebExtractorError.invalidURL
        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(error.errorDescription, "Invalid URL")
    }

    func testErrorDescriptionFetchFailedContainsStatusCode() {
        let error = WebExtractorError.fetchFailed(503)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("503") ?? false)
    }

    func testErrorDescriptionNoContent() {
        let error = WebExtractorError.noContent
        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(error.errorDescription, "No readable content found")
    }

    func testErrorDescriptionFileReadFailed() {
        let error = WebExtractorError.fileReadFailed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(error.errorDescription, "Failed to read file")
    }
}
