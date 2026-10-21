import SwiftUI

/// The voice of one language: a button with the voice's name that opens the grouped list
/// (中文 / English (US) / English (UK)) with ▶ on every row (H8, R4-07).
struct VoicePickerButton: View {
    @Bindable var appState: AppState
    let language: SpeechLanguage
    /// In the Settings window (a preview's failure is shown there).
    var inSettings = false
    @State private var showsList = false

    var body: some View {
        let voice = appState.voice(for: language)
        Button {
            showsList.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: voice.pickerLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(appState.usingSystemVoice)
        .help(Text("Choose the voice for \(VoiceAccent.languageName(language)) text"))
        .accessibilityLabel(Text("Voice for \(VoiceAccent.languageName(language))"))
        .accessibilityValue(Text(verbatim: voice.pickerLabel))
        .popover(isPresented: $showsList, arrowEdge: .bottom) {
            VoiceListView(appState: appState, language: language, inSettings: inSettings) {
                showsList = false
            }
        }
    }
}

/// ▶ / ■ for one voice: its sample through the current engine (the document pauses meanwhile).
struct VoicePreviewButton: View {
    @Bindable var appState: AppState
    let voice: Voice
    /// In the Settings window (a failure is shown there, not in the panel's banner).
    var inSettings = false

    var body: some View {
        let phase = appState.previewer.phase
        let active = phase.voiceID == voice.id
        Button {
            appState.previewVoice(voice, inSettings: inSettings)
        } label: {
            ZStack {
                if case .loading(let id) = phase, id == voice.id {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: active ? "stop.fill" : "play.fill")
                        .font(.caption)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(appState.usingSystemVoice)
        .help(active ? Text("Stop the preview") : Text("Hear \(voice.name)"))
        .accessibilityLabel(active ? Text("Stop the preview") : Text("Preview \(voice.name)"))
    }
}

/// Every voice of `language` by accent, with ▶ on each row; a click on a row chooses it.
struct VoiceListView: View {
    @Bindable var appState: AppState
    let language: SpeechLanguage
    var inSettings = false
    var onChoose: () -> Void = {}

    var body: some View {
        let selected = appState.voice(for: language)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(VoiceGroup.groups(for: language)) { group in
                        Section {
                            ForEach(group.voices) { voice in
                                row(voice, selected: voice.id == selected.id)
                                    .id(voice.id)
                            }
                        } header: {
                            Text(verbatim: group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 3)
                                .background(.regularMaterial)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .onAppear { proxy.scrollTo(selected.id, anchor: .center) }
        }
        .frame(width: 250, height: language == .zh ? 150 : 320)
    }

    private func row(_ voice: Voice, selected: Bool) -> some View {
        HStack(spacing: 6) {
            VoicePreviewButton(appState: appState, voice: voice, inSettings: inSettings)
            Button {
                appState.selectVoice(voice)
                onChoose()
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: voice.name)
                    Text(verbatim: voice.accentLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: voice.pickerLabel))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

/// The speed for documents in `language`: a slider (reading mode, Settings) or − 1.0× + (input
/// mode, where two of them share the panel's width).
struct SpeedControl: View {
    enum Style {
        case slider
        case stepper
    }

    @Bindable var appState: AppState
    let language: SpeechLanguage
    var style: Style = .slider

    var body: some View {
        let speed = appState.speed(for: language)
        // Steps of 0.1 by rounding, not `step:` (which draws 16 tick marks under the slider).
        let binding = Binding(get: { appState.speed(for: language) },
                              set: { appState.setSpeed(Self.rounded($0), for: language) })
        switch style {
        case .slider:
            HStack(spacing: 8) {
                Slider(value: binding, in: SynthesisRequest.speedRange) {
                    Text("Speed")
                }
                .labelsHidden()
                .accessibilityLabel(Text("Speed for \(VoiceAccent.languageName(language))"))
                .accessibilityValue(Text(Self.label(speed)))
                Text(Self.label(speed))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
        case .stepper:
            Stepper(value: binding, in: SynthesisRequest.speedRange, step: 0.1) {
                Text(Self.label(speed))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
            .accessibilityLabel(Text("Speed for \(VoiceAccent.languageName(language))"))
            .accessibilityValue(Text(Self.label(speed)))
            .help(Text("Speed for \(VoiceAccent.languageName(language)) text"))
        }
    }

    /// "1.0×" (locale independent: the speed steps by 0.1).
    static func label(_ speed: Double) -> String {
        String(format: "%.1f×", speed)
    }

    /// To the nearest 0.1, within the range.
    static func rounded(_ speed: Double) -> Double {
        let range = SynthesisRequest.speedRange
        return min(range.upperBound, max(range.lowerBound, (speed * 10).rounded() / 10))
    }
}

/// Input mode and Settings › Voices: the voice and the speed of each language, so what a text
/// will be read with is in view before it loads (R4-07).
struct VoiceSettingsGrid: View {
    @Bindable var appState: AppState
    var compact = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(SpeechLanguage.allCases, id: \.self) { language in
                GridRow {
                    Text(VoiceAccent.voiceLabel(language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    VoicePickerButton(appState: appState, language: language)
                    VoicePreviewButton(appState: appState, voice: appState.voice(for: language))
                    SpeedControl(appState: appState, language: language, style: compact ? .stepper : .slider)
                        .frame(width: compact ? nil : 150)
                }
            }
        }
    }
}

extension VoiceAccent {
    /// The language's name in its own language (never translated).
    static func languageName(_ language: SpeechLanguage) -> String {
        switch language {
        case .zh: "中文"
        case .en: "English"
        }
    }

    /// "中文 voice" / "English voice".
    static func voiceLabel(_ language: SpeechLanguage) -> LocalizedStringKey {
        switch language {
        case .zh: LocalizedStringKey("中文 voice")
        case .en: LocalizedStringKey("English voice")
        }
    }
}
