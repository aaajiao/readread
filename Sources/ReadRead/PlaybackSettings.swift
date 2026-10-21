import Foundation

/// What the player reads a document with: a voice per language, one speed, and the
/// language choice (auto = every unit in its own detected language).
struct PlaybackSettings: Sendable, Equatable {
    var voices: [SpeechLanguage: Voice]
    var speed: Double
    var languageChoice: LanguageChoice

    init(voices: [SpeechLanguage: Voice] = [:], speed: Double = 1.0, languageChoice: LanguageChoice = .auto) {
        self.voices = voices
        self.speed = SynthesisRequest.normalizedSpeed(speed)
        self.languageChoice = languageChoice
    }

    func voice(for language: SpeechLanguage) -> Voice {
        if let voice = voices[language], voice.language == language { return voice }
        return Voice.defaultVoice(for: language)
    }
}
