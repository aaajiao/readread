import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var appState: AppState

    /// Text and Markdown files (Markdown is plain text, listed so the picker always offers it).
    static let readableTypes: [UTType] = [.plainText] + ["md", "markdown"].compactMap {
        UTType(filenameExtension: $0, conformingTo: .plainText)
    }

    private var player: PlaybackController { appState.player }

    var body: some View {
        VStack(spacing: 0) {
            if let document = appState.document {
                // ── Reading mode ──
                readingHeader(document)
                Divider()
                readingSection(document)
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
        .fileImporter(isPresented: $appState.showFilePicker, allowedContentTypes: Self.readableTypes) { result in
            switch result {
            case .success(let url):
                appState.openFile(url: url)
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

                Text("Paste a URL, a file path or text, or open a file to start reading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("URL, file path or text…", text: $appState.urlInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit { appState.submit() }

                    Button {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            appState.urlInput = text
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
                        appState.submit()
                    } label: {
                        Label("Read", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(appState.urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || appState.isLoading)

                    Button {
                        appState.showFilePicker = true
                    } label: {
                        Label("Open File", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Spacer()

                    if appState.isLoading {
                        ProgressView()
                            .controlSize(.small)
                        Button("Cancel") { appState.cancelLoad() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Reading Header

    private func readingHeader(_ document: ReadingDocument) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(2)

                if !document.sourceLabel.isEmpty {
                    if case .url(let url) = document.source {
                        Link(document.sourceLabel, destination: url)
                            .font(.caption)
                    } else {
                        Text(document.sourceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button {
                appState.closeDocument()
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

    private func readingSection(_ document: ReadingDocument) -> some View {
        let current = document.units.indices.contains(player.currentUnit) ? document.units[player.currentUnit] : nil
        return VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                            BlockView(
                                block: block,
                                highlight: current?.block == index ? current?.range : nil,
                                isPast: (current?.block ?? 0) > index
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !block.units.isEmpty { player.seek(to: block.units.lowerBound) }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: current?.block) { _, block in
                    guard let block else { return }
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(block, anchor: .center)
                    }
                }
            }

            VStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    ProgressView(value: player.progress)
                        .progressViewStyle(.linear)
                }

                HStack(spacing: 24) {
                    Button { player.previous() } label: {
                        Image(systemName: "backward.fill")
                    }
                    .help("Previous sentence")

                    Button { player.toggle() } label: {
                        playPauseIcon
                    }
                    .help(player.state == .playing || player.state == .buffering ? "Pause" : "Play")

                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                    }
                    .help("Next sentence")

                    Spacer()

                    if player.readableCount > 0 {
                        Text("\(player.readablePosition) / \(player.readableCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Button { player.stop() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var playPauseIcon: some View {
        switch player.state {
        case .buffering:
            ZStack {
                Image(systemName: "pause.circle.fill").font(.title).opacity(0.25)
                ProgressView().controlSize(.small)
            }
        case .playing:
            Image(systemName: "pause.circle.fill").font(.title)
        default:
            Image(systemName: "play.circle.fill").font(.title)
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

                // Only voices of the document's language: the voice decides the
                // pronunciation (ZH / EN-US / EN-GB).
                Picker("Voice", selection: Binding(
                    get: { appState.selectedVoice.id },
                    set: { id in if let voice = Voice.voice(id: id) { appState.selectVoice(voice) } }
                )) {
                    ForEach(appState.voicesForSettingsLanguage) { voice in
                        Text(voice.pickerLabel).tag(voice.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(appState.usingSystemVoice)

                if appState.hasDocument {
                    Picker("Language", selection: Binding(
                        get: { appState.languageChoice },
                        set: { appState.setLanguageChoice($0) }
                    )) {
                        Text("Auto").tag(LanguageChoice.auto)
                        Text("中文").tag(LanguageChoice.zh)
                        Text("English").tag(LanguageChoice.en)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Read the document as detected, or all in Chinese or English")
                }
            }

            HStack {
                Text("Speed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)

                Slider(value: Binding(get: { appState.speed }, set: { appState.setSpeed($0) }),
                       in: SynthesisRequest.speedRange, step: 0.1)

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
            if appState.usingSystemVoice {
                Image(systemName: "person.wave.2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("System voice")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Use Kokoro") { appState.useEngineVoice() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            } else if appState.engineStatus == .starting {
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
                    appState.dismissError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            HStack(spacing: 14) {
                Spacer()
                if appState.offersSystemVoice {
                    Button("Use System Voice") { appState.useSystemVoice() }
                        .help("Read with the macOS system voice until the voice engine works again")
                }
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

/// One block of the reading view; the current sentence's span is highlighted.
private struct BlockView: View, Equatable {
    let block: ReadingBlock
    /// The current unit's span of `block.text`, in Character offsets.
    let highlight: Range<Int>?
    /// Before the current sentence (dimmed).
    let isPast: Bool

    var body: some View {
        Text(Self.attributed(block.text, highlight: highlight))
            .font(font)
            .lineSpacing(5)
            .opacity(highlight != nil ? 1 : isPast ? 0.4 : 0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, block.kind == .listItem || block.kind == .quote ? 26 : 14)
            .padding(.trailing, 14)
    }

    private var font: Font {
        switch block.kind {
        case .title: .system(size: 15, weight: .semibold)
        case .heading: .system(size: 14, weight: .semibold)
        case .quote: .system(size: 13).italic()
        case .paragraph, .listItem: .system(size: 13)
        }
    }

    static func attributed(_ text: String, highlight: Range<Int>?) -> AttributedString {
        var string = AttributedString(text)
        guard let highlight, !highlight.isEmpty else { return string }
        let characters = string.characters
        guard let start = characters.index(characters.startIndex, offsetBy: highlight.lowerBound,
                                           limitedBy: characters.endIndex),
              let end = characters.index(start, offsetBy: highlight.count, limitedBy: characters.endIndex) else {
            return string
        }
        string[start..<end].backgroundColor = Color.accentColor.opacity(0.22)
        return string
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
