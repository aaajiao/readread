import AppKit
import XCTest

@testable import ReadRead

/// What the menu bar item shows and offers in every playback state (R4-12).
final class StatusItemModelTests: XCTestCase {
    private func titles(_ model: StatusItemModel) -> [String?] { model.menu.map { $0?.title } }
    private func commands(_ model: StatusItemModel) -> [AppCommand?] { model.menu.map { $0?.command } }
    private func enabled(_ model: StatusItemModel) -> [Bool?] { model.menu.map { $0?.enabled } }

    func testNothingOpen() {
        let model = StatusItemModel(state: .idle, documentTitle: nil)
        XCTAssertEqual(model.indicator, .none)
        XCTAssertEqual(model.toolTip, "ReadRead")
        XCTAssertEqual(commands(model), [.togglePlayPause, .previousSentence, .nextSentence, .stop, nil,
                                         .openFile, .readClipboard, nil, .openSettings, .quit])
        XCTAssertEqual(titles(model), ["Play", "Previous Sentence", "Next Sentence", "Stop", nil,
                                       "Open File…", "Read Clipboard", nil, "Settings…", "Quit ReadRead"])
        XCTAssertEqual(enabled(model), [false, false, false, false, nil, true, true, nil, true, true])
    }

    func testReading() {
        let model = StatusItemModel(state: .playing, documentTitle: "语音合成")
        XCTAssertEqual(model.indicator, .reading)
        XCTAssertEqual(model.indicator.symbolName, "waveform")
        XCTAssertEqual(model.toolTip, "ReadRead — reading: 语音合成")
        XCTAssertEqual(model.menu.first??.title, "Pause")
        XCTAssertEqual(enabled(model), [true, true, true, true, nil, true, true, nil, true, true])
    }

    func testBufferingCountsAsReading() {
        let model = StatusItemModel(state: .buffering, documentTitle: "A")
        XCTAssertEqual(model.indicator, .buffering)
        XCTAssertEqual(model.indicator.symbolName, "ellipsis")
        XCTAssertEqual(model.toolTip, "ReadRead — reading: A")
        XCTAssertEqual(model.menu.first??.title, "Pause")
    }

    func testPausedStoppedFailedAndFinished() {
        let paused = StatusItemModel(state: .paused, documentTitle: "A")
        XCTAssertEqual(paused.indicator, .none)
        XCTAssertEqual(paused.toolTip, "ReadRead — paused: A")
        XCTAssertEqual(paused.menu.first??.title, "Play")

        let idle = StatusItemModel(state: .idle, documentTitle: "A")
        XCTAssertEqual(idle.toolTip, "ReadRead — A")
        XCTAssertEqual(enabled(idle).prefix(4), [true, true, true, false], "Stop needs something to stop")

        for state: PlaybackController.State in [.failed("boom"), .finished] {
            let model = StatusItemModel(state: state, documentTitle: "A")
            XCTAssertEqual(model.indicator, .none)
            XCTAssertEqual(model.toolTip, "ReadRead — A")
            XCTAssertEqual(model.menu.first??.title, "Play")
        }
    }

    @MainActor
    func testTheReadingIconIsTheIconWithTheSymbolAfterIt() {
        let icon = NSImage(size: NSSize(width: 18, height: 18))
        XCTAssertTrue(StatusItemController.image(icon: icon, indicator: .none) === icon)
        let reading = StatusItemController.image(icon: icon, indicator: .reading)
        XCTAssertGreaterThan(reading.size.width, 18)
        XCTAssertEqual(reading.size.height, 18)
        XCTAssertFalse(reading.isTemplate, "the 🤓 keeps its colours")
    }
}
