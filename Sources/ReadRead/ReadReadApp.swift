import SwiftUI
import AppKit

/// Started from main.swift (which handles --self-test first), not via @main.
struct ReadReadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private let appState = AppState()
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPanel()
        setupEventMonitor()
        // The TTS server starts lazily: on the first read (prewarmed when a fetch
        // or file open begins), and it shuts down again after 15 idle minutes.
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        appState.shutdown()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = loadMenuBarIcon()
            image.size = NSSize(width: 18, height: 18)
            button.image = image
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    /// The icon from Contents/Resources (copied there by build-app.sh). Under
    /// `swift run` there is no bundle, so fall back to an SF Symbol. Never
    /// Bundle.module: its accessor crashes when the dev .build path is absent.
    private func loadMenuBarIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "menubar-icon@2x", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        let symbol = NSImage(systemSymbolName: "headphones", accessibilityDescription: "ReadRead") ?? NSImage()
        symbol.isTemplate = true
        return symbol
    }

    private func setupPanel() {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560)
        )
        panel.contentView = NSHostingView(
            rootView: ContentView(appState: appState)
        )
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                let hasOpenPanel = NSApp.windows.contains { $0 is NSOpenPanel }
                if !hasOpenPanel {
                    self?.panel.orderOut(nil)
                }
            }
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonRect = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )

        let panelWidth = panel.frame.width
        let panelHeight = panel.frame.height

        var x = buttonRect.midX - panelWidth / 2
        let y = buttonRect.minY - panelHeight - 4

        if let screen = buttonWindow.screen ?? NSScreen.main {
            let screenFrame = screen.visibleFrame
            x = max(screenFrame.minX + 8, min(x, screenFrame.maxX - panelWidth - 8))
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
