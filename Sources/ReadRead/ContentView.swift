import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if appState.hasContent {
                // ── Reading mode ──
                readingHeader
                Divider()
                readingSection
                Divider()
                settingsSection
            } else {
                // ── Input mode ──
                inputSection
                Spacer(minLength: 0)
                Divider()
                settingsSection
            }

            if let error = appState.errorMessage {
                errorBanner(error)
            }

            if appState.errorNeedsSetup {
                setupBanner
            }

            Divider()
            bottomBar
        }
        .frame(width: 380, height: 560)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: appState.selectedVoice) {
            appState.saveLanguagePreferences()
            appState.restartCurrentChunk()
        }
        .onChange(of: appState.speed) {
            appState.saveLanguagePreferences()
            appState.restartCurrentChunk()
        }
        .fileImporter(
            isPresented: $appState.showFilePicker,
            allowedContentTypes: [.plainText]
        ) { result in
            switch result {
            case .success(let url):
                Task { await appState.openFile(url: url) }
            case .failure(let error):
                appState.showError(error)
            }
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "book.closed")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)

                Text("ReadRead")
                    .font(.title2)
                    .fontWeight(.medium)

                Text("Paste a URL or open a file to start reading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("Paste URL here...", text: $appState.urlInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit { Task { await appState.fetchURL() } }

                    Button {
                        if let str = NSPasteboard.general.string(forType: .string) {
                            appState.urlInput = str
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Paste from clipboard")
                }
                .padding(10)
                .background(.background.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Button {
                        Task { await appState.fetchURL() }
                    } label: {
                        Label("Read", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(appState.urlInput.isEmpty || appState.playbackState == .loading)

                    Button {
                        appState.showFilePicker = true
                    } label: {
                        Label("Open File", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Spacer()

                    if appState.playbackState == .loading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Reading Header

    private var readingHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.currentTitle)
                    .font(.headline)
                    .lineLimit(2)

                if !appState.currentDomain.isEmpty {
                    Text(appState.currentDomain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .onTapGesture {
                            var input = appState.urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !input.isEmpty {
                                if !input.contains("://") {
                                    input = "https://" + input
                                }
                                if let url = URL(string: input) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                }
            }

            Spacer()

            Button {
                appState.stop()
                appState.currentText = ""
                appState.currentTitle = ""
                appState.currentDomain = ""
                appState.textChunks = []
                appState.urlInput = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close and return to input")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Reading

    private var readingSection: some View {
        VStack(spacing: 8) {
            // Scrollable text display — continuous flow
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(appState.textChunks.enumerated()), id: \.offset) { index, chunk in
                            Text(chunk)
                                .font(.system(size: 13, design: .default))
                                .lineSpacing(5)
                                .opacity(
                                    index == appState.currentChunkIndex
                                        ? 1.0
                                        : index < appState.currentChunkIndex
                                            ? 0.3
                                            : 0.5
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 4)
                                .id(index)
                                .animation(.easeInOut(duration: 0.4), value: appState.currentChunkIndex)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity)
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 12)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 12)
                    }
                )
                .onChange(of: appState.currentChunkIndex) { _, newIndex in
                    withAnimation(.easeInOut(duration: 0.6)) {
                        proxy.scrollTo(newIndex, anchor: .top)
                    }
                }
            }

            // Progress + controls
            VStack(spacing: 8) {
                ProgressView(value: appState.progress)
                    .progressViewStyle(.linear)

                HStack(spacing: 24) {
                    Button { appState.previousChunk() } label: {
                        Image(systemName: "backward.fill")
                    }
                    .disabled(appState.currentChunkIndex == 0)

                    Button { appState.togglePlayPause() } label: {
                        Image(systemName: appState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title)
                    }

                    Button { appState.nextChunk() } label: {
                        Image(systemName: "forward.fill")
                    }
                    .disabled(appState.currentChunkIndex >= appState.textChunks.count - 1)

                    Spacer()

                    if !appState.textChunks.isEmpty {
                        Text("\(appState.currentChunkIndex + 1)/\(appState.textChunks.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Button { appState.stop() } label: {
                        Image(systemName: "stop.fill")
                    }
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Voice")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)

                // Only voices of the text's language: the voice decides the
                // pronunciation (ZH / EN-US / EN-GB).
                Picker("Voice", selection: $appState.selectedVoice) {
                    ForEach(appState.voicesForCurrentLanguage) { voice in
                        Text(voice.pickerLabel)
                            .tag(voice.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            HStack {
                Text("Speed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)

                Slider(value: $appState.speed, in: 0.5...2.0, step: 0.1)

                Text(String(format: "%.1fx", appState.speed))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 32)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if appState.engineStatus == .starting {
                ProgressView()
                    .controlSize(.mini)
                Text("Starting voice engine…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(appVersionLabel)
                .font(.caption2)
                .foregroundStyle(.quaternary)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var appVersionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "v\(version)"
    }

    // MARK: - Banners

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                // The full text, selectable so it can be copied into a bug report.
                if Self.isLongMessage(message) {
                    ScrollView {
                        errorText(message)
                    }
                    .frame(height: 110)
                } else {
                    errorText(message)
                }
                Button {
                    appState.clearError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            HStack(spacing: 14) {
                Spacer()
                Button("Show Log") { appState.showLog() }
                    .help("Open the voice engine log")
                Button("Retry") { appState.retry() }
                    .help("Restart the voice engine if needed and continue")
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.red.opacity(0.08))
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func isLongMessage(_ message: String) -> Bool {
        message.count > 360 || message.filter(\.isNewline).count >= 6
    }

    private var setupBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TTS Setup Required")
                .font(.caption)
                .bold()
            Text(Bundle.main.bundleURL.pathExtension == "app"
                 ? "Rebuild the app: ./scripts/build-app.sh"
                 : "Run: ./scripts/setup.sh")
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

// MARK: - Voice Model

/// The accent a voice speaks with; also the G2P route on the server.
enum VoiceAccent: String, Sendable {
    case zh
    case us
    case uk

    var label: String {
        switch self {
        case .zh: return "ZH"
        case .us: return "EN-US"
        case .uk: return "EN-GB"
        }
    }
}

struct Voice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let language: SpeechLanguage
    let accent: VoiceAccent

    var accentLabel: String { accent.label }
    var pickerLabel: String { "\(name) (\(accentLabel))" }

    /// The server routes by id prefix: zf_/zm_ → Chinese, af_/am_ → US English,
    /// bf_/bm_ → UK English.
    static func route(forID id: String) -> (language: SpeechLanguage, accent: VoiceAccent)? {
        switch id.prefix(3) {
        case "zf_", "zm_": return (.zh, .zh)
        case "af_", "am_": return (.en, .us)
        case "bf_", "bm_": return (.en, .uk)
        default: return nil
        }
    }

    /// The single list of voices in the app (order = picker order).
    static let all: [Voice] = [
        // Chinese (Kokoro v1.1-zh)
        zh("zf_001", "女声 001"),
        zh("zf_032", "女声 032"),
        zh("zm_009", "男声 009"),
        zh("zm_055", "男声 055"),
        // American English (Kokoro v1.0)
        us("af_heart", "Heart"),
        us("af_alloy", "Alloy"),
        us("af_aoede", "Aoede"),
        us("af_bella", "Bella"),
        us("af_jessica", "Jessica"),
        us("af_kore", "Kore"),
        us("af_nicole", "Nicole"),
        us("af_nova", "Nova"),
        us("af_river", "River"),
        us("af_sarah", "Sarah"),
        us("af_sky", "Sky"),
        us("am_adam", "Adam"),
        us("am_echo", "Echo"),
        us("am_eric", "Eric"),
        us("am_fenrir", "Fenrir"),
        us("am_liam", "Liam"),
        us("am_michael", "Michael"),
        us("am_onyx", "Onyx"),
        us("am_puck", "Puck"),
        // British English (Kokoro v1.0)
        uk("bf_alice", "Alice"),
        uk("bf_emma", "Emma"),
        uk("bf_isabella", "Isabella"),
        uk("bf_lily", "Lily"),
        uk("bm_daniel", "Daniel"),
        uk("bm_fable", "Fable"),
        uk("bm_george", "George"),
        uk("bm_lewis", "Lewis"),
    ]

    static let defaultVoiceIDs: [SpeechLanguage: String] = [.zh: "zf_001", .en: "af_heart"]

    static func voices(for language: SpeechLanguage) -> [Voice] {
        all.filter { $0.language == language }
    }

    static func voice(id: String) -> Voice? {
        all.first { $0.id == id }
    }

    /// The voice with this id, only if it reads `language`.
    static func voice(id: String, language: SpeechLanguage) -> Voice? {
        guard let voice = voice(id: id), voice.language == language else { return nil }
        return voice
    }

    static func defaultVoice(for language: SpeechLanguage) -> Voice {
        defaultVoiceIDs[language].flatMap { voice(id: $0) } ?? voices(for: language)[0]
    }

    /// Catalog voices that the server's `GET /voices` (`{"zh": […], "en": […]}`)
    /// does not list under their own language. Must be empty: `--self-test`, and
    /// with it the build's smoke test, fails otherwise.
    static func missing(from serverVoices: [String: [String]], in catalog: [Voice] = all) -> [Voice] {
        catalog.filter { !(serverVoices[$0.language.rawValue] ?? []).contains($0.id) }
    }

    private static func zh(_ id: String, _ name: String) -> Voice {
        Voice(id: id, name: name, language: .zh, accent: .zh)
    }

    private static func us(_ id: String, _ name: String) -> Voice {
        Voice(id: id, name: name, language: .en, accent: .us)
    }

    private static func uk(_ id: String, _ name: String) -> Voice {
        Voice(id: id, name: name, language: .en, accent: .uk)
    }
}
