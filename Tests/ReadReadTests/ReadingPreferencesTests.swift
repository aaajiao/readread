import ServiceManagement
import XCTest

@testable import ReadRead

/// Text size, auto-follow and the panel's size in the preferences, and where the panel goes.
@MainActor
final class ReadingPreferencesTests: XCTestCase {
    func testDefaults() {
        let preferences = ReadingPreferences(defaults: MemoryPreferences())
        XCTAssertEqual(preferences.fontSize, 13)
        XCTAssertTrue(preferences.autoFollow)
        XCTAssertEqual(preferences.panelSize, CGSize(width: 380, height: 560), "the v0.3.0 size")
    }

    func testTheFontSizeIsRoundedAndKeptInRange() {
        let store = MemoryPreferences()
        let preferences = ReadingPreferences(defaults: store)
        preferences.fontSize = 17.4
        XCTAssertEqual(preferences.fontSize, 17)
        XCTAssertEqual(store.object(forKey: "font_size") as? Double, 17)
        preferences.fontSize = 400
        XCTAssertEqual(preferences.fontSize, ReadingPreferences.fontSizeRange.upperBound)
        store.set(2, forKey: "font_size")
        XCTAssertEqual(preferences.fontSize, ReadingPreferences.fontSizeRange.lowerBound, "a stored value is clamped too")
        store.set("large", forKey: "font_size")
        XCTAssertEqual(preferences.fontSize, 13)
        store.set(Double.nan, forKey: "font_size")
        XCTAssertEqual(preferences.fontSize, 13)
    }

    func testAutoFollowAndThePanelSizeAreStored() {
        let store = MemoryPreferences()
        let preferences = ReadingPreferences(defaults: store)
        preferences.autoFollow = false
        XCTAssertFalse(ReadingPreferences(defaults: store).autoFollow)
        preferences.panelSize = CGSize(width: 512.6, height: 700.2)
        XCTAssertEqual(store.object(forKey: "panel_width") as? Double, 513)
        XCTAssertEqual(store.object(forKey: "panel_height") as? Double, 700)
        XCTAssertEqual(preferences.panelSize, CGSize(width: 513, height: 700))
        preferences.panelSize = CGSize(width: 10, height: 99_999)
        XCTAssertEqual(preferences.panelSize, CGSize(width: ReadingPreferences.minimumPanelSize.width,
                                                     height: ReadingPreferences.maximumPanelSize.height))
        store.removeObject(forKey: "panel_height")
        XCTAssertEqual(preferences.panelSize, ReadingPreferences.defaultPanelSize, "half a size is no size")
    }

    func testTheKeysSurviveTheVoiceMigration() {
        let store = MemoryPreferences()
        let reading = ReadingPreferences(defaults: store)
        reading.fontSize = 18
        reading.autoFollow = false
        reading.panelSize = CGSize(width: 600, height: 800)
        store.set("remote", forKey: ExtractionMode.defaultsKey)
        VoicePreferences(defaults: store).migrate()
        XCTAssertEqual(Set(store.values.keys), ["font_size", "auto_follow", "panel_width", "panel_height", "extraction_mode"])
    }

    // MARK: - Placement and resizing

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)  // visible frame, under a 25 pt menu bar
    private let button = CGRect(x: 1200, y: 875, width: 30, height: 24)

    func testThePanelHangsCentredUnderTheStatusItem() {
        let frame = PanelPlacement.frame(size: CGSize(width: 380, height: 560), under: button, in: screen)
        XCTAssertEqual(frame.midX, button.midX)
        XCTAssertEqual(frame.maxY, button.minY - PanelPlacement.gapBelowMenuBar)
        XCTAssertEqual(frame.size, CGSize(width: 380, height: 560))
    }

    func testThePanelStaysOnScreen() {
        let right = CGRect(x: 1420, y: 875, width: 20, height: 24)
        let frame = PanelPlacement.frame(size: CGSize(width: 380, height: 560), under: right, in: screen)
        XCTAssertEqual(frame.maxX, screen.maxX - PanelPlacement.margin)
        let tall = PanelPlacement.frame(size: CGSize(width: 380, height: 1_200), under: button, in: screen)
        XCTAssertEqual(tall.minY, screen.minY + PanelPlacement.margin, "no taller than the screen allows")
        let small = CGRect(x: 0, y: 0, width: 300, height: 875)
        let narrow = PanelPlacement.frame(size: CGSize(width: 900, height: 560), under: CGRect(x: 150, y: 875, width: 20, height: 24), in: small)
        XCTAssertEqual(narrow.width, ReadingPreferences.minimumPanelSize.width, "never below the minimum")
    }

    func testResizingKeepsTheTopEdgeAndTheBounds() {
        let start = CGRect(x: 100, y: 300, width: 380, height: 560)
        let wider = PanelResize.frame(from: start, dragged: CGSize(width: 120, height: -100))
        XCTAssertEqual(wider, CGRect(x: 100, y: 200, width: 500, height: 660))
        XCTAssertEqual(wider.maxY, start.maxY)
        let tiny = PanelResize.frame(from: start, dragged: CGSize(width: -1_000, height: 1_000))
        XCTAssertEqual(tiny.size, ReadingPreferences.minimumPanelSize)
        XCTAssertEqual(tiny.maxY, start.maxY)
    }
}

/// Launch at login: outside an installed app (`swift test`, `swift run`), and the system's status.
@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func testOutsideAnAppBundleItIsUnavailable() {
        XCTAssertNotEqual(Bundle.main.bundleURL.pathExtension, "app")
        XCTAssertEqual(MainAppLoginItem().status, .unavailable, "SMAppService is not asked")
    }

    /// In the app: `.notFound` (a fresh install, or removed in System Settings) is off, so the
    /// toggle stays enabled and turns it on.
    func testTheSystemStatusIsOnOrOff() {
        XCTAssertEqual(MainAppLoginItem.status(for: .enabled), .enabled)
        XCTAssertEqual(MainAppLoginItem.status(for: .requiresApproval), .requiresApproval)
        XCTAssertEqual(MainAppLoginItem.status(for: .notRegistered), .disabled)
        XCTAssertEqual(MainAppLoginItem.status(for: .notFound), .disabled)
    }
}
