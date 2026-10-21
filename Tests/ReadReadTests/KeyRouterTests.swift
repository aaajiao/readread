import AppKit
import XCTest

@testable import ReadRead

/// The panel's keyboard map (R4-11): every path, in reading and input mode, with and without a
/// focused text field, and while an input method composes.
final class KeyRouterTests: XCTestCase {
    private let reading = KeyContext(reading: true, textFieldFocused: false)
    private let readingInField = KeyContext(reading: true, textFieldFocused: true)
    private let input = KeyContext(reading: false, textFieldFocused: true)
    private let inputUnfocused = KeyContext(reading: false, textFieldFocused: false)

    private func route(_ key: KeyStroke.Key, _ modifiers: KeyStroke.Modifiers = [], in context: KeyContext) -> AppCommand? {
        KeyRouter.command(for: KeyStroke(key, modifiers), in: context)
    }

    func testPlaybackKeysInReadingMode() {
        XCTAssertEqual(route(.space, in: reading), .togglePlayPause)
        XCTAssertEqual(route(.leftArrow, in: reading), .previousSentence)
        XCTAssertEqual(route(.rightArrow, in: reading), .nextSentence)
    }

    func testPlaybackKeysBelongToAFocusedTextFieldAndDoNothingInInputMode() {
        for context in [readingInField, input, inputUnfocused] {
            XCTAssertNil(route(.space, in: context), "\(context)")
            XCTAssertNil(route(.leftArrow, in: context), "\(context)")
            XCTAssertNil(route(.rightArrow, in: context), "\(context)")
        }
        XCTAssertNil(route(.space, .shift, in: reading), "⇧Space is not play/pause")
        XCTAssertNil(route(.space, .option, in: reading))
        XCTAssertNil(route(.leftArrow, .command, in: reading), "⌘← moves the cursor, not the reading")
        XCTAssertNil(route(.returnKey, in: reading))
    }

    func testEscapeHidesThePanelEverywhere() {
        for context in [reading, readingInField, input, inputUnfocused] {
            XCTAssertEqual(route(.escape, in: context), .hidePanel)
        }
    }

    func testCommandVReadsTheClipboardOutsideTheFieldAndPastesInIt() {
        XCTAssertEqual(route(.character("v"), .command, in: reading), .readClipboard)
        XCTAssertEqual(route(.character("v"), .command, in: inputUnfocused), .readClipboard)
        XCTAssertEqual(route(.character("v"), .command, in: input), .edit(.paste))
        XCTAssertEqual(route(.character("v"), .command, in: readingInField), .edit(.paste))
    }

    func testEditShortcutsInATextField() {
        XCTAssertEqual(route(.character("x"), .command, in: input), .edit(.cut))
        XCTAssertEqual(route(.character("c"), .command, in: input), .edit(.copy))
        XCTAssertEqual(route(.character("a"), .command, in: input), .edit(.selectAll))
        XCTAssertEqual(route(.character("z"), .command, in: input), .edit(.undo))
        XCTAssertEqual(route(.character("z"), [.command, .shift], in: input), .edit(.redo))
        XCTAssertNil(route(.character("x"), .command, in: reading), "no field: nothing to cut")
        XCTAssertNil(route(.character("z"), .command, in: reading))
        XCTAssertEqual(route(.character("c"), .command, in: reading), .edit(.copy), "a selection outside a field")
    }

    func testCommandShortcutsWorkWithAndWithoutAField() {
        for context in [reading, readingInField, input, inputUnfocused] {
            XCTAssertEqual(route(.character("o"), .command, in: context), .openFile)
            XCTAssertEqual(route(.character(","), .command, in: context), .openSettings)
            XCTAssertEqual(route(.character("w"), .command, in: context), .hidePanel)
            XCTAssertEqual(route(.character("q"), .command, in: context), .quit)
            XCTAssertEqual(route(.character("="), .command, in: context), .largerText)
            XCTAssertEqual(route(.character("+"), [.command, .shift], in: context), .largerText)
            XCTAssertEqual(route(.character("-"), .command, in: context), .smallerText)
            XCTAssertEqual(route(.character("0"), .command, in: context), .defaultTextSize)
        }
        XCTAssertNil(route(.character("w"), [.command, .shift], in: reading))
        XCTAssertNil(route(.character("o"), [.command, .option], in: reading))
        XCTAssertNil(route(.character("o"), .control, in: reading))
        XCTAssertNil(route(.character("o"), in: reading), "a plain letter is not a shortcut")
        XCTAssertNil(route(.character("k"), .command, in: reading))
    }

    func testEveryKeyIsTheInputMethodsWhileItComposes() {
        let composing = KeyContext(reading: true, textFieldFocused: true, composingText: true)
        XCTAssertNil(route(.space, in: composing))
        XCTAssertNil(route(.escape, in: composing))
        XCTAssertNil(route(.rightArrow, in: composing))
        XCTAssertNil(route(.character("v"), .command, in: composing))
    }

    func testKeyStrokesFromEvents() throws {
        func event(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [],
                   type: NSEvent.EventType = .keyDown) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        }
        XCTAssertEqual(KeyStroke(event: try event(" ", keyCode: 49)), KeyStroke(.space))
        XCTAssertEqual(KeyStroke(event: try event("\u{F702}", keyCode: 123)), KeyStroke(.leftArrow))
        XCTAssertEqual(KeyStroke(event: try event("\u{F703}", keyCode: 124)), KeyStroke(.rightArrow))
        XCTAssertEqual(KeyStroke(event: try event("\u{1B}", keyCode: 53)), KeyStroke(.escape))
        XCTAssertEqual(KeyStroke(event: try event("\r", keyCode: 36)), KeyStroke(.returnKey))
        XCTAssertEqual(KeyStroke(event: try event("V", keyCode: 9, [.command, .shift])),
                       KeyStroke(.character("v"), [.command, .shift]))
        XCTAssertEqual(KeyStroke(event: try event("o", keyCode: 31, [.command, .option, .control])),
                       KeyStroke(.character("o"), [.command, .option, .control]))
        XCTAssertNil(KeyStroke(event: try event("v", keyCode: 9, .command, type: .keyUp)))
        let held = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: true, keyCode: 49))
        XCTAssertEqual(KeyStroke(event: held), KeyStroke(.space, isRepeat: true))
        XCTAssertNotEqual(KeyStroke(event: held), KeyStroke(.space))
    }

    /// A held key: ← → and the text size step on, play/pause and ⌘V run once per press.
    func testHeldKeysRepeatOnlyWhatShouldRepeat() {
        let reading = KeyContext(reading: true, textFieldFocused: false)
        let field = KeyContext(reading: false, textFieldFocused: true)
        func held(_ key: KeyStroke.Key, _ modifiers: KeyStroke.Modifiers = [], in context: KeyContext) -> KeyRouter.Routing? {
            KeyRouter.routing(for: KeyStroke(key, modifiers, isRepeat: true), in: context)
        }
        XCTAssertEqual(KeyRouter.routing(for: KeyStroke(.space), in: reading), .run(.togglePlayPause))
        XCTAssertEqual(held(.space, in: reading), .swallow)
        XCTAssertEqual(held(.character("v"), .command, in: reading), .swallow)
        XCTAssertEqual(held(.character("o"), .command, in: reading), .swallow)
        XCTAssertEqual(held(.character(","), .command, in: reading), .swallow)
        XCTAssertEqual(held(.rightArrow, in: reading), .run(.nextSentence))
        XCTAssertEqual(held(.leftArrow, in: reading), .run(.previousSentence))
        XCTAssertEqual(held(.character("="), .command, in: reading), .run(.largerText))
        XCTAssertEqual(held(.character("-"), .command, in: reading), .run(.smallerText))
        XCTAssertEqual(held(.character("v"), .command, in: field), .run(.edit(.paste)), "a held ⌘V pastes again")
        XCTAssertNil(held(.space, in: field), "the field's own key, repeats and all")
    }

    func testEditActionsUseTheFieldEditorsSelectors() {
        XCTAssertEqual(EditAction.cut.selector, #selector(NSText.cut(_:)))
        XCTAssertEqual(EditAction.copy.selector, #selector(NSText.copy(_:)))
        XCTAssertEqual(EditAction.paste.selector, #selector(NSText.paste(_:)))
        XCTAssertEqual(EditAction.selectAll.selector, #selector(NSText.selectAll(_:)))
        XCTAssertEqual(NSStringFromSelector(EditAction.undo.selector), "undo:")
        XCTAssertEqual(NSStringFromSelector(EditAction.redo.selector), "redo:")
    }

    func testTheSettingsWindowsOwnKeys() {
        XCTAssertEqual(KeyRouter.settingsCommand(for: KeyStroke(.character("w"), .command)), .close)
        XCTAssertEqual(KeyRouter.settingsCommand(for: KeyStroke(.character("q"), .command)), .quit)
        XCTAssertNil(KeyRouter.settingsCommand(for: KeyStroke(.character("w"))))
        XCTAssertNil(KeyRouter.settingsCommand(for: KeyStroke(.character("w"), [.command, .shift])))
        XCTAssertNil(KeyRouter.settingsCommand(for: KeyStroke(.character("c"), .command)), "copy stays the window's")
    }
}
