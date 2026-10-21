import AppKit

/// What the menu bar item shows and offers (R4-12): the 🤓 icon with a small waveform next to
/// it while reading (an ellipsis while the next sentence is synthesized), and the right-click menu.
struct StatusItemModel: Equatable {
    enum Indicator: Equatable {
        case none
        case reading
        case buffering

        /// The SF Symbol drawn next to the icon.
        var symbolName: String? {
            switch self {
            case .none: nil
            case .reading: "waveform"
            case .buffering: "ellipsis"
            }
        }
    }

    struct MenuEntry: Equatable {
        let title: String
        let command: AppCommand
        let enabled: Bool
    }

    let indicator: Indicator
    let toolTip: String
    /// nil = a separator.
    let menu: [MenuEntry?]

    init(state: PlaybackController.State, documentTitle: String?) {
        let hasDocument = documentTitle != nil
        let active = state == .playing || state == .buffering
        indicator = switch state {
        case .playing: .reading
        case .buffering: .buffering
        default: .none
        }
        if let documentTitle {
            toolTip = switch state {
            case .playing, .buffering: String(localized: "ReadRead — reading: \(documentTitle)")
            case .paused: String(localized: "ReadRead — paused: \(documentTitle)")
            default: String(localized: "ReadRead — \(documentTitle)")
            }
        } else {
            toolTip = "ReadRead"
        }
        menu = [
            MenuEntry(title: active ? String(localized: "Pause") : String(localized: "Play"),
                      command: .togglePlayPause, enabled: hasDocument),
            MenuEntry(title: String(localized: "Previous Sentence"), command: .previousSentence, enabled: hasDocument),
            MenuEntry(title: String(localized: "Next Sentence"), command: .nextSentence, enabled: hasDocument),
            MenuEntry(title: String(localized: "Stop"), command: .stop, enabled: hasDocument && state != .idle),
            nil,
            MenuEntry(title: String(localized: "Open File…"), command: .openFile, enabled: true),
            MenuEntry(title: String(localized: "Read Clipboard"), command: .readClipboard, enabled: true),
            nil,
            MenuEntry(title: String(localized: "Settings…"), command: .openSettings, enabled: true),
            MenuEntry(title: String(localized: "Quit ReadRead"), command: .quit, enabled: true),
        ]
    }
}

/// The NSStatusItem: a left click toggles the panel, a right click (or ⌃-click) opens the menu,
/// and files, links and text dropped on it are read (the status bar window forwards the drag to
/// its delegate, this object).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    private let statusItem: NSStatusItem
    private let icon: NSImage
    private var shown: StatusItemModel?
    private var model: () -> StatusItemModel
    var onToggle: () -> Void = {}
    var onCommand: (AppCommand) -> Void = { _ in }
    var onDrop: (PasteboardItems) -> Void = { _ in }

    init(model: @escaping () -> StatusItemModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        icon = Self.loadMenuBarIcon()
        super.init()
        if let button = statusItem.button {
            button.image = icon
            button.imagePosition = .imageOnly
            button.action = #selector(clicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.window?.registerForDraggedTypes(DropResolver.acceptedPasteboardTypes)
            button.window?.delegate = self
        }
        update()
    }

    /// The button in screen coordinates (the panel opens under it).
    var buttonFrameOnScreen: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    var screen: NSScreen? { statusItem.button?.window?.screen }

    /// Re-read the model (state or title changed).
    func update() {
        let current = model()
        guard current != shown, let button = statusItem.button else { return }
        if current.indicator != shown?.indicator {
            button.image = Self.image(icon: icon, indicator: current.indicator)
        }
        button.toolTip = current.toolTip
        button.setAccessibilityLabel(current.toolTip)
        shown = current
    }

    // MARK: - Clicks and the menu

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            onToggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in model().menu {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = entry.enabled
            item.representedObject = MenuCommand(entry.command)
            menu.addItem(item)
        }
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated { statusItem.menu = nil }
    }

    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        guard let command = (sender.representedObject as? MenuCommand)?.command else { return }
        onCommand(command)
    }

    private final class MenuCommand: NSObject {
        let command: AppCommand
        init(_ command: AppCommand) { self.command = command }
    }

    // MARK: - Drag and drop

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let items = SystemPasteboard.items(from: sender.draggingPasteboard)
        guard DropResolver.resolve(items) != .nothing else { return [] }
        statusItem.button?.highlight(true)
        return .copy
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        statusItem.button?.highlight(false)
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        statusItem.button?.highlight(false)
        let items = SystemPasteboard.items(from: sender.draggingPasteboard)
        guard !items.isEmpty else { return false }
        onDrop(items)
        return true
    }

    // MARK: - The icon

    /// The owner's 🤓 from Contents/Resources (copied there by build-app.sh). Under `swift run`
    /// there is no bundle, so an SF Symbol stands in. Never Bundle.module: its accessor crashes
    /// when the dev .build path is absent.
    static func loadMenuBarIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "menubar-icon@2x", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        let symbol = NSImage(systemSymbolName: "headphones", accessibilityDescription: "ReadRead") ?? NSImage()
        symbol.isTemplate = true
        return symbol
    }

    /// The icon, and while reading a small symbol after it in the menu bar's text colour
    /// (resolved when it is drawn, so it follows a light or dark menu bar).
    static func image(icon: NSImage, indicator: StatusItemModel.Indicator) -> NSImage {
        guard let name = indicator.symbolName,
              let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)) else {
            return icon
        }
        let iconSize = NSSize(width: 18, height: 18)
        let symbolSize = symbol.size
        let gap: CGFloat = 2
        let size = NSSize(width: iconSize.width + gap + symbolSize.width, height: iconSize.height)
        let image = NSImage(size: size, flipped: false) { _ in
            icon.draw(in: NSRect(origin: .zero, size: iconSize))
            let tinted = NSImage(size: symbolSize, flipped: false) { rect in
                symbol.draw(in: rect)
                NSColor.labelColor.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let origin = NSPoint(x: iconSize.width + gap, y: (iconSize.height - symbolSize.height) / 2)
            tinted.draw(in: NSRect(origin: origin, size: symbolSize))
            return true
        }
        image.isTemplate = false
        image.cacheMode = .never
        return image
    }
}
