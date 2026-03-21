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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "headphones",
                accessibilityDescription: "ReadRead"
            )
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    private func setupPanel() {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 440)
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
                self?.panel.orderOut(nil)
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
