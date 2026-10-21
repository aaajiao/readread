import Foundation

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

    /// The voice picker's section title: language names stay in their own language.
    var groupTitle: String {
        switch self {
        case .zh: return "中文"
        case .us: return "English (US)"
        case .uk: return "English (UK)"
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

    /// The voices of `language` in `catalog` (Kokoro's by default; `catalog(for:)` gives an engine's).
    static func voices(for language: SpeechLanguage, in catalog: [Voice] = all) -> [Voice] {
        catalog.filter { $0.language == language }
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

/// One section of the voice picker (H8): 中文, English (US) or English (UK).
struct VoiceGroup: Identifiable, Equatable, Sendable {
    let accent: VoiceAccent
    let voices: [Voice]

    var id: VoiceAccent { accent }
    var title: String { accent.groupTitle }

    /// The language's voices in `catalog` by accent, in catalog order (Kokoro's Chinese: one group;
    /// its English: US, then UK; Qwen's: one voice each).
    static func groups(for language: SpeechLanguage, in catalog: [Voice] = Voice.all) -> [VoiceGroup] {
        let voices = Voice.voices(for: language, in: catalog)
        var accents: [VoiceAccent] = []
        for voice in voices where !accents.contains(voice.accent) { accents.append(voice.accent) }
        return accents.map { accent in VoiceGroup(accent: accent, voices: voices.filter { $0.accent == accent }) }
    }
}
