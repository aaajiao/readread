import XCTest

@testable import ReadRead

@MainActor
final class VoicePreferencesTests: XCTestCase {
    private var store: MemoryPreferences!
    private var prefs: VoicePreferences!

    override func setUp() async throws {
        store = MemoryPreferences()
        prefs = VoicePreferences(defaults: store)
    }

    // MARK: - Migration from v0.1.x

    func testEnUSKeysMoveToEn() {
        store.set("am_adam", forKey: "voice_en-us")
        store.set(1.3, forKey: "speed_en-us")
        prefs.migrate()
        XCTAssertEqual(store.string(forKey: "voice_en"), "am_adam")
        XCTAssertEqual(store.object(forKey: "speed_en") as? Double, 1.3)
        XCTAssertNil(store.object(forKey: "voice_en-us"))
        XCTAssertNil(store.object(forKey: "speed_en-us"))
        XCTAssertEqual(prefs.voice(for: .en).id, "am_adam")
        XCTAssertEqual(prefs.speed(for: .en), 1.3)
    }

    func testMigrationNeverOverwritesNewKeys() {
        store.set("bf_emma", forKey: "voice_en")
        store.set("am_adam", forKey: "voice_en-us")
        prefs.migrate()
        XCTAssertEqual(store.string(forKey: "voice_en"), "bf_emma")
        XCTAssertNil(store.object(forKey: "voice_en-us"))
    }

    func testDroppedLanguageKeysAreRemoved() {
        for code in ["ja", "es", "fr", "hi", "it", "pt", "en-gb"] {
            store.set("x", forKey: "voice_\(code)")
            store.set(1.0, forKey: "speed_\(code)")
        }
        store.set("zf_032", forKey: "voice_zh")
        prefs.migrate()
        XCTAssertEqual(Set(store.values.keys), ["voice_zh"])
    }

    func testUnknownOrMismatchedVoicesFallBackToTheDefault() {
        store.set("zf_xiaobei", forKey: "voice_zh")  // v0.1 voice, gone in v1.1-zh
        store.set("zf_001", forKey: "voice_en")      // a Chinese voice under English
        prefs.migrate()
        XCTAssertNil(store.object(forKey: "voice_zh"))
        XCTAssertNil(store.object(forKey: "voice_en"))
        XCTAssertEqual(prefs.voice(for: .zh).id, "zf_001")
        XCTAssertEqual(prefs.voice(for: .en).id, "af_heart")
    }

    func testInvalidSpeedsAreDropped() {
        store.set(5.0, forKey: "speed_zh")
        store.set("fast", forKey: "speed_en")
        prefs.migrate()
        XCTAssertNil(store.object(forKey: "speed_zh"))
        XCTAssertNil(store.object(forKey: "speed_en"))
        XCTAssertEqual(prefs.speed(for: .zh), 1.0)
    }

    func testMigrationIsIdempotent() {
        store.set("am_adam", forKey: "voice_en-us")
        store.set("zf_032", forKey: "voice_zh")
        prefs.migrate()
        let once = store.values.mapValues { "\($0)" }
        prefs.migrate()
        XCTAssertEqual(store.values.mapValues { "\($0)" }, once)
    }

    // MARK: - Reading and saving

    func testNothingStoredGivesDefaults() {
        XCTAssertEqual(prefs.voice(for: .zh).id, "zf_001")
        XCTAssertEqual(prefs.voice(for: .en).id, "af_heart")
        XCTAssertEqual(prefs.speed(for: .en), 1.0)
        XCTAssertNil(prefs.lastLanguage)
    }

    func testSaveStoresTheVoiceUnderItsOwnLanguage() throws {
        let emma = try XCTUnwrap(Voice.voice(id: "bf_emma"))
        prefs.saveVoice(emma)
        prefs.saveSpeed(1.2000000000000002, for: .en)
        XCTAssertEqual(store.string(forKey: "voice_en"), "bf_emma")
        XCTAssertEqual(store.object(forKey: "speed_en") as? Double, 1.2)

        let zh = try XCTUnwrap(Voice.voice(id: "zm_009"))
        prefs.saveVoice(zh)
        XCTAssertEqual(store.string(forKey: "voice_zh"), "zm_009")
        XCTAssertEqual(store.string(forKey: "voice_en"), "bf_emma", "never a Chinese voice under English")
        XCTAssertEqual(prefs.voice(for: .zh), zh)
        XCTAssertEqual(prefs.speed(for: .en), 1.2)
        XCTAssertEqual(prefs.speed(for: .zh), 1.0, "a speed is per document language")
    }

    func testLastLanguageRoundTrips() {
        prefs.lastLanguage = .en
        XCTAssertEqual(store.string(forKey: "last_language"), "en")
        XCTAssertEqual(prefs.lastLanguage, .en)
        store.set("ja", forKey: "last_language")
        XCTAssertNil(prefs.lastLanguage)
    }
}
