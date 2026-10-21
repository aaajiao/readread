import SwiftUI
import UniformTypeIdentifiers

/// The panel: its content on Liquid Glass (R4-22), the resize grip, and drops: files, links and
/// text dropped anywhere on it are read (R4-13).
struct ContentView: View {
    static let cornerRadius: CGFloat = 16

    @Bindable var appState: AppState
    @State private var dropTargeted = false

    var body: some View {
        PanelContent(appState: appState)
            .frame(minWidth: ReadingPreferences.minimumPanelSize.width, maxWidth: .infinity,
                   minHeight: ReadingPreferences.minimumPanelSize.height, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: Self.cornerRadius))
            .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                PanelResizeGrip { appState.savePanelSize($0) }
                    .frame(width: 14, height: 14)
                    .padding(3)
            }
            .onDrop(of: DropResolver.acceptedTypes, isTargeted: $dropTargeted) { providers in
                Task { appState.handle(await ItemProviderReader.items(from: providers)) }
                return true
            }
            .fileImporter(isPresented: $appState.showFilePicker, allowedContentTypes: ReadableFileType.utTypes) { result in
                switch result {
                case .success(let url):
                    appState.openFile(url: url)
                case .failure(let error):
                    appState.showError(error)
                }
            }
    }
}

/// What the panel shows: input mode (no document) or reading mode, the banners, the bottom bar.
struct PanelContent: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let document = appState.document {
                // ── Reading mode ──
                ReadingHeader(appState: appState, document: document)
                Divider()
                ReadingView(appState: appState, document: document)
                Divider()
                ReadingSettingsSection(appState: appState)
            } else {
                // ── Input mode ──
                InputView(appState: appState)
            }

            if let message = appState.bannerMessage {
                MessageBanner(appState: appState, message: message,
                              kind: appState.errorMessage != nil ? .error : .notice)
            }

            if appState.errorNeedsSetup {
                SetupBanner()
            }

            Divider()
            BottomBar(appState: appState)
        }
    }
}

// MARK: - Input mode

/// The field for a URL, a path or text, Read / Open File… / the clipboard, and the voice and
/// speed of both languages (R4-07).
struct InputView: View {
    @Bindable var appState: AppState
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            VStack(spacing: 14) {
                Image(systemName: "book.closed")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(verbatim: "ReadRead")
                    .font(.title2)
                    .fontWeight(.medium)

                Text("Paste a URL, a file path or text, or open a file to start reading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("Files, links and text can also be dropped here or on the menu bar icon.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)

            Spacer(minLength: 12)

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("URL, file path or text…", text: $appState.urlInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($fieldFocused)
                        .onSubmit { appState.submit() }
                        .accessibilityLabel(Text("URL, file path or text"))

                    Button {
                        appState.readClipboard()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Read the clipboard (⌘V outside the field)")
                    .accessibilityLabel(Text("Read the clipboard"))
                }
                .padding(10)
                .background(.background.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Button {
                        appState.submit()
                    } label: {
                        Label("Read", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(appState.urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || appState.isLoading)
                    .help("Read it (Return)")

                    Button {
                        appState.requestOpenFile()
                    } label: {
                        Label("Open File…", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Open a text, Markdown, web page, Word, RTF, OpenDocument, PDF or EPUB file (⌘O)")

                    Spacer()

                    if appState.isLoading {
                        ProgressView()
                            .controlSize(.small)
                        Button("Cancel") { appState.cancelLoad() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help("Stop loading")
                    }
                }
            }
            .padding()

            Divider()

            VoiceSettingsGrid(appState: appState, compact: true)
                .padding(.horizontal)
                .padding(.vertical, 10)
        }
        .defaultFocus($fieldFocused, true)
        .onAppear { fieldFocused = true }
        .onChange(of: appState.panelShowCount) { fieldFocused = true }
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            if appState.usingSystemVoice {
                Image(systemName: "person.wave.2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("System voice")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Use Kokoro") { appState.useEngineVoice() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .help("Read with the Kokoro voices again")
            } else if appState.engineStatus == .starting {
                ProgressView()
                    .controlSize(.mini)
                Group {
                    if appState.engineKind == .qwen {
                        Text("Starting the high-quality engine…")
                    } else {
                        Text("Starting voice engine…")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else if appState.engineKind == .qwen {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("High-quality mode")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Reading with Qwen3-TTS (Settings › Advanced)")
            }

            Spacer()

            Text(verbatim: Self.versionLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button {
                appState.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Settings (⌘,)")
            .accessibilityLabel(Text("Settings"))

            Button("Quit") { appState.perform(.quit) }
                .buttonStyle(.borderless)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Quit ReadRead (⌘Q)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 20)
        .padding(.vertical, 8)
    }

    static var versionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "v\(version)"
    }
}

// MARK: - Banners

/// An error (with Retry, Show Log and the system-voice offer) or a notice: the full text,
/// selectable; long ones collapse to a few lines with Show More; Copy puts it on the clipboard
/// (R4-17).
struct MessageBanner: View {
    enum Kind {
        case error
        case notice
    }

    /// Lines a long message shows collapsed.
    static let collapsedLines = 3

    @Bindable var appState: AppState
    let message: String
    let kind: Kind
    @State private var expanded = false

    var body: some View {
        let long = Self.isLong(message)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(kind == .error ? Color.yellow : Color.accentColor)
                    .font(.caption)
                    .accessibilityHidden(true)
                if long && expanded {
                    ScrollView {
                        messageText
                    }
                    .frame(maxHeight: 150)
                } else {
                    messageText
                        .lineLimit(long ? Self.collapsedLines : nil)
                }
                Button {
                    appState.dismissError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel(Text("Dismiss"))
            }
            HStack(spacing: 14) {
                if long {
                    Button {
                        expanded.toggle()
                    } label: {
                        expanded ? Text("Show Less") : Text("Show More")
                    }
                    .help(expanded ? Text("Show the first lines only") : Text("Show the whole message"))
                }
                Spacer()
                Button("Copy") { appState.copyBannerMessage() }
                    .help("Copy the message")
                if kind == .error {
                    if appState.offersKokoro {
                        Button("Use Kokoro") { appState.useKokoro() }
                            .help("Read with Kokoro from this sentence on")
                    }
                    if appState.offersSystemVoice {
                        Button("Use System Voice") { appState.useSystemVoice() }
                            .help("Read with the macOS system voice until the voice engine works again")
                    }
                    Button("Show Log") { appState.showLog() }
                        .help("Open the voice engine log")
                    Button("Retry") { appState.retry() }
                        .help("Restart the voice engine if needed and continue")
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(kind == .error ? Color.red.opacity(0.08) : Color.accentColor.opacity(0.06))
    }

    private var messageText: some View {
        Text(verbatim: message)
            .font(.caption)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func isLong(_ message: String) -> Bool {
        message.count > 240 || message.filter(\.isNewline).count >= collapsedLines
    }
}

struct SetupBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TTS Setup Required")
                .font(.caption)
                .bold()
            Group {
                if Bundle.main.bundleURL.pathExtension == "app" {
                    Text("Rebuild the app: ./scripts/build-app.sh")
                } else {
                    Text("Run: ./scripts/setup.sh")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }
}
