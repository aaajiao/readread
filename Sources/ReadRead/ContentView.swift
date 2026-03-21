import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            inputSection

            if appState.hasContent {
                Divider()
                readingSection
            }

            Spacer(minLength: 0)

            Divider()
            settingsSection

            if let error = appState.errorMessage {
                errorBanner(error)
            }

            if case .error = appState.serverState {
                setupBanner
            }

            Divider()
            HStack {
                Spacer()
                Button("Quit ReadRead") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .frame(width: 360, height: 440)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: appState.selectedVoice) {
            appState.restartCurrentChunk()
        }
        .onChange(of: appState.speed) {
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
                appState.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Input

    private var inputSection: some View {
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

    // MARK: - Reading

    private var readingSection: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.currentTitle)
                    .font(.headline)
                    .lineLimit(2)

                if !appState.currentDomain.isEmpty {
                    Text(appState.currentDomain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                ProgressView(value: appState.progress)
                    .progressViewStyle(.linear)

                HStack {
                    if !appState.textChunks.isEmpty {
                        Text("\(appState.currentChunkIndex + 1) / \(appState.textChunks.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                }
            }

            HStack(spacing: 24) {
                Button { appState.previousChunk() } label: {
                    Image(systemName: "backward.fill")
                }
                .disabled(appState.currentChunkIndex == 0)

                Button { appState.togglePlayPause() } label: {
                    Image(systemName: appState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.largeTitle)
                }

                Button { appState.nextChunk() } label: {
                    Image(systemName: "forward.fill")
                }
                .disabled(appState.currentChunkIndex >= appState.textChunks.count - 1)

                Spacer()

                Button { appState.stop() } label: {
                    Image(systemName: "stop.fill")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding()
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Voice")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)

                Picker("", selection: $appState.selectedVoice) {
                    ForEach(Voice.all) { voice in
                        Text("\(voice.name) (\(voice.languageLabel))")
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

    // MARK: - Banners

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button {
                appState.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.red.opacity(0.08))
    }

    private var setupBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TTS Setup Required")
                .font(.caption)
                .bold()
            Text("Run: ./scripts/setup.sh")
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

struct Voice: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let gender: String

    var languageLabel: String {
        switch language {
        case "en-us": return "EN"
        case "en-gb": return "EN-GB"
        case "zh": return "ZH"
        case "ja": return "JA"
        case "fr": return "FR"
        case "es": return "ES"
        default: return language.uppercased()
        }
    }

    static let all: [Voice] = [
        // American English
        Voice(id: "af_heart", name: "Heart", language: "en-us", gender: "F"),
        Voice(id: "af_alloy", name: "Alloy", language: "en-us", gender: "F"),
        Voice(id: "af_aoede", name: "Aoede", language: "en-us", gender: "F"),
        Voice(id: "af_bella", name: "Bella", language: "en-us", gender: "F"),
        Voice(id: "af_jessica", name: "Jessica", language: "en-us", gender: "F"),
        Voice(id: "af_kore", name: "Kore", language: "en-us", gender: "F"),
        Voice(id: "af_nicole", name: "Nicole", language: "en-us", gender: "F"),
        Voice(id: "af_nova", name: "Nova", language: "en-us", gender: "F"),
        Voice(id: "af_river", name: "River", language: "en-us", gender: "F"),
        Voice(id: "af_sarah", name: "Sarah", language: "en-us", gender: "F"),
        Voice(id: "af_sky", name: "Sky", language: "en-us", gender: "F"),
        Voice(id: "am_adam", name: "Adam", language: "en-us", gender: "M"),
        Voice(id: "am_echo", name: "Echo", language: "en-us", gender: "M"),
        Voice(id: "am_eric", name: "Eric", language: "en-us", gender: "M"),
        Voice(id: "am_fenrir", name: "Fenrir", language: "en-us", gender: "M"),
        Voice(id: "am_liam", name: "Liam", language: "en-us", gender: "M"),
        Voice(id: "am_michael", name: "Michael", language: "en-us", gender: "M"),
        Voice(id: "am_onyx", name: "Onyx", language: "en-us", gender: "M"),
        Voice(id: "am_puck", name: "Puck", language: "en-us", gender: "M"),
        // British English
        Voice(id: "bf_alice", name: "Alice", language: "en-gb", gender: "F"),
        Voice(id: "bf_emma", name: "Emma", language: "en-gb", gender: "F"),
        Voice(id: "bf_isabella", name: "Isabella", language: "en-gb", gender: "F"),
        Voice(id: "bf_lily", name: "Lily", language: "en-gb", gender: "F"),
        Voice(id: "bm_daniel", name: "Daniel", language: "en-gb", gender: "M"),
        Voice(id: "bm_fable", name: "Fable", language: "en-gb", gender: "M"),
        Voice(id: "bm_george", name: "George", language: "en-gb", gender: "M"),
        Voice(id: "bm_lewis", name: "Lewis", language: "en-gb", gender: "M"),
        // Chinese
        Voice(id: "zf_xiaobei", name: "小北", language: "zh", gender: "F"),
        Voice(id: "zf_xiaoni", name: "小妮", language: "zh", gender: "F"),
        Voice(id: "zf_xiaoxiao", name: "小晓", language: "zh", gender: "F"),
        Voice(id: "zf_xiaoyi", name: "小艺", language: "zh", gender: "F"),
        Voice(id: "zm_yunjian", name: "云间", language: "zh", gender: "M"),
        Voice(id: "zm_yunxi", name: "云希", language: "zh", gender: "M"),
        Voice(id: "zm_yunxia", name: "云夏", language: "zh", gender: "M"),
        Voice(id: "zm_yunyang", name: "云扬", language: "zh", gender: "M"),
        // Japanese
        Voice(id: "jf_alpha", name: "Alpha", language: "ja", gender: "F"),
        Voice(id: "jf_gongitsune", name: "Gongitsune", language: "ja", gender: "F"),
        Voice(id: "jf_nezumi", name: "Nezumi", language: "ja", gender: "F"),
        Voice(id: "jf_tebukuro", name: "Tebukuro", language: "ja", gender: "F"),
        Voice(id: "jm_kumo", name: "Kumo", language: "ja", gender: "M"),
        // French
        Voice(id: "ff_siwis", name: "Siwis", language: "fr", gender: "F"),
        // Spanish
        Voice(id: "ef_dora", name: "Dora", language: "es", gender: "F"),
        Voice(id: "em_alex", name: "Alex", language: "es", gender: "M"),
    ]
}
