import SwiftUI
import AppKit

@main
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

        Task {
            await appState.startTTSServer()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        appState.ttsEngine.stop()
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

    private func loadMenuBarIcon() -> NSImage {
        // Try app bundle Resources/ first, then SPM bundle
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("menubar-icon@2x.png"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/menubar-icon@2x.png"),
            Bundle.module.url(forResource: "menubar-icon@2x", withExtension: "png", subdirectory: "Resources"),
        ]
        for case let url? in candidates {
            if let img = NSImage(contentsOf: url) {
                return img
            }
        }
        // Fallback to SF Symbol
        return NSImage(systemSymbolName: "headphones", accessibilityDescription: "ReadRead")!
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
                // Don't close panel while a file picker is open
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

        // Keep panel on screen
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let screenFrame = screen.visibleFrame
            x = max(screenFrame.minX + 8, min(x, screenFrame.maxX - panelWidth - 8))
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
