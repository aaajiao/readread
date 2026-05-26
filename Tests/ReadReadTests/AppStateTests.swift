import XCTest

@testable import ReadRead

@MainActor
final class AppStateTests: XCTestCase {

    // MARK: - splitIntoChunks

    func testSplitSkipsEmptyAndWhitespaceParagraphs() {
        let state = AppState()
        // Double-newline paragraphs that are blank/whitespace only
        let text = "Hello\n\n   \n\nWorld"
        let chunks = state.splitIntoChunks(text, maxLength: 200)
        XCTAssertEqual(chunks, ["Hello\n\nWorld"])
    }

    func testSplitMergesShortParagraphsUnderMaxLength() {
        let state = AppState()
        // "abc" (3) + "def" (3) = 6 < 20 — should merge
        let text = "abc\n\ndef"
        let chunks = state.splitIntoChunks(text, maxLength: 20)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], "abc\n\ndef")
    }

    func testSplitStartsNewChunkWhenAddingExceedsMaxLength() {
        let state = AppState()
        // "abcdefghij" (10) + "klmnopqrst" (10) = 20 > 15, and current is non-empty
        let text = "abcdefghij\n\nklmnopqrst"
        let chunks = state.splitIntoChunks(text, maxLength: 15)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0], "abcdefghij")
        XCTAssertEqual(chunks[1], "klmnopqrst")
    }

    func testSplitThreeParagraphsPartialMerge() {
        let state = AppState()
        // maxLength=20. "aaa"(3) + "bbb"(3) merge into "aaa\n\nbbb" — note current.count
        // now counts the "\n\n" separator too, so current is 8 chars. Adding
        // "cccccccccccccc"(14): 8 + 14 = 22 > 20 → new chunk. Result: 2 chunks.
        let text = "aaa\n\nbbb\n\ncccccccccccccc"
        let chunks = state.splitIntoChunks(text, maxLength: 20)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0], "aaa\n\nbbb")
        XCTAssertEqual(chunks[1], "cccccccccccccc")
    }

    func testSplitFallbackReturnsOriginalTextWhenResultWouldBeEmpty() {
        let state = AppState()
        // All paragraphs are whitespace-only — result would be empty, fallback to [text]
        let text = "   \n\n\t\n\n  "
        let chunks = state.splitIntoChunks(text, maxLength: 200)
        XCTAssertEqual(chunks, [text])
    }

    func testSplitPlainStringWithNoDoubleNewline() {
        let state = AppState()
        let text = "Just a plain sentence with no double newline."
        let chunks = state.splitIntoChunks(text, maxLength: 200)
        XCTAssertEqual(chunks, [text])
    }

    func testSplitBoundaryExactlyAtMaxLength() {
        let state = AppState()
        // "aaaa"(4) + "bbbb"(4) combined = 8+4 ("aaaa\n\n" is 6 chars in current, plus 4 = 10)
        // Actually current.count + trimmed.count: after first para, current="aaaa"(4)
        // second para: 4+4=8 ≤ 10 → merge → current="aaaa\n\nbbbb"
        // third para: 10+4=14 > 10 and current non-empty → new chunk
        let text = "aaaa\n\nbbbb\n\ncccc"
        let chunks = state.splitIntoChunks(text, maxLength: 10)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0], "aaaa\n\nbbbb")
        XCTAssertEqual(chunks[1], "cccc")
    }

    // MARK: - detectLanguage

    func testDetectLanguageEnglish() {
        let state = AppState()
        let english = """
            The quick brown fox jumps over the lazy dog. \
            This is a clearly English paragraph with multiple sentences. \
            Language detection should have no trouble identifying this as English.
            """
        XCTAssertEqual(state.detectLanguage(english), "en-us")
    }

    func testDetectLanguageSimplifiedChinese() {
        let state = AppState()
        let chinese = """
            这是一段中文文本，用于测试语言检测功能。中文是世界上使用人数最多的语言之一。\
            自然语言处理技术可以识别不同语言的文字。这段话应该被识别为中文。
            """
        XCTAssertEqual(state.detectLanguage(chinese), "zh")
    }

    func testDetectLanguageJapanese() {
        let state = AppState()
        let japanese = """
            これは日本語のテキストです。自然言語処理のテストに使用されています。\
            日本語はひらがな、カタカナ、漢字を組み合わせた言語です。\
            この文章は日本語として認識されるはずです。
            """
        XCTAssertEqual(state.detectLanguage(japanese), "ja")
    }

    func testDetectLanguageSpanish() {
        let state = AppState()
        let spanish = """
            Este es un texto en español para probar la detección de idioma. \
            El español es una lengua romance hablada en muchos países del mundo. \
            La detección automática de idiomas debe reconocer este texto como español.
            """
        XCTAssertEqual(state.detectLanguage(spanish), "es")
    }

    func testDetectLanguageFrench() {
        let state = AppState()
        let french = """
            Ceci est un texte en français pour tester la détection de la langue. \
            Le français est une langue romane parlée dans de nombreux pays. \
            La détection automatique des langues devrait reconnaître ce texte comme français.
            """
        XCTAssertEqual(state.detectLanguage(french), "fr")
    }

    func testDetectLanguageEmptyStringReturnsDefault() {
        let state = AppState()
        XCTAssertEqual(state.detectLanguage(""), "en-us")
    }

    // MARK: - mapLanguageCode

    func testMapLanguageCodeSimplifiedChinese() {
        let state = AppState()
        XCTAssertEqual(state.mapLanguageCode("zh-Hans"), "zh")
    }

    func testMapLanguageCodeJapanese() {
        let state = AppState()
        XCTAssertEqual(state.mapLanguageCode("ja"), "ja")
    }

    func testMapLanguageCodeSpanish() {
        let state = AppState()
        XCTAssertEqual(state.mapLanguageCode("es-ES"), "es")
    }

    func testMapLanguageCodeFrench() {
        let state = AppState()
        XCTAssertEqual(state.mapLanguageCode("fr"), "fr")
    }

    func testMapLanguageCodeHindi() {
        let state = AppState()
        XCTAssertEqual(state.mapLanguageCode("hi"), "hi")
    }

    func testMapLanguageCodeItalian() {
        let state = AppState()
        XCTAssertEqual(state.mapLanguageCode("it"), "it")
    }

    func testMapLanguageCodePortuguese() {
        let state = AppState()
        XCTAssertEqual(state.mapLanguageCode("pt"), "pt")
    }

    func testMapLanguageCodeEnglishGB() {
        let state = AppState()
        XCTAssertEqual(state.mapLanguageCode("en-GB"), "en-us")
    }

    func testMapLanguageCodeUnknownDefaultsToEnglish() {
        let state = AppState()
        XCTAssertEqual(state.mapLanguageCode("de"), "en-us")
    }

    // MARK: - defaultVoice

    func testDefaultVoiceChinese() {
        let state = AppState()
        XCTAssertEqual(state.defaultVoice(for: "zh"), "zf_xiaobei")
    }

    func testDefaultVoiceJapanese() {
        let state = AppState()
        XCTAssertEqual(state.defaultVoice(for: "ja"), "jf_alpha")
    }

    func testDefaultVoiceSpanish() {
        let state = AppState()
        XCTAssertEqual(state.defaultVoice(for: "es"), "ef_dora")
    }

    func testDefaultVoiceFrench() {
        let state = AppState()
        XCTAssertEqual(state.defaultVoice(for: "fr"), "ff_siwis")
    }

    func testDefaultVoiceUnknownFallsBackToAfHeart() {
        let state = AppState()
        XCTAssertEqual(state.defaultVoice(for: "en-us"), "af_heart")
    }

    // MARK: - Language Preferences Persistence

    private let testLangKey = "xx-test"
    private let voiceKey = "voice_xx-test"
    private let speedKey = "speed_xx-test"

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: voiceKey)
        UserDefaults.standard.removeObject(forKey: speedKey)
    }

    func testSaveLanguagePreferencesPersistsValues() {
        let state = AppState()
        state.selectedLanguage = testLangKey
        state.selectedVoice = "zf_xiaobei"
        state.speed = 1.5
        state.currentText = "x"   // hasContent must be true

        state.saveLanguagePreferences()

        XCTAssertEqual(UserDefaults.standard.string(forKey: voiceKey), "zf_xiaobei")
        XCTAssertEqual(UserDefaults.standard.double(forKey: speedKey), 1.5, accuracy: 0.001)
    }

    func testSaveLanguagePreferencesIsNoOpWhenCurrentTextEmpty() {
        let state = AppState()
        state.selectedLanguage = testLangKey
        state.selectedVoice = "zf_xiaobei"
        state.speed = 1.5
        // currentText is "" by default — hasContent == false

        state.saveLanguagePreferences()

        XCTAssertNil(UserDefaults.standard.string(forKey: voiceKey),
                     "saveLanguagePreferences should not write when currentText is empty")
    }

    func testApplyLanguagePreferencesRestoresSavedValues() {
        // Persist values for the test language
        UserDefaults.standard.set("jf_alpha", forKey: voiceKey)
        UserDefaults.standard.set(0.8, forKey: speedKey)

        let state = AppState()
        state.applyLanguagePreferences(for: testLangKey)

        XCTAssertEqual(state.selectedVoice, "jf_alpha")
        XCTAssertEqual(state.speed, 0.8, accuracy: 0.001)
    }

    func testApplyLanguagePreferencesFallsBackToDefaultVoiceWhenNoSavedValue() {
        // Ensure no saved prefs for "fr" under our clean test conditions.
        // We use a fresh AppState and check against the expected default for French.
        let state = AppState()
        // Remove any existing fr prefs to ensure a clean slate
        UserDefaults.standard.removeObject(forKey: "voice_fr")
        UserDefaults.standard.removeObject(forKey: "speed_fr")

        state.applyLanguagePreferences(for: "fr")

        XCTAssertEqual(state.selectedVoice, "ff_siwis")
    }

    // MARK: - Computed Properties

    func testProgressIsZeroWhenNoChunks() {
        let state = AppState()
        XCTAssertEqual(state.progress, 0.0, accuracy: 0.001)
    }

    func testProgressReflectsChunkIndex() {
        let state = AppState()
        state.textChunks = ["a", "b", "c", "d"]
        state.currentChunkIndex = 2
        XCTAssertEqual(state.progress, 0.5, accuracy: 0.001)
    }

    func testIsPlayingReflectsPlaybackState() {
        let state = AppState()
        state.playbackState = .playing
        XCTAssertTrue(state.isPlaying)
        XCTAssertFalse(state.isPaused)

        state.playbackState = .paused
        XCTAssertFalse(state.isPlaying)
        XCTAssertTrue(state.isPaused)

        state.playbackState = .idle
        XCTAssertFalse(state.isPlaying)
        XCTAssertFalse(state.isPaused)
    }

    func testHasContentReflectsCurrentText() {
        let state = AppState()
        XCTAssertFalse(state.hasContent)
        state.currentText = "something"
        XCTAssertTrue(state.hasContent)
    }

    // MARK: - Safe State Guards

    func testNextChunkIsNoOpAtLastChunk() {
        let state = AppState()
        state.textChunks = ["a", "b", "c"]
        state.currentChunkIndex = 2   // already at last index (count - 1)

        state.nextChunk()

        // Guard fires: index must be unchanged and no task spawned
        XCTAssertEqual(state.currentChunkIndex, 2)
    }

    func testPreviousChunkIsNoOpAtFirstChunk() {
        let state = AppState()
        state.textChunks = ["a", "b", "c"]
        state.currentChunkIndex = 0

        state.previousChunk()

        XCTAssertEqual(state.currentChunkIndex, 0)
    }

    func testStopSetsIdleAndResetsIndex() {
        let state = AppState()
        state.textChunks = ["a", "b", "c"]
        state.currentChunkIndex = 2
        state.playbackState = .paused

        state.stop()

        XCTAssertEqual(state.playbackState, .idle)
        XCTAssertEqual(state.currentChunkIndex, 0)
    }
}
