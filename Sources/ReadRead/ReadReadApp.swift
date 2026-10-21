import AppKit
import SwiftUI

/// Started from main.swift (which handles --self-test first), not via @main.
struct ReadReadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No SwiftUI Settings scene content: ⌘, and the app menu's Settings… open the real
        // window (R4-21).
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// The app around AppState: the status item, the panel, the Settings window, and the ways in
/// from other apps (Services, Open With, a second launch, drops on the status item; R4-13).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, AppShell {
    private let appState = AppState()
    private var statusItem: StatusItemController?
    private var panel: FloatingPanel?
    private lazy var settingsWindow: SettingsWindowController = {
        let controller = SettingsWindowController(appState: appState)
        controller.onClose = { [weak self] in self?.settingsDidClose() }
        return controller
    }()
    private var eventMonitor: Any?
    private var showRequestObserver: (any NSObjectProtocol)?
    /// Files opened before the app finished launching ("Open With" launches it with them).
    private var pendingOpen: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appState.shell = self

        setupStatusItem()
        setupPanel()
        setupEventMonitor()
        NSApp.servicesProvider = self
        showRequestObserver = DistributedNotificationCenter.default().addObserver(
            forName: SingleInstance.showPanelRequest, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showPanel() }
        }
        launched = true
        if !pendingOpen.isEmpty {
            open(pendingOpen)
            pendingOpen = []
        }
        // The TTS server starts lazily: on the first read (prewarmed when a fetch or file open
        // begins), and it shuts down again after 15 idle minutes (Qwen3-TTS's after 5).
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let showRequestObserver {
            DistributedNotificationCenter.default().removeObserver(showRequestObserver)
        }
        appState.shutdown()
    }

    /// The app was opened again (Finder, Spotlight, the Dock): show the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    /// Open With › ReadRead, or files dropped on the app's icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            pendingOpen += urls
            return
        }
        open(urls)
    }

    private func open(_ urls: [URL]) {
        appState.handle(PasteboardItems(fileURLs: urls.filter(\.isFileURL), urls: urls.filter { !$0.isFileURL }))
        showPanel()
    }

    // MARK: - Services (Info.plist NSServices: NSMessage readAloud)

    /// Services › Read Aloud with ReadRead: the selected text or link.
    @objc(readAloud:userData:error:)
    func readAloud(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let items = SystemPasteboard.items(from: pasteboard)
        guard DropResolver.resolve(items) != .nothing else {
            error.pointee = String(localized: "There is no text or link to read.") as NSString
            return
        }
        appState.handle(items)
        showPanel()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let appState = self.appState
        let item = StatusItemController {
            StatusItemModel(state: appState.player.state, documentTitle: appState.document?.title)
        }
        item.onToggle = { [weak self] in self?.togglePanel() }
        item.onCommand = { [weak self] command in self?.appState.perform(command) }
        item.onDrop = { [weak self] items in
            self?.appState.handle(items)
            self?.showPanel()
        }
        statusItem = item
        observeStatusItem()
    }

    /// Re-read the status item's model whenever the playback state or the document changes.
    private func observeStatusItem() {
        withObservationTracking {
            statusItem?.update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatusItem() }
        }
    }

    // MARK: - Panel

    private func setupPanel() {
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: appState.panelSize))
        panel.isReading = { [weak self] in self?.appState.hasDocument ?? false }
        panel.onCommand = { [weak self] command in self?.appState.perform(command) }
        panel.delegate = self
        let hostingView = NSHostingView(rootView: ContentView(appState: appState))
        // The window's size drives the view (the panel is resizable), not the other way round.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        self.panel = panel
    }

    private func setupEventMonitor() {
        // A click in another app hides the panel, except while the file picker is open: its
        // clicks arrive as global events too (it runs out of process). R4-19: visible ones only.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.clickedElsewhere() }
        }
    }

    private func clickedElsewhere() {
        guard let panel, panel.isVisible, !appState.showFilePicker,
              !NSApp.windows.contains(where: { $0 is NSOpenPanel && $0.isVisible }) else { return }
        hidePanel()
    }

    private func togglePanel() {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel, (notification.object as? NSWindow) === panel else { return }
        appState.savePanelSize(panel.frame.size)
    }

    // MARK: - AppShell

    /// Under the status item (or at the top of the screen when the menu bar hides it), at the
    /// saved size; the app is not activated (R4-20).
    func showPanel() {
        guard let panel else { return }
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        let screen = statusItem?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = statusItem?.buttonFrameOnScreen ?? NSRect(x: visible.midX, y: visible.maxY, width: 0, height: 0)
        panel.setFrame(PanelPlacement.frame(size: appState.panelSize, under: anchor, in: visible), display: false)
        panel.makeKeyAndOrderFront(nil)
        appState.panelDidShow()
    }

    /// Ordered out; an app that was activated (file picker, Settings) gives the focus back.
    func hidePanel() {
        panel?.orderOut(nil)
        if NSApp.isActive, !settingsWindow.isVisible {
            NSApp.hide(nil)
        }
    }

    func showSettings() {
        settingsWindow.show()
    }

    var isSettingsVisible: Bool { settingsWindow.isVisible }

    func activateApp() {
        NSApp.activate()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func settingsDidClose() {
        if panel?.isVisible != true, NSApp.isActive {
            NSApp.hide(nil)
        }
    }
}
