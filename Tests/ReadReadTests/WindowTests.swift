import AppKit
import XCTest

@testable import ReadRead

/// FloatingPanel's side of the key routing (R4-11): real key events into a real panel (never
/// ordered in, nothing is shown), with and without a focused text field and an input method
/// composing. `KeyRouterTests` covers the map itself. Needs a window server session (a logged-in
/// user); skipped without one.
@MainActor
final class PanelKeyRoutingTests: XCTestCase {
    private var panel: FloatingPanel!
    private var field: NSTextField!
    private var commands: [AppCommand] = []
    private var reading = true

    override func setUp() async throws {
        try XCTSkipIf(CGSessionCopyCurrentDictionary() == nil, "no window server session")
        _ = NSApplication.shared
        commands = []
        reading = true
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560))
        panel.isReading = { [unowned self] in self.reading }
        panel.onCommand = { [unowned self] in self.commands.append($0) }
        field = NSTextField(frame: NSRect(x: 20, y: 500, width: 300, height: 22))
        field.stringValue = "https://example.com/post"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 560))
        content.addSubview(field)
        panel.contentView = content
        XCTAssertFalse(panel.isVisible)
    }

    override func tearDown() async throws {
        panel?.contentView = nil
        panel = nil
        field = nil
    }

    private func key(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [],
                     repeated: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeated,
            keyCode: keyCode))
    }

    private var space: NSEvent { get throws { try key(" ", keyCode: 49) } }
    private var escape: NSEvent { get throws { try key("\u{1b}", keyCode: 53) } }
    private var leftArrow: NSEvent { get throws { try key("\u{F702}", keyCode: 123) } }

    func testPlaybackKeysAndShortcutsReachTheApp() throws {
        XCTAssertTrue(panel.performKeyEquivalent(with: try space))
        XCTAssertTrue(panel.performKeyEquivalent(with: try leftArrow))
        XCTAssertTrue(panel.performKeyEquivalent(with: try key("v", keyCode: 9, .command)))
        XCTAssertTrue(panel.performKeyEquivalent(with: try key(",", keyCode: 43, .command)))
        XCTAssertTrue(panel.performKeyEquivalent(with: try escape))
        XCTAssertEqual(commands, [.togglePlayPause, .previousSentence, .readClipboard, .openSettings, .hidePanel])
    }

    /// Held Space toggles once, held ⌘V reads the clipboard once; the repeats are taken (no
    /// beep). A held → steps on.
    func testHeldKeysDoNotRepeatOneShotCommands() throws {
        XCTAssertTrue(panel.performKeyEquivalent(with: try space))
        for _ in 0..<5 {
            XCTAssertTrue(panel.performKeyEquivalent(with: try key(" ", keyCode: 49, repeated: true)), "taken")
        }
        XCTAssertTrue(panel.performKeyEquivalent(with: try key("v", keyCode: 9, .command)))
        for _ in 0..<3 {
            XCTAssertTrue(panel.performKeyEquivalent(with: try key("v", keyCode: 9, .command, repeated: true)))
        }
        for _ in 0..<2 {
            XCTAssertTrue(panel.performKeyEquivalent(with: try key("\u{F703}", keyCode: 124, repeated: true)))
        }
        XCTAssertEqual(commands, [.togglePlayPause, .readClipboard, .nextSentence, .nextSentence])
    }

    func testInInputModeSpaceIsNotAPlaybackKey() throws {
        reading = false
        XCTAssertFalse(panel.performKeyEquivalent(with: try space))
        XCTAssertTrue(commands.isEmpty)
    }

    func testAFocusedFieldKeepsItsKeysAndGetsItsEditActions() throws {
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView, "the field editor")
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertTrue(panel.keyContext.textFieldFocused)

        XCTAssertFalse(panel.performKeyEquivalent(with: try space), "typed into the field")
        XCTAssertFalse(panel.performKeyEquivalent(with: try leftArrow), "moves the caret")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(panel.performKeyEquivalent(with: try key("a", keyCode: 0, .command)))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (field.stringValue as NSString).length),
                       "⌘A went to the field editor")
        XCTAssertTrue(commands.isEmpty, "nothing reached the app: ⌘V in the field would paste, not read the clipboard")

        XCTAssertTrue(panel.performKeyEquivalent(with: try escape), "Esc still hides the panel")
        XCTAssertEqual(commands, [.hidePanel])
    }

    func testWhileAnInputMethodComposesEveryKeyIsItsOwn() throws {
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(panel.keyContext.composingText)
        XCTAssertFalse(panel.performKeyEquivalent(with: try escape), "Esc cancels the composition")
        XCTAssertFalse(panel.performKeyEquivalent(with: try key("v", keyCode: 9, .command)))
        XCTAssertTrue(commands.isEmpty)
        editor.unmarkText()
        XCTAssertFalse(panel.keyContext.composingText)
    }

    func testCancelOperationHidesThePanel() {
        panel.cancelOperation(nil)
        XCTAssertEqual(commands, [.hidePanel])
    }

    func testThePanelIsOnEverySpaceAndWithinItsBounds() {
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertEqual(panel.minSize, ReadingPreferences.minimumPanelSize)
        XCTAssertEqual(panel.maxSize, ReadingPreferences.maximumPanelSize)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.canBecomeKey)
    }
}

/// The Settings window (R4-21): its tabs are the toolbar of a titled window, built without
/// showing it. Needs a window server session; skipped without one.
@MainActor
final class SettingsWindowTests: XCTestCase {
    func testTheTabsAreTheWindowsToolbar() throws {
        try XCTSkipIf(CGSessionCopyCurrentDictionary() == nil, "no window server session")
        _ = NSApplication.shared
        let scratch = try makeTemporaryDirectory()
        let state = AppState(
            engine: FakeSynthesizer(), output: FakeAudioOutput(), defaults: MemoryPreferences(),
            loadDocument: FakeDocumentLoader().load, pasteboard: FakePasteboard(), workspace: FakeWorkspace(),
            loginItem: FakeLoginItem(), previewOutput: FakeAudioOutput(),
            directories: RuntimeDirectories(
                logDirectory: scratch.appending(path: "logs").path, cacheDirectory: scratch.appending(path: "cache").path,
                userLexicon: scratch.appending(path: "lexicon_zh.json").path))
        let controller = SettingsWindowController(appState: state)
        let window = controller.makeWindow()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(controller.isVisible)

        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        XCTAssertEqual(tabs.tabStyle, .toolbar)
        XCTAssertEqual(tabs.tabViewItems.map { $0.identifier as? String }, SettingsTab.allCases.map(\.rawValue))
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["General", "Voices", "Reading", "Advanced"])
        XCTAssertTrue(tabs.tabViewItems.allSatisfy { $0.image != nil }, "every tab's SF Symbol exists")
        XCTAssertEqual(window.title, "General", "the window is titled after its tab")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.toolbarStyle, .preference)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        window.contentViewController = nil
    }
}
