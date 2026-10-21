import AppKit

/// Everything the user can ask for from the keyboard, the status item's menu or a toolbar
/// button. `AppState.perform` runs the playback and document ones; the window ones go to the
/// `AppShell` (the app delegate).
enum AppCommand: Equatable, Sendable {
    case togglePlayPause
    case previousSentence
    case nextSentence
    case stop
    case readClipboard
    case openFile
    case openSettings
    case hidePanel
    case quit
    case largerText
    case smallerText
    case defaultTextSize
    /// A standard edit action for the focused text field (the panel has no Edit menu).
    case edit(EditAction)

    /// Holding its key runs it again at each auto-repeat: stepping through sentences, the text
    /// size, a text field's edit actions. The others (play/pause, the clipboard, a file,
    /// Settings, hide, quit) run once per press; their repeats are swallowed.
    var repeatsWhileHeld: Bool {
        switch self {
        case .previousSentence, .nextSentence, .largerText, .smallerText, .edit: true
        case .togglePlayPause, .stop, .readClipboard, .openFile, .openSettings, .hidePanel, .quit, .defaultTextSize: false
        }
    }
}

enum EditAction: String, Equatable, Sendable, CaseIterable {
    case cut
    case copy
    case paste
    case selectAll
    case undo
    case redo

    /// The responder-chain action the field editor implements.
    var selector: Selector {
        switch self {
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        case .undo: Selector(("undo:"))
        case .redo: Selector(("redo:"))
        }
    }
}

/// One key press, independent of NSEvent so the routing is unit-tested.
struct KeyStroke: Equatable, Sendable {
    enum Key: Equatable, Sendable {
        case space
        case leftArrow
        case rightArrow
        case escape
        case returnKey
        /// `charactersIgnoringModifiers`, lowercased ("v", "=", "+", "-", "0", ",").
        case character(String)
    }

    struct Modifiers: OptionSet, Equatable, Sendable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let control = Modifiers(rawValue: 1 << 3)
    }

    let key: Key
    let modifiers: Modifiers
    /// An auto-repeat of a held key (`NSEvent.isARepeat`).
    let isRepeat: Bool

    init(_ key: Key, _ modifiers: Modifiers = [], isRepeat: Bool = false) {
        self.key = key
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }

    /// nil for anything but a key press.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        isRepeat = event.isARepeat
        var modifiers: Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        switch event.keyCode {
        case 49: key = .space
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        case 53: key = .escape
        case 36, 76: key = .returnKey
        default:
            guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
            key = .character(characters.lowercased())
        }
        self.modifiers = modifiers
    }
}

/// What the panel knows when a key arrives.
struct KeyContext: Equatable, Sendable {
    /// A document is open (reading mode).
    var reading: Bool
    /// The first responder is a text field's editor: plain keys and edit shortcuts are its own.
    var textFieldFocused: Bool
    /// An input method is composing (marked text): every key is the input method's.
    var composingText: Bool = false
}

/// The keyboard map of the panel (R4-11). A non-activating accessory panel has no main menu to
/// route key equivalents, so `FloatingPanel` asks this for every key press first:
/// Space play/pause, ← → previous/next sentence (reading mode, no text field focused), Esc and
/// ⌘W hide the panel, ⌘V reads the clipboard outside the text field (pastes inside it), ⌘O opens
/// a file, ⌘, opens Settings, ⌘Q quits, ⌘+ ⌘− ⌘0 text size, ⌘C copies a selection. In a text
/// field ⌘X ⌘C ⌘V ⌘A ⌘Z ⇧⌘Z are its edit actions; while an input method composes, every key is
/// the input method's. A held key repeats only the commands that repeat (`repeatsWhileHeld`).
enum KeyRouter {
    /// What the panel does with a key press.
    enum Routing: Equatable, Sendable {
        case run(AppCommand)
        /// The auto-repeat of a command that runs once per press: taken, nothing happens (no
        /// beep, no second toggle or clipboard read).
        case swallow
    }

    /// nil = not the app's key (the responder chain gets it).
    static func routing(for stroke: KeyStroke, in context: KeyContext) -> Routing? {
        guard let command = command(for: stroke, in: context) else { return nil }
        return stroke.isRepeat && !command.repeatsWhileHeld ? .swallow : .run(command)
    }

    static func command(for stroke: KeyStroke, in context: KeyContext) -> AppCommand? {
        if context.composingText { return nil }
        let modifiers = stroke.modifiers.subtracting(.shift)
        if modifiers == .command {
            return commandShortcut(stroke, in: context)
        }
        guard modifiers.isEmpty else { return nil }
        switch stroke.key {
        case .escape:
            return .hidePanel
        case .space where context.reading && !context.textFieldFocused && !stroke.modifiers.contains(.shift):
            return .togglePlayPause
        case .leftArrow where context.reading && !context.textFieldFocused:
            return .previousSentence
        case .rightArrow where context.reading && !context.textFieldFocused:
            return .nextSentence
        default:
            return nil
        }
    }

    private static func commandShortcut(_ stroke: KeyStroke, in context: KeyContext) -> AppCommand? {
        guard case .character(let character) = stroke.key else { return nil }
        let shift = stroke.modifiers.contains(.shift)
        if context.textFieldFocused, let edit = editAction(character, shift: shift) {
            return .edit(edit)
        }
        switch character {
        case "c" where !shift: return .edit(.copy)  // selected text in the banner or the header
        case "v" where !shift: return .readClipboard
        case "o" where !shift: return .openFile
        case ",": return .openSettings
        case "w" where !shift: return .hidePanel
        case "q" where !shift: return .quit
        case "=", "+": return .largerText
        case "-", "_": return .smallerText
        case "0": return .defaultTextSize
        default: return nil
        }
    }

    private static func editAction(_ character: String, shift: Bool) -> EditAction? {
        switch character {
        case "x" where !shift: .cut
        case "c" where !shift: .copy
        case "v" where !shift: .paste
        case "a" where !shift: .selectAll
        case "z": shift ? .redo : .undo
        default: nil
        }
    }

    /// The Settings window's own keys: ⌘W closes it, ⌘Q quits.
    static func settingsCommand(for stroke: KeyStroke) -> SettingsWindowCommand? {
        guard stroke.modifiers == .command, case .character(let character) = stroke.key else { return nil }
        switch character {
        case "w": return .close
        case "q": return .quit
        default: return nil
        }
    }
}

enum SettingsWindowCommand: Equatable, Sendable {
    case close
    case quit
}
