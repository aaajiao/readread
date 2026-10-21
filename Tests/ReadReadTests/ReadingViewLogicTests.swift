import SwiftUI
import XCTest

@testable import ReadRead

/// The reading view's decisions, outside SwiftUI: following the reading (R4-16), the sentence
/// links (tap = seek), where to scroll, and the highlighted text.
@MainActor
final class ReadingViewLogicTests: XCTestCase {
    // MARK: - Auto-follow

    func testItFollowsUntilTheUserScrolls() {
        var follow = AutoFollow(enabled: true)
        XCTAssertTrue(follow.isFollowing)
        XCTAssertTrue(follow.unitChanged(inView: true))
        XCTAssertTrue(follow.unitChanged(inView: false), "following: the view goes with the reading")

        follow.scrollPhaseChanged(to: .animating)
        follow.scrollPhaseChanged(to: .idle)
        XCTAssertTrue(follow.isFollowing, "its own scrolling is not the user's")

        follow.scrollPhaseChanged(to: .interacting)
        XCTAssertFalse(follow.isFollowing)
        XCTAssertFalse(follow.unitChanged(inView: false), "scrolled away: the view stays")
        XCTAssertTrue(follow.showsBackToCurrent(currentInView: false))
        XCTAssertFalse(follow.showsBackToCurrent(currentInView: true))
    }

    func testANewSentenceInViewResumesFollowing() {
        var follow = AutoFollow(enabled: true)
        follow.scrollPhaseChanged(to: .decelerating)
        XCTAssertFalse(follow.isFollowing)
        XCTAssertTrue(follow.unitChanged(inView: true), "the user only nudged the text")
        XCTAssertTrue(follow.isFollowing)
    }

    func testBackToCurrentAndJumpsResumeFollowing() {
        var follow = AutoFollow(enabled: true)
        follow.scrollPhaseChanged(to: .interacting)
        follow.backToCurrent()
        XCTAssertTrue(follow.isFollowing)
        follow.scrollPhaseChanged(to: .interacting)
        XCTAssertTrue(follow.jumped(), "a sentence the user chose: scroll there")
        XCTAssertTrue(follow.isFollowing)
    }

    func testFollowingTurnedOff() {
        var follow = AutoFollow(enabled: false)
        XCTAssertFalse(follow.isFollowing)
        XCTAssertFalse(follow.unitChanged(inView: true))
        XCTAssertFalse(follow.jumped(), "no scrolling at all")
        XCTAssertTrue(follow.showsBackToCurrent(currentInView: false), "the button still finds the sentence")
        XCTAssertFalse(follow.showsBackToCurrent(currentInView: true))
        follow.enabled = true
        XCTAssertTrue(follow.isFollowing)
    }

    // MARK: - Links and scrolling

    func testReadingLinksRoundTrip() throws {
        let url = ReadingLink.url(unit: 42)
        XCTAssertEqual(url.absoluteString, "readread-unit://42")
        XCTAssertEqual(ReadingLink.unit(from: url), 42)
        XCTAssertNil(ReadingLink.unit(from: try XCTUnwrap(URL(string: "https://example.com/42"))))
        XCTAssertNil(ReadingLink.unit(from: try XCTUnwrap(URL(string: "readread-unit://x"))))
        XCTAssertNil(ReadingLink.unit(from: try XCTUnwrap(URL(string: "readread-unit://-1"))))
    }

    func testLongBlocksScrollToTheUnitsShare() {
        XCTAssertEqual(ReadingScroll.anchor(unitRange: 0..<10, blockLength: 200), .center)
        let anchor = ReadingScroll.anchor(unitRange: 900..<1_100, blockLength: 2_000)
        XCTAssertEqual(anchor.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(ReadingScroll.anchor(unitRange: 1_990..<2_010, blockLength: 2_000).y, 1)
    }

    // MARK: - Rows

    /// A title and one paragraph of `count` sentences of 16 characters.
    private func longDocument(sentences count: Int) -> ReadingDocument {
        let sentence = "这是一个用来测试很长段落的句子。"
        let units = [SpeechUnit(id: 0, block: 0, range: 0..<3, speakText: "长段落。", language: .zh, kind: .title, endsBlock: true)]
            + (0..<count).map { index in
                SpeechUnit(id: index + 1, block: 1, range: (index * 16)..<((index + 1) * 16), speakText: sentence, language: .zh,
                           kind: .sentence, endsBlock: index == count - 1)
            }
        return ReadingDocument(title: "长段落", source: .text, sourceLabel: "",
                               blocks: [ReadingBlock(kind: .title, text: "长段落", units: 0..<1),
                                        ReadingBlock(kind: .paragraph, text: String(repeating: sentence, count: count),
                                                     units: 1..<(count + 1))],
                               units: units, detectedLanguage: .zh)
    }

    /// A long block is cut between its units into rows of about `rowLength` characters, which
    /// together are its text; a short one is one row (F3).
    func testALongBlockIsLaidOutInRows() throws {
        let document = longDocument(sentences: 300)
        let rows = ReadingRows(document)
        XCTAssertEqual(rows.rows.first?.text, "长段落")
        let paragraph = rows.rows.filter { $0.block == 1 }
        XCTAssertEqual(paragraph.map(\.length), [1_008, 1_008, 1_008, 1_008, 768], "cut after the sentence that reaches 1,000")
        XCTAssertEqual(paragraph.map(\.text).joined(), document.blocks[1].text)
        XCTAssertEqual(paragraph.map(\.continuesBlock), [false, true, true, true, true])
        XCTAssertEqual(paragraph.map(\.units.count), [63, 63, 63, 63, 48])
        for unit in document.units {
            let row = try XCTUnwrap(rows.row(of: unit.id).map { rows.rows[$0] })
            XCTAssertTrue(row.units.contains(unit.id))
            let local = row.local(unit.range)
            XCTAssertTrue(local.lowerBound >= 0 && local.upperBound <= row.length, "\(unit.id): \(local)")
        }
        XCTAssertEqual(ReadingRows(longDocument(sentences: 90)).rows.count, 2, "1,440 characters stay one row")

        // The row's links and highlight are the units' own.
        let second = paragraph[1]
        let string = BlockText.attributed(second.text, units: document.units[second.units], sentence: document.units[64].range,
                                          word: nil, offset: second.offset)
        let lit = string.runs.filter { $0.backgroundColor != nil }.map { String(string[$0.range].characters) }
        XCTAssertEqual(lit, ["这是一个用来测试很长段落的句子。"])
        XCTAssertEqual(string.runs.first?.link.flatMap(ReadingLink.unit(from:)), 64)
    }

    /// A Markdown novel is one block of hundreds of thousands of characters: the row being read
    /// stays small, so redrawing it for a word costs what a short paragraph does (F3).
    func testTheRowBeingReadStaysSmallInAHugeBlock() throws {
        let document = longDocument(sentences: 23_000)  // 368,000 characters
        let started = ContinuousClock.now
        let rows = ReadingRows(document)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertLessThanOrEqual(rows.rows.map(\.length).max() ?? 0, ReadingRows.rowLength + 16)
        let unit = document.units[11_500]
        let row = rows.rows[try XCTUnwrap(rows.row(of: unit.id))]
        var times: [Duration] = []
        for word in 0..<20 {
            let begin = ContinuousClock.now
            let start = unit.range.lowerBound + word % 8
            _ = BlockText.attributed(row.text, units: document.units[row.units], sentence: unit.range, word: start..<(start + 2),
                                     offset: row.offset)
            times.append(ContinuousClock.now - begin)
        }
        XCTAssertLessThan(times.sorted()[10], .milliseconds(10), "\(times)")
    }

    /// In a row taller than the view, the sentence being read counts as in view only when its own
    /// share of the row is (F6): a user who scrolled up inside a long paragraph keeps the view.
    func testASentenceOutsideTheVisiblePartOfItsRowIsNotInView() throws {
        let document = longDocument(sentences: 90)  // one row of 1,440 characters
        let rows = ReadingRows(document)
        let late = document.units[80]  // at about 88% of the row
        let early = document.units[2]
        let row = try XCTUnwrap(rows.row(of: late.id))
        let scrolledUp = try XCTUnwrap(RowShare(height: 2_000, visible: CGRect(x: 0, y: 0, width: 380, height: 560)))
        XCTAssertEqual(scrolledUp, RowShare(top: 0, bottom: 0.28))
        XCTAssertFalse(rows.shows(late, visibleRows: [row], shares: [row: scrolledUp]))
        XCTAssertTrue(rows.shows(early, visibleRows: [row], shares: [row: scrolledUp]))
        XCTAssertFalse(scrolledUp.isAbove(early.range, length: 1_440))
        XCTAssertTrue(rows.shows(late, visibleRows: [row], shares: [:]), "no share yet: the row's visibility decides")
        XCTAssertFalse(rows.shows(late, visibleRows: [], shares: [:]))
        XCTAssertTrue(rows.shows(late, visibleRows: nil, shares: [:]), "nothing reported yet")

        var follow = AutoFollow(enabled: true)
        follow.scrollPhaseChanged(to: .interacting)
        let next = document.units[81]
        let inView = rows.shows(next, visibleRows: [row], shares: [row: scrolledUp])
            || rows.shows(late, visibleRows: [row], shares: [row: scrolledUp])
        XCTAssertFalse(follow.unitChanged(inView: inView), "the view stays where the user put it")

        let further = try XCTUnwrap(RowShare(height: 2_000, visible: CGRect(x: 0, y: 1_500, width: 380, height: 560)))
        XCTAssertEqual(further, RowShare(top: 0.75, bottom: 1))
        XCTAssertTrue(further.isAbove(early.range, length: 1_440))
        XCTAssertFalse(further.isAbove(late.range, length: 1_440))
        XCTAssertNil(RowShare(height: 2_000, visible: CGRect(x: 0, y: 2_100, width: 380, height: 560)), "none of it on screen")
        XCTAssertNil(RowShare(height: 2_000, visible: nil))
    }

    // MARK: - Highlighted text

    private let units: [SpeechUnit] = [
        SpeechUnit(id: 7, block: 2, range: 0..<4, speakText: "第一句。", language: .zh, kind: .sentence, endsBlock: false),
        SpeechUnit(id: 8, block: 2, range: 5..<12, speakText: "👍🏽 ok 好。", language: .zh, kind: .sentence, endsBlock: true),
    ]

    private func runs(_ string: AttributedString) -> [(text: String, link: URL?, background: Color?)] {
        string.runs.map { run in
            (String(string[run.range].characters), run.link, run.backgroundColor)
        }
    }

    func testEverySentenceIsALinkToItsUnit() {
        let text = "第一句。 👍🏽 ok 好。"
        let string = BlockText.attributed(text, units: units[...], sentence: nil, word: nil)
        let links = runs(string).filter { $0.link != nil }
        XCTAssertEqual(links.map(\.text), ["第一句。", "👍🏽 ok 好。"])
        XCTAssertEqual(links.map { $0.link.flatMap(ReadingLink.unit(from:)) }, [7, 8])
        XCTAssertTrue(runs(string).allSatisfy { $0.background == nil })
    }

    func testTheSentenceAndTheWordAreHighlightedByCharacterOffsets() {
        let text = "第一句。 👍🏽 ok 好。"
        let string = BlockText.attributed(text, units: units[...], sentence: 5..<12, word: 7..<9)
        let lit = runs(string).filter { $0.background != nil }
        XCTAssertEqual(lit.map(\.text), ["👍🏽 ", "ok", " 好。"], "the emoji with its skin tone is one Character")
        XCTAssertEqual(lit.map(\.background), [BlockText.sentenceHighlight, BlockText.wordHighlight, BlockText.sentenceHighlight])
    }

    func testSpansOutsideTheTextAreIgnored() {
        let string = BlockText.attributed("短句。", units: [], sentence: 2..<40, word: -1..<1)
        XCTAssertTrue(runs(string).allSatisfy { $0.background == nil })
        XCTAssertEqual(String(string.characters), "短句。")
    }

    func testFontsGrowWithTheTextSize() {
        XCTAssertEqual(BlockText.font(.paragraph, size: 13), .system(size: 13))
        XCTAssertEqual(BlockText.font(.title, size: 20), .system(size: 22, weight: .semibold))
        XCTAssertEqual(BlockText.font(.heading, size: 20), .system(size: 21, weight: .semibold))
    }
}
