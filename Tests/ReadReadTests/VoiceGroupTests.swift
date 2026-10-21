import XCTest

@testable import ReadRead

/// The voice picker's groups (H8): the document language's voices by accent, in catalog order.
@MainActor
final class VoiceGroupTests: XCTestCase {
    func testChineseIsOneGroup() {
        let groups = VoiceGroup.groups(for: .zh)
        XCTAssertEqual(groups.map(\.title), ["中文"])
        XCTAssertEqual(groups.first?.voices.map(\.id), ["zf_001", "zf_032", "zm_009", "zm_055"])
    }

    func testEnglishIsUSThenUK() {
        let groups = VoiceGroup.groups(for: .en)
        XCTAssertEqual(groups.map(\.title), ["English (US)", "English (UK)"])
        XCTAssertEqual(groups.map(\.accent), [.us, .uk])
        XCTAssertEqual(groups.map(\.voices.count), [19, 8])
        XCTAssertTrue(groups[0].voices.allSatisfy { $0.accent == .us })
        XCTAssertTrue(groups[1].voices.allSatisfy { $0.accent == .uk })
    }

    func testEveryVoiceIsInExactlyOneGroupInCatalogOrder() {
        for language in SpeechLanguage.allCases {
            let grouped = VoiceGroup.groups(for: language).flatMap(\.voices)
            XCTAssertEqual(grouped, Voice.voices(for: language))
        }
    }

    /// v0.5.0: Qwen3-TTS's catalog, one voice per language.
    func testQwenHasOneVoicePerLanguage() {
        let zh = VoiceGroup.groups(for: .zh, in: Voice.catalog(for: .qwen))
        XCTAssertEqual(zh.map(\.title), ["中文"])
        XCTAssertEqual(zh.flatMap(\.voices).map(\.id), ["serena"])
        let en = VoiceGroup.groups(for: .en, in: Voice.catalog(for: .qwen))
        XCTAssertEqual(en.map(\.title), ["English (US)"])
        XCTAssertEqual(en.flatMap(\.voices).map(\.id), ["aiden"])
        XCTAssertEqual(Voice.voices(for: .zh, in: Voice.catalog(for: .kokoro)), Voice.voices(for: .zh))
        XCTAssertNil(Voice.voice(id: "serena"), "Kokoro's lookups never find Qwen's voices")
    }

    func testLanguageNamesStayInTheirOwnLanguage() {
        XCTAssertEqual(VoiceAccent.languageName(.zh), "中文")
        XCTAssertEqual(VoiceAccent.languageName(.en), "English")
        XCTAssertEqual(SpeedControl.label(1), "1.0×")
        XCTAssertEqual(SpeedControl.label(0.5), "0.5×")
    }
}
