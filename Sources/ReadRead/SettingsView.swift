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
        case .voices: CGSize(width: 540, height: 370)
        case .reading: CGSize(width: 540, height: 310)
        case .advanced: CGSize(width: 540, height: 760)
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
                if appState.engineKind == .qwen {
                    Text("Qwen3-TTS has one voice per language. It always reads at speed 1.0; other speeds are played time-stretched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

/// The engine (Kokoro or Qwen3-TTS), high-quality mode, the logs, the pronunciation file and the
/// article cache.
struct AdvancedSettingsPane: View {
    @Bindable var appState: AppState
    /// The confirmation High-quality mode shows at first (for the UI renders; nil in the app).
    var confirming: HighQualityModeSection.Confirmation?

    var body: some View {
        Form {
            Section {
                // A radio group cannot disable one of its items (it still draws and takes clicks):
                // with only Kokoro to choose, the whole picker is disabled.
                Picker("Engine", selection: Binding(
                    get: { appState.engineKind },
                    set: { appState.setEngine($0) }
                )) {
                    Text("Kokoro (standard)").tag(EngineKind.kokoro)
                    Text("Qwen3-TTS (high quality)").tag(EngineKind.qwen)
                }
                .pickerStyle(.radioGroup)
                .disabled(!appState.canChooseQwen && appState.engineKind == .kokoro)
                if !appState.canChooseQwen {
                    Group {
                        if !appState.canRunQwen {
                            Text("This build of ReadRead cannot run high-quality mode.")
                        } else if appState.installerIsBusy {
                            Text("Available once the installer is done.")
                        } else if appState.installer.installState.hasNoHome {
                            Text(verbatim: HQInstallation.emptyHomeMessage)
                        } else if case .damaged = appState.installer.installState {
                            Text("Repair high-quality mode below first.")
                        } else {
                            Text("Install high-quality mode below first.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    HStack(spacing: 10) {
                        Text(appState.engineStatusText)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                        Button("Restart Engine") { appState.restartEngine() }
                            .disabled(appState.usingSystemVoice)
                            .help("Stop the voice engine and start it again")
                    }
                }
            } header: {
                Text("Voice engine")
            } footer: {
                SettingsNoticeFooter(appState: appState, section: .engine)
            }

            HighQualityModeSection(appState: appState, confirming: confirming)

            Section {
                LabeledContent("Log") {
                    pathRow(appState.engineLogURL?.path(percentEncoded: false) ?? "—") {
                        Button("Show Log") { appState.showLog(inSettings: true) }
                            .help("Open the voice engine log")
                    }
                }
                LabeledContent("Installer log") {
                    pathRow(appState.installer.logFileURL.path(percentEncoded: false)) {
                        Button("Show Log") { appState.showInstallerLog(inSettings: .files) }
                            .help("Open the log of the high-quality installer")
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

/// Settings › Advanced › High-quality mode: what it is, then the install's state with what can be
/// done about it: Install (after a confirmation), the running operation with Cancel, Verify and
/// Uninstall… (confirmed), Repair, Try Again after a failure or a cancel, the installer's log, and
/// Remove Downloaded Files… (confirmed) for what an install that never finished left.
struct HighQualityModeSection: View {
    /// What the section asks before it starts (inline, so it stays in the Settings window).
    enum Confirmation: Equatable {
        case install
        case uninstall
    }

    @Bindable var appState: AppState
    @State private var confirmation: Confirmation?

    init(appState: AppState, confirming: Confirmation? = nil) {
        self.appState = appState
        _confirmation = State(initialValue: confirming)
    }

    var body: some View {
        Section {
            Text("Qwen3-TTS reads more naturally. It runs on this Mac's GPU, downloads about 3.5 GB once (Python, its packages and the model) and uses about 3–4 GB of memory while reading; it stops 5 minutes after the last sentence.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            state
        } header: {
            Text("High-quality mode")
        } footer: {
            SettingsNoticeFooter(appState: appState, section: .highQuality)
        }
    }

    @ViewBuilder
    private var state: some View {
        switch appState.highQualityStatus {
        case .notInstalled:
            if confirmation == .install {
                installConfirmation
            } else if confirmation == .uninstall {
                uninstallConfirmation(freeing: nil)
            } else {
                HStack {
                    Spacer()
                    if appState.highQualityRemoval == .leftovers { removeLeftoversButton }
                    Button("Install High-Quality Mode (about 3.5 GB)") { confirmation = .install }
                        .help("Download and install Qwen3-TTS for this Mac (asks first)")
                }
            }
        case .running(let operation, let progress):
            InstallerProgressView(operation: operation, progress: progress)
            HStack {
                Button("Show Installer Log") { appState.showInstallerLog() }
                    .help("Open the installer's log")
                Spacer()
                Button("Cancel") { appState.cancelInstaller() }
                    .help("Stop the installer; installing again resumes where it stopped")
            }
        case .installed(let installation):
            LabeledContent("Model") {
                Text(verbatim: "Qwen3-TTS 1.7B · \(HQFormat.bytes(installation.modelBytes))")
                    .foregroundStyle(.secondary)
            }
            if let date = installation.installedAt {
                LabeledContent("Installed") {
                    Text(date, format: .dateTime.year().month().day())
                        .foregroundStyle(.secondary)
                }
            }
            if confirmation == .uninstall {
                uninstallConfirmation(freeing: installation.modelBytes + HQFormat.runtimeBytes)
            } else {
                HStack {
                    Spacer()
                    Button("Verify") { appState.runInstaller(.check) }
                        .help("Check every file of the installation without changing anything")
                    Button("Uninstall…") { confirmation = .uninstall }
                        .help("Remove high-quality mode from this Mac (asks first)")
                }
            }
        case .damaged(let reason):
            message(String(localized: "High-quality mode cannot be used: \(reason)"), isError: true)
            if appState.highQualityRemoval == .nothing {
                // No HQ home ($READREAD_HQ_HOME set but empty): nothing to repair or remove.
            } else if confirmation == .uninstall {
                uninstallConfirmation(freeing: nil)
            } else {
                HStack {
                    Spacer()
                    Button("Uninstall…") { confirmation = .uninstall }
                        .help("Remove high-quality mode from this Mac (asks first)")
                    Button("Repair") { appState.runInstaller(.install) }
                        .help("Install again: what is missing or damaged is downloaded again")
                }
            }
        case .failed(let operation, let failure):
            message(AppState.failureMessage(operation, failure), isError: true)
            outcomeActions(operation)
        case .cancelled(let operation):
            message(AppState.cancelledMessage(operation), isError: false)
            outcomeActions(operation)
        }
    }

    private var removeLeftoversButton: some View {
        Button("Remove Downloaded Files…") { confirmation = .uninstall }
            .help("Remove what an install that did not finish left on this Mac (asks first)")
    }

    private func message(_ text: String, isError: Bool) -> some View {
        Label {
            Text(verbatim: text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isError ? Color.orange : Color.secondary)
        }
        .font(.callout)
    }

    /// After a failure or a cancel: the same operation again (a failed verification also offers
    /// Repair), what is on disk can be removed (Uninstall…, or Remove Downloaded Files… after a
    /// first install that did not finish), and the log that says what happened.
    @ViewBuilder
    private func outcomeActions(_ operation: InstallerOperation) -> some View {
        if confirmation == .uninstall {
            uninstallConfirmation(freeing: appState.installer.installState.installation.map {
                $0.modelBytes + HQFormat.runtimeBytes
            })
        } else {
            HStack {
                Button("Show Installer Log") { appState.showInstallerLog() }
                    .help("Open the installer's log")
                Spacer()
                if operation != .uninstall {
                    switch appState.highQualityRemoval {
                    case .install:
                        Button("Uninstall…") { confirmation = .uninstall }
                            .help("Remove high-quality mode from this Mac (asks first)")
                    case .leftovers:
                        removeLeftoversButton
                    case .nothing:
                        EmptyView()
                    }
                }
                if operation == .check {
                    Button("Repair") { appState.runInstaller(.install) }
                        .help("Install again: what is missing or damaged is downloaded again")
                }
                Button("Try Again") { appState.runInstaller(operation) }
            }
        }
    }

    private var installConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Install high-quality mode?")
                .font(.callout.weight(.semibold))
            Text("About 3.5 GB is downloaded once: Python from GitHub, its packages from PyPI and the Qwen3-TTS model from Hugging Face. About 4.3 GB of free disk space is needed. You can cancel at any time; installing again resumes where it stopped.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { confirmation = nil }
                Button("Install") {
                    confirmation = nil
                    appState.runInstaller(.install)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// `freeing`: the bytes the install takes (nil: unknown, the install is damaged).
    private func uninstallConfirmation(freeing bytes: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Uninstall high-quality mode?")
                .font(.callout.weight(.semibold))
            Group {
                if let bytes {
                    Text("This removes Python, its packages and the model from this Mac and frees about \(HQFormat.bytes(bytes)). ReadRead then reads with Kokoro; high-quality mode can be installed again at any time.")
                } else {
                    Text("This removes what is left of high-quality mode from this Mac. ReadRead reads with Kokoro; high-quality mode can be installed again at any time.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { confirmation = nil }
                Button("Uninstall", role: .destructive) {
                    confirmation = nil
                    appState.runInstaller(.uninstall)
                }
            }
        }
    }
}

/// The running installer: the step ("Step 3 of 6: Model files") on a bar of the steps, and while a
/// file downloads, its name and its bytes ("1.2 GB of 2.4 GB") on a second bar.
struct InstallerProgressView: View {
    let operation: InstallerOperation
    let progress: InstallerProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                switch operation {
                case .install: Text("Installing high-quality mode…")
                case .check: Text("Verifying high-quality mode…")
                case .uninstall: Text("Uninstalling high-quality mode…")
                }
            }
            .font(.callout.weight(.semibold))
            ProgressView(value: Self.stepFraction(progress)) {
                Group {
                    if progress.stepIndex > 0 {
                        Text("Step \(String(progress.stepIndex)) of \(String(progress.stepCount)): \(HQFormat.stepTitle(progress.stepName))")
                    } else {
                        Text("Starting…")
                    }
                }
                .font(.caption)
            }
            if let file = progress.file {
                ProgressView(value: Self.fileFraction(progress)) {
                    Text(verbatim: file)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: file))
                } currentValueLabel: {
                    Text("\(HQFormat.bytes(progress.bytesDone)) of \(HQFormat.bytes(progress.bytesTotal))")
                        .font(.caption2)
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The steps done (the one running counts from its start).
    static func stepFraction(_ progress: InstallerProgress) -> Double {
        guard progress.stepCount > 0, progress.stepIndex > 0 else { return 0 }
        return min(1, Double(progress.stepIndex - 1) / Double(progress.stepCount))
    }

    static func fileFraction(_ progress: InstallerProgress) -> Double {
        guard progress.bytesTotal > 0 else { return 0 }
        return min(1, max(0, Double(progress.bytesDone) / Double(progress.bytesTotal)))
    }
}

/// Sizes and step names for High-quality mode.
enum HQFormat {
    /// python/ and venv/ of an install, next to the model (about 0.7 GB, tts_server/README).
    static let runtimeBytes: Int64 = 700_000_000

    /// "3.1 GB", "682 MB", "35 KB": decimal units, like the installer's (locale independent,
    /// like the speed label).
    static func bytes(_ count: Int64) -> String {
        let value = Double(max(0, count))
        if value >= 999_500_000 { return String(format: "%.1f GB", value / 1e9) }
        if value >= 999_500 { return String(format: "%.0f MB", value / 1e6) }
        return String(format: "%.0f KB", value / 1e3)
    }

    /// install-hq.sh's step names (English, for its log) as the section shows them.
    static func stepTitle(_ name: String) -> String {
        switch name {
        case "Standalone Python": "Python"
        case "Virtual environment (requirements-hq.lock)": String(localized: "Python packages")
        case "Model files": String(localized: "Model files")
        case "Import check", "Imports": String(localized: "Checking the packages")
        case "Smoke test: one Chinese sentence through the server": String(localized: "Test: one Chinese sentence")
        case "install.json": String(localized: "Install record (install.json)")
        case "Python and venv": String(localized: "Python and its packages")
        case "Model files (size and sha256)": String(localized: "Model files (size and checksum)")
        default: name.hasPrefix("Uninstall ") ? String(localized: "Removing the files") : name
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
        appState.refreshForSettings()
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
