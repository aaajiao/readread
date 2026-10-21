import AppKit
import SwiftUI

/// The panel under the menu bar item: borderless, floating, non-activating (typing works without
/// taking the focus from the frontmost app, and a full-screen app keeps its Space, R4-20), shown
/// on every Space and next to full-screen windows, resizable within `ReadingPreferences` bounds.
///
/// An accessory app's main menu does not route keys to a non-activating panel, so the panel
/// routes every key press through `KeyRouter` first (R4-11): playback keys, Esc, the ⌘ shortcuts
/// and the text field's edit actions.
final class FloatingPanel: NSPanel {
    /// Reading mode (a document is open): Space and the arrows are playback keys.
    var isReading: () -> Bool = { false }
    /// A routed command (playback, Settings, hide, quit, text size).
    var onCommand: (AppCommand) -> Void = { _ in }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = ReadingPreferences.minimumPanelSize
        maxSize = ReadingPreferences.maximumPanelSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Keys

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, route(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        route(event) || super.performKeyEquivalent(with: event)
    }

    /// Esc from the text field's editor (and the responder chain).
    override func cancelOperation(_ sender: Any?) {
        onCommand(.hidePanel)
    }

    /// What the router needs to know about the panel right now.
    var keyContext: KeyContext {
        let editor = firstResponder as? NSTextView
        let editing = editor.map { $0.isFieldEditor || $0.isEditable } ?? false
        return KeyContext(reading: isReading(), textFieldFocused: editing, composingText: editor?.hasMarkedText() ?? false)
    }

    /// Handle `event` when the router maps it to a command; false = not ours.
    func route(_ event: NSEvent) -> Bool {
        guard let stroke = KeyStroke(event: event),
              let routing = KeyRouter.routing(for: stroke, in: keyContext) else { return false }
        guard case .run(let command) = routing else { return true }
        if case .edit(let action) = command {
            // Up the responder chain from the field editor (or the selected text), as the Edit
            // menu would send it.
            return (firstResponder ?? self).tryToPerform(action.selector, with: self)
        }
        onCommand(command)
        return true
    }
}

/// The panel's size from a drag on its resize grip: the top edge stays (it hangs from the menu
/// bar), the size stays within bounds.
enum PanelResize {
    static func frame(from start: CGRect, dragged translation: CGSize) -> CGRect {
        let size = ReadingPreferences.clampedPanelSize(
            CGSize(width: start.width + translation.width, height: start.height - translation.height))
        return CGRect(x: start.minX, y: start.maxY - size.height, width: size.width, height: size.height)
    }
}

/// The bottom-right grip: drag to resize the panel (a borderless window has no frame to drag).
struct PanelResizeGrip: NSViewRepresentable {
    /// The size when the drag ends.
    var onResized: (CGSize) -> Void

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        view.onResized = onResized
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.handle)
        view.setAccessibilityLabel(String(localized: "Resize the panel"))
        view.toolTip = String(localized: "Drag to resize the panel")
        return view
    }

    func updateNSView(_ view: GripView, context: Context) {
        view.onResized = onResized
    }

    final class GripView: NSView {
        var onResized: (CGSize) -> Void = { _ in }

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.tertiaryLabelColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            for inset in [4.0, 8.0, 12.0] where inset <= bounds.width {
                path.move(to: NSPoint(x: bounds.maxX - inset, y: bounds.minY + 1))
                path.line(to: NSPoint(x: bounds.maxX - 1, y: bounds.minY + inset))
            }
            path.stroke()
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let start = window.frame
            let origin = NSEvent.mouseLocation
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let location = NSEvent.mouseLocation
                let frame = PanelResize.frame(
                    from: start, dragged: CGSize(width: location.x - origin.x, height: location.y - origin.y))
                window.setFrame(frame, display: true)
                if next.type == .leftMouseUp { break }
            }
            onResized(window.frame.size)
        }
    }
}
