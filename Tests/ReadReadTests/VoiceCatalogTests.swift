import XCTest

@testable import ReadRead

final class VoiceCatalogTests: XCTestCase {

    // MARK: - The exact list (contract: ContentView `Voice.all` is the single source)

    func testChineseVoicesInOrder() {
        XCTAssertEqual(Voice.voices(for: .zh).map(\.id), ["zf_001", "zf_032", "zm_009", "zm_055"])
        XCTAssertEqual(Voice.voices(for: .zh).map(\.name), ["女声 001", "女声 032", "男声 009", "男声 055"])
    }

    func testAmericanVoicesInOrder() {
        let us = Voice.all.filter { $0.accent == .us }
        XCTAssertEqual(us.map(\.id), [
            "af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica", "af_kore", "af_nicole", "af_nova",
            "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
            "am_michael", "am_onyx", "am_puck",
        ])
        XCTAssertEqual(us.first?.name, "Heart")
        XCTAssertEqual(us.last?.name, "Puck")
    }

    func testBritishVoicesInOrder() {
        let uk = Voice.all.filter { $0.accent == .uk }
        XCTAssertEqual(uk.map(\.id), [
            "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
        ])
        XCTAssertEqual(uk.map(\.name), ["Alice", "Emma", "Isabella", "Lily", "Daniel", "Fable", "George", "Lewis"])
    }

    func testCountsAndUniqueness() {
        XCTAssertEqual(Voice.all.count, 31)
        XCTAssertEqual(Voice.voices(for: .en).count, 27)
        XCTAssertEqual(Set(Voice.all.map(\.id)).count, Voice.all.count)
    }

    func testDroppedLanguagesAndVoicesAreGone() {
        for id in ["zf_xiaobei", "zf_xiaoni", "zm_yunjian", "jf_alpha", "ef_dora", "ff_siwis", "hf_alpha", "if_sara", "pf_dora"] {
            XCTAssertNil(Voice.voice(id: id), id)
        }
    }

    // MARK: - Labels

    func testAccentLabels() {
        XCTAssertEqual(Voice.voice(id: "zf_001")?.accentLabel, "ZH")
        XCTAssertEqual(Voice.voice(id: "af_heart")?.accentLabel, "EN-US")
        XCTAssertEqual(Voice.voice(id: "bm_george")?.accentLabel, "EN-GB")
        XCTAssertEqual(Voice.voice(id: "bf_emma")?.pickerLabel, "Emma (EN-GB)")
        XCTAssertEqual(Voice.voice(id: "zm_009")?.pickerLabel, "男声 009 (ZH)")
    }

    // MARK: - Routing: the voice decides the pipeline

    func testEveryVoiceAgreesWithTheServersPrefixRouting() {
        for voice in Voice.all {
            let route = Voice.route(forID: voice.id)
            XCTAssertEqual(route?.language, voice.language, voice.id)
            XCTAssertEqual(route?.accent, voice.accent, voice.id)
        }
    }

    func testUnknownPrefixesHaveNoRoute() {
        for id in ["jf_alpha", "ef_dora", "zz_001", "af", ""] {
            XCTAssertNil(Voice.route(forID: id), id)
        }
    }

    func testRequestLanguageComesFromTheVoice() throws {
        let emma = try XCTUnwrap(Voice.voice(id: "bf_emma"))
        let heart = try XCTUnwrap(Voice.voice(id: "af_heart"))
        let zh = try XCTUnwrap(Voice.voice(id: "zf_001"))
        XCTAssertEqual(SynthesisRequest(text: "x", voice: emma, speed: 1).language, .en)
        XCTAssertEqual(SynthesisRequest(text: "x", voice: heart, speed: 1).language, .en)
        XCTAssertEqual(SynthesisRequest(text: "x", voice: zh, speed: 1).language, .zh)
        XCTAssertEqual(SynthesisRequest(text: "x", voice: emma, speed: 1).voiceID, "bf_emma")
    }

    // MARK: - Lookup and defaults

    func testDefaults() {
        XCTAssertEqual(Voice.defaultVoice(for: .zh).id, "zf_001")
        XCTAssertEqual(Voice.defaultVoice(for: .en).id, "af_heart")
    }

    func testLookupByLanguageRejectsOtherLanguages() {
        XCTAssertEqual(Voice.voice(id: "bf_lily", language: .en)?.id, "bf_lily")
        XCTAssertNil(Voice.voice(id: "bf_lily", language: .zh))
        XCTAssertNil(Voice.voice(id: "zf_001", language: .en))
        XCTAssertNil(Voice.voice(id: "nope", language: .en))
    }

    func testVoicesForALanguageAreOnlyThatLanguage() {
        XCTAssertTrue(Voice.voices(for: .zh).allSatisfy { $0.language == .zh && $0.accent == .zh })
        XCTAssertTrue(Voice.voices(for: .en).allSatisfy { $0.language == .en && $0.accent != .zh })
    }

    // MARK: - Against the server's GET /voices (enforced live by --self-test)

    /// /voices as the server lists it: every catalog voice under its language, plus voices the app doesn't offer.
    private var serverVoices: [String: [String]] {
        ["zh": Voice.voices(for: .zh).map(\.id) + ["zf_002", "zm_010"], "en": Voice.voices(for: .en).map(\.id) + ["af_extra"]]
    }

    func testNothingIsMissingWhenTheServerListsEveryCatalogVoice() {
        XCTAssertEqual(Voice.missing(from: serverVoices), [])
    }

    func testAVoiceTheServerDoesNotListIsMissing() {
        var voices = serverVoices
        voices["en"]?.removeAll { $0 == "bm_lewis" }
        voices["zh"]?.removeAll { $0 == "zm_055" }
        XCTAssertEqual(Voice.missing(from: voices).map(\.id), ["zm_055", "bm_lewis"])
    }

    func testAVoiceListedUnderTheOtherLanguageIsMissing() {
        let everythingUnderZh = ["zh": Voice.all.map(\.id), "en": [String]()]
        XCTAssertEqual(Voice.missing(from: everythingUnderZh).map(\.id), Voice.voices(for: .en).map(\.id))
        XCTAssertEqual(Voice.missing(from: [:]).count, Voice.all.count)
    }

    // MARK: - Speed normalization

    func testSpeedIsClampedAndRoundedToTheSliderStep() {
        XCTAssertEqual(SynthesisRequest.normalizedSpeed(2.0000000000000004), 2.0)
        XCTAssertEqual(SynthesisRequest.normalizedSpeed(1.2000000000000002), 1.2)
        XCTAssertEqual(SynthesisRequest.normalizedSpeed(0.3), 0.5)
        XCTAssertEqual(SynthesisRequest.normalizedSpeed(7), 2.0)
        XCTAssertEqual(SynthesisRequest.normalizedSpeed(.nan), 1.0)
        XCTAssertEqual(SynthesisRequest.normalizedSpeed(.infinity), 1.0)
    }

    func testRequestIDsAreShortAndDistinct() {
        let a = SynthesisRequest.makeRequestID()
        let b = SynthesisRequest.makeRequestID()
        XCTAssertTrue(a.hasPrefix("rr-"))
        XCTAssertEqual(a.count, 11)
        XCTAssertNotEqual(a, b)
    }
}
