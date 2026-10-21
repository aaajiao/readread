import Foundation

/// The subset of UserDefaults the preferences use, so tests can keep them in
/// memory instead of writing a plist.
@MainActor
protocol PreferencesStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: PreferencesStore {}

/// A voice per language (`voice_zh`, `voice_en`), a speed per document language
/// (`speed_zh`, `speed_en`), the last document language (to prewarm the right model) and the
/// engine (`engine`). The voices are Kokoro's: Qwen3-TTS has one voice per language and stores none.
@MainActor
struct VoicePreferences {
    /// Languages v0.1.x had and this version dropped.
    static let removedLanguageCodes = ["ja", "es", "fr", "hi", "it", "pt"]
    static let lastLanguageKey = "last_language"

    let defaults: any PreferencesStore

    static func voiceKey(_ language: SpeechLanguage) -> String { "voice_\(language.rawValue)" }
    static func speedKey(_ language: SpeechLanguage) -> String { "speed_\(language.rawValue)" }

    /// Clean up keys written by v0.1.x. Idempotent: old keys are deleted once
    /// migrated, so later runs find nothing to do.
    func migrate() {
        for kind in ["voice", "speed"] {
            // en-us → en (UK vs US is now a property of the voice).
            let old = "\(kind)_en-us"
            let new = "\(kind)_en"
            if let value = defaults.object(forKey: old) {
                if defaults.object(forKey: new) == nil { defaults.set(value, forKey: new) }
                defaults.removeObject(forKey: old)
            }
            defaults.removeObject(forKey: "\(kind)_en-gb")
            for code in Self.removedLanguageCodes {
                defaults.removeObject(forKey: "\(kind)_\(code)")
            }
        }
        // Stored voices that no longer exist (zf_xiaobei…) or belong to another
        // language (a Chinese voice saved under English) fall back to the default.
        for language in SpeechLanguage.allCases {
            let voiceKey = Self.voiceKey(language)
            if let id = defaults.string(forKey: voiceKey), Voice.voice(id: id, language: language) == nil {
                defaults.removeObject(forKey: voiceKey)
            }
            let speedKey = Self.speedKey(language)
            if defaults.object(forKey: speedKey) != nil, storedSpeed(forKey: speedKey) == nil {
                defaults.removeObject(forKey: speedKey)
            }
        }
    }

    func voice(for language: SpeechLanguage) -> Voice {
        if let id = defaults.string(forKey: Self.voiceKey(language)),
           let voice = Voice.voice(id: id, language: language) {
            return voice
        }
        return Voice.defaultVoice(for: language)
    }

    func speed(for language: SpeechLanguage) -> Double {
        storedSpeed(forKey: Self.speedKey(language)) ?? 1.0
    }

    /// The voice is stored under its own language, so it can never land under
    /// the wrong key. Only Kokoro's voices are stored (Qwen's come with the engine).
    func saveVoice(_ voice: Voice) {
        guard Voice.voice(id: voice.id, language: voice.language) != nil else { return }
        defaults.set(voice.id, forKey: Self.voiceKey(voice.language))
    }

    /// The speed for documents in `language`.
    func saveSpeed(_ speed: Double, for language: SpeechLanguage) {
        defaults.set(SynthesisRequest.normalizedSpeed(speed), forKey: Self.speedKey(language))
    }

    var lastLanguage: SpeechLanguage? {
        get { defaults.string(forKey: Self.lastLanguageKey).flatMap(SpeechLanguage.init(rawValue:)) }
        nonmutating set { defaults.set(newValue?.rawValue, forKey: Self.lastLanguageKey) }
    }

    /// The engine chosen in Settings; nil (never chosen, an unknown value, or reset) is Kokoro.
    var engine: EngineKind? {
        get { defaults.string(forKey: EngineKind.defaultsKey).flatMap(EngineKind.init(rawValue:)) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: EngineKind.defaultsKey)
            } else {
                defaults.removeObject(forKey: EngineKind.defaultsKey)
            }
        }
    }

    private func storedSpeed(forKey key: String) -> Double? {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, SynthesisRequest.speedRange.contains(value) else { return nil }
        return SynthesisRequest.normalizedSpeed(value)
    }
}
