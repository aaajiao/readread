import XCTest

@testable import ReadRead

/// YAML-style frontmatter (R3-11, R5-13), including the cases WebExtractor.parseFrontmatter had.
final class FrontmatterTests: XCTestCase {
    func testKeyValuePairsAndTheBodyAfterTheClosingLine() {
        let split = Frontmatter.split("---\ntitle: My Article\nAuthor: Jane\n---\nFirst paragraph\n\nSecond paragraph")
        XCTAssertEqual(split.metadata, ["title": "My Article", "author": "Jane"], "keys are lowercased")
        XCTAssertEqual(split.body, "First paragraph\n\nSecond paragraph")
    }

    func testQuotedValuesAreUnescaped() {
        let split = Frontmatter.split(#"""
        ---
        title: "Say \"hi\"\tnow"
        site: 'It''s here'
        url: https://example.com/a:b
        empty:
        ---
        Body
        """#)
        XCTAssertEqual(split.metadata["title"], "Say \"hi\"\tnow")
        XCTAssertEqual(split.metadata["site"], "It's here")
        XCTAssertEqual(split.metadata["url"], "https://example.com/a:b", "a colon in the value stays")
        XCTAssertEqual(split.metadata["empty"], "")
        XCTAssertEqual(split.body, "Body")
    }

    func testListsBlocksCommentsAndTheDotsCloser() {
        let split = Frontmatter.split("""
        ---
        # a comment
        tags:
          - one
          - "two"
        description: >
          folded over
          two lines
        poem: |
          line one
          line two
        summary: a value that
          continues here
        ...
        Body text.
        """)
        XCTAssertEqual(split.metadata["tags"], "one, two")
        XCTAssertEqual(split.metadata["description"], "folded over two lines")
        XCTAssertEqual(split.metadata["poem"], "line one\nline two")
        XCTAssertEqual(split.metadata["summary"], "a value that continues here")
        XCTAssertEqual(split.body, "Body text.")
    }

    func testKeysInOtherScripts() {
        XCTAssertEqual(Frontmatter.split("---\n标题: 你好\n---\n正文").metadata["标题"], "你好")
    }

    func testNoFrontmatterLeavesTheTextAlone() {
        for text in ["Just some plain text without frontmatter", "# Heading\n\nSome content here", ""] {
            let split = Frontmatter.split(text)
            XCTAssertTrue(split.metadata.isEmpty, text)
            XCTAssertEqual(split.body, text)
        }
    }

    func testOnlyAtTheVeryStart() {
        let text = "Intro\n---\ntitle: x\n---\nBody"
        XCTAssertEqual(Frontmatter.split(text), .init(metadata: [:], body: text))
    }

    func testWithoutAClosingLineItIsBody() {
        for text in ["---\ntitle: No closing\nauthor: Jane\n", "---\nkey: value\nmore text without closing delimiter"] {
            XCTAssertEqual(Frontmatter.split(text), .init(metadata: [:], body: text))
        }
    }

    func testProseBetweenTwoRulesIsNotFrontmatter() {
        let text = "---\nThis is an intro paragraph between two rules.\n---\n\nThe article."
        XCTAssertEqual(Frontmatter.split(text), .init(metadata: [:], body: text))
        let empty = "---\n---\nBody"
        XCTAssertEqual(Frontmatter.split(empty), .init(metadata: [:], body: empty), "nothing YAML-like in it")
    }

    func testALeadingByteOrderMarkIsIgnored() {
        let split = Frontmatter.split("\u{FEFF}---\ntitle: BOM\n---\nBody")
        XCTAssertEqual(split.metadata["title"], "BOM")
        XCTAssertEqual(split.body, "Body")
    }

    func testDefuddleResponseFixture() throws {
        let split = Frontmatter.split(try Fixtures.text("pages/en_wikipedia.md"))
        XCTAssertEqual(split.metadata["title"], "Speech synthesis")
        XCTAssertEqual(split.metadata["published"], "2002-03-04T15:36:04Z")
        XCTAssertEqual(split.metadata["domain"], "en.wikipedia.org")
        XCTAssertFalse(split.body.contains("word_count:"))
    }
}
