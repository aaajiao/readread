import AppKit
import SwiftUI

/// The Settings window's tabs (R4-21), shown as its toolbar.
enum SettingsTab: String, CaseIterable, Hashable, Sendable {
    case general
    case voices
    case reading
    case advanced

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .voices: String(localized: "Voices")
        case .reading: String(localized: "Reading")
        case .advanced: String(localized: "Advanced")
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .voices: "person.wave.2"
        case .reading: "text.alignleft"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

/// The keyboard shortcuts, as Settings › General lists them (the routing is `KeyRouter`).
enum ShortcutHelp {
    struct Entry: Identifiable {
        let keys: String
        let action: LocalizedStringKey
        var id: String { keys }
    }

    static var entries: [Entry] { [
        Entry(keys: "Space", action: LocalizedStringKey("Play or pause")),
        Entry(keys: "← →", action: LocalizedStringKey("Previous or next sentence")),
        Entry(keys: "⌘V", action: LocalizedStringKey("Read the clipboard (outside the text field)")),
        Entry(keys: "⌘O", action: LocalizedStringKey("Open a file")),
        Entry(keys: "⌘+  ⌘−  ⌘0", action: LocalizedStringKey("Larger, smaller, default text size")),
        Entry(keys: "⌘,", action: LocalizedStringKey("Settings")),
        Entry(keys: "Esc  ⌘W", action: LocalizedStringKey("Hide the panel")),
        Entry(keys: "⌘Q", action: LocalizedStringKey("Quit ReadRead")),
    ] }
}

/// One tab of the Settings window: General, Voices, Reading or Advanced (the window's toolbar
/// switches between them).
struct SettingsView: View {
    /// Each tab's size: the window takes it when the tab is chosen (as Settings windows do).
    static func size(for tab: SettingsTab) -> CGSize {
        switch tab {
        case .general: CGSize(width: 540, height: 600)
        case .voices: CGSize(width: 540, height: 350)
        case .reading: CGSize(width: 540, height: 310)
        case .advanced: CGSize(width: 540, height: 480)
        }
    }

    @Bindable var appState: AppState
    let tab: SettingsTab

    var body: some View {
        let size = Self.size(for: tab)
        Group {
            switch tab {
            case .general: GeneralSettingsPane(appState: appState)
            case .voices: VoicesSettingsPane(appState: appState)
            case .reading: ReadingSettingsPane(appState: appState)
            case .advanced: AdvancedSettingsPane(appState: appState)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Launch at login, the shortcuts, Services and drops.
struct GeneralSettingsPane: View {
    @Bindable var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { appState.loginItemStatus == .enabled || appState.loginItemStatus == .requiresApproval },
                    set: { appState.setLaunchAtLogin($0) }
                ))
                .disabled(appState.loginItemStatus == .unavailable)
                LabeledContent("Status") {
                    Text(Self.statusText(appState.loginItemStatus))
                        .foregroundStyle(.secondary)
                }
                if appState.loginItemStatus == .requiresApproval {
                    Button("Open Login Items Settings…") { appState.openLoginItemsSettings() }
                }
            } footer: {
                SettingsNoticeFooter(appState: appState, section: .launchAtLogin)
            }

            Section("Keyboard shortcuts in the panel") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(ShortcutHelp.entries) { entry in
                        GridRow {
                            Text(verbatim: entry.keys)
                                .font(.callout.monospaced())
                                .gridColumnAlignment(.trailing)
                            Text(entry.action)
                        }
                    }
                }
            }

            Section("From other apps") {
                Text("Select text or a link in any app and choose Services › Read Aloud with ReadRead (also in the right-click menu). A shortcut can be set in System Settings › Keyboard › Keyboard Shortcuts › Services.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Files, links and text can also be dropped on the menu bar icon or the panel, and files opened with Open With › ReadRead.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { appState.refreshLoginItemStatus() }
    }

    static func statusText(_ status: LoginItemStatus) -> LocalizedStringKey {
        switch status {
        case .enabled: LocalizedStringKey("ReadRead opens when you log in.")
        case .requiresApproval: LocalizedStringKey("Waiting for approval in System Settings › General › Login Items & Extensions.")
        case .disabled: LocalizedStringKey("Off")
        case .unavailable: LocalizedStringKey("Only available for the installed app (ReadRead.app).")
        }
    }
}

/// A voice and a speed per language.
struct VoicesSettingsPane: View {
    @Bindable var appState: AppState

    var body: some View {
        Form {
            ForEach(SpeechLanguage.allCases, id: \.self) { language in
                Section {
                    LabeledContent("Voice") {
                        HStack(spacing: 6) {
                            VoicePickerButton(appState: appState, language: language, inSettings: true)
                                .frame(width: 210)
                            VoicePreviewButton(appState: appState, voice: appState.voice(for: language), inSettings: true)
                        }
                    }
                    LabeledContent("Speed") {
                        SpeedControl(appState: appState, language: language, style: .slider)
                            .frame(width: 240)
                    }
                } header: {
                    Text(verbatim: VoiceAccent.languageName(language))
                }
            }
            Section {
                Text("A document is read with the voice of its language; ▶ plays a short sample at speed 1.0 (the document pauses meanwhile).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if appState.usingSystemVoice {
                    Text("The system voice is in use; these voices apply again after Use Kokoro.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                SettingsNoticeFooter(appState: appState, section: .preview)
            }
        }
        .formStyle(.grouped)
    }
}

/// Text size, following the reading, and how web pages are read.
struct ReadingSettingsPane: View {
    @Bindable var appState: AppState

    var body: some View {
        Form {
            Section {
                LabeledContent("Text size") {
                    HStack(spacing: 10) {
                        Button { appState.perform(.smallerText) } label: {
                            Image(systemName: "textformat.size.smaller")
                        }
                        .disabled(!appState.canShrinkText)
                        .help("Smaller text (⌘−)")
                        .accessibilityLabel(Text("Smaller text"))
                        Text("\(String(Int(appState.fontSize))) pt")
                            .monospacedDigit()
                            .frame(minWidth: 40)
                        Button { appState.perform(.largerText) } label: {
                            Image(systemName: "textformat.size.larger")
                        }
                        .disabled(!appState.canEnlargeText)
                        .help("Larger text (⌘+)")
                        .accessibilityLabel(Text("Larger text"))
                        Button("Default") { appState.perform(.defaultTextSize) }
                            .disabled(appState.fontSize == ReadingPreferences.defaultFontSize)
                            .help("Default text size (⌘0)")
                    }
                }
                Toggle("Follow the sentence being read", isOn: Binding(
                    get: { appState.autoFollow },
                    set: { appState.setAutoFollow($0) }
                ))
                Text("Scrolling by hand pauses following until Back to Current or the next sentence in view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Web pages") {
                Picker("Read web pages", selection: Binding(
                    get: { appState.extractionMode },
                    set: { appState.setExtractionMode($0) }
                )) {
                    Text("On this Mac first").tag(ExtractionMode.localFirst)
                    Text("With defuddle.md only").tag(ExtractionMode.remoteOnly)
                }
                Group {
                    switch appState.extractionMode {
                    case .localFirst:
                        Text("Pages are read on this Mac; if that fails, the address is sent to defuddle.md (never a local address, such as localhost, a .local name or a private IP address).")
                    case .remoteOnly:
                        Text("Every page address is sent to defuddle.md (local addresses, such as localhost, .local names and private IP addresses, are still read on this Mac).")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

/// The engine, its log, the pronunciation file and the article cache.
struct AdvancedSettingsPane: View {
    @Bindable var appState: AppState

    var body: some View {
        Form {
            Section {
                // v0.5.0 adds the Qwen engine here.
                Picker("Engine", selection: .constant("kokoro")) {
                    Text(verbatim: "Kokoro").tag("kokoro")
                }
                .disabled(true)
                LabeledContent("Status") {
                    Text(appState.engineStatusText)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Restart Engine") { appState.restartEngine() }
                        .disabled(appState.usingSystemVoice)
                        .help("Stop the voice engine and start it again")
                }
            } header: {
                Text("Voice engine")
            } footer: {
                SettingsNoticeFooter(appState: appState, section: .engine)
            }

            Section {
                LabeledContent("Log") {
                    pathRow(appState.engine.logFileURL?.path(percentEncoded: false) ?? "—") {
                        Button("Show Log") { appState.showLog(inSettings: true) }
                            .help("Open the voice engine log")
                    }
                }
                LabeledContent("Pronunciations") {
                    pathRow(appState.userLexiconURL.path(percentEncoded: false)) {
                        Button("Show in Finder") { appState.revealUserLexicon() }
                            .help("Show your Chinese pronunciation file (created empty if there is none)")
                    }
                }
            } header: {
                Text("Files")
            } footer: {
                SettingsNoticeFooter(appState: appState, section: .files)
            }

            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("Web pages are kept for 30 days, so they open again at once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Clear Cached Articles") { appState.clearArticleCache() }
                }
            } header: {
                Text("Article cache")
            } footer: {
                SettingsNoticeFooter(appState: appState, section: .articleCache)
            }
        }
        .formStyle(.grouped)
    }

    private func pathRow(_ path: String, @ViewBuilder button: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(Text(verbatim: path))
            button()
        }
    }
}

/// The result of a Settings action (R4-21) under the section it came from, while the window is
/// open (`AppState.settingsNotice`).
struct SettingsNoticeFooter: View {
    let appState: AppState
    let section: SettingsNotice.Section

    var body: some View {
        if let notice = appState.settingsNotice, notice.section == section {
            Label {
                Text(verbatim: notice.message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(notice.isError ? Color.orange : Color.secondary)
            }
            .font(.caption)
            .foregroundStyle(notice.isError ? Color.primary : Color.secondary)
        }
    }
}

// MARK: - The window

/// The Settings window: a plain NSWindow whose toolbar holds the tabs (an NSTabViewController,
/// one SwiftUI view per tab), brought to the front with the app (an accessory app's SwiftUI
/// Settings scene does not reliably come forward, R4-21).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private var window: SettingsWindow?
    /// The window closed (the app hides again unless the panel is shown).
    var onClose: () -> Void = {}

    init(appState: AppState) {
        self.appState = appState
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        appState.refreshLoginItemStatus()
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window?.performClose(nil)
    }

    /// The window, not shown (`show` orders it in).
    func makeWindow() -> SettingsWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let content = NSHostingController(rootView: SettingsView(appState: appState, tab: tab))
            content.sizingOptions = [.preferredContentSize]
            content.title = tab.title
            let item = NSTabViewItem(viewController: content)
            item.identifier = tab.rawValue
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        let window = SettingsWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        appState.clearSettingsNotice()
        onClose()
    }
}

/// ⌘W closes, ⌘Q quits, also while the app's menu bar is not the one shown.
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let stroke = KeyStroke(event: event), let command = KeyRouter.settingsCommand(for: stroke) {
            switch command {
            case .close: performClose(nil)
            case .quit: NSApp.terminate(nil)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
