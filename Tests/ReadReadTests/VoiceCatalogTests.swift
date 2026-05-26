import XCTest

@testable import ReadRead

final class VoiceCatalogTests: XCTestCase {

    // MARK: - Basic catalog invariants

    func testAllIsNonEmpty() {
        XCTAssertFalse(Voice.all.isEmpty, "Voice.all must not be empty")
    }

    func testAllIDsAreUnique() {
        let ids = Voice.all.map(\.id)
        let unique = Set(ids)
        XCTAssertEqual(ids.count, unique.count, "every voice id must be unique")
    }

    func testAllGendersAreValid() {
        let validGenders: Set<String> = ["F", "M"]
        for voice in Voice.all {
            XCTAssertTrue(
                validGenders.contains(voice.gender),
                "voice '\(voice.id)' has invalid gender '\(voice.gender)'"
            )
        }
    }

    func testAllLanguagesAreKnown() {
        let knownLanguages: Set<String> = ["en-us", "en-gb", "zh", "ja", "fr", "es"]
        for voice in Voice.all {
            XCTAssertTrue(
                knownLanguages.contains(voice.language),
                "voice '\(voice.id)' has unknown language '\(voice.language)'"
            )
        }
    }

    // MARK: - languageLabel mapping

    func testLanguageLabelEnUs() {
        let voice = Voice(id: "af_heart", name: "Heart", language: "en-us", gender: "F")
        XCTAssertEqual(voice.languageLabel, "EN")
    }

    func testLanguageLabelEnGb() {
        let voice = Voice(id: "bf_alice", name: "Alice", language: "en-gb", gender: "F")
        XCTAssertEqual(voice.languageLabel, "EN-GB")
    }

    func testLanguageLabelZh() {
        let voice = Voice(id: "zf_xiaobei", name: "小北", language: "zh", gender: "F")
        XCTAssertEqual(voice.languageLabel, "ZH")
    }

    func testLanguageLabelJa() {
        let voice = Voice(id: "jf_alpha", name: "Alpha", language: "ja", gender: "F")
        XCTAssertEqual(voice.languageLabel, "JA")
    }

    func testLanguageLabelFr() {
        let voice = Voice(id: "ff_siwis", name: "Siwis", language: "fr", gender: "F")
        XCTAssertEqual(voice.languageLabel, "FR")
    }

    func testLanguageLabelEs() {
        let voice = Voice(id: "ef_dora", name: "Dora", language: "es", gender: "F")
        XCTAssertEqual(voice.languageLabel, "ES")
    }

    // MARK: - ID prefix encodes language and gender consistently

    func testIDPrefixConvention() {
        // Maps first-char prefix pair → expected language; second char → expected gender.
        let languageByPrefix: [Character: String] = [
            "a": "en-us",
            "b": "en-gb",
            "z": "zh",
            "j": "ja",
            "f": "fr",
            "e": "es",
        ]
        let genderBySecondChar: [Character: String] = [
            "f": "F",
            "m": "M",
        ]

        for voice in Voice.all {
            let id = voice.id
            guard id.count >= 2 else {
                XCTFail("voice id '\(id)' is too short to encode prefix convention")
                continue
            }

            let firstChar = id[id.startIndex]
            let secondIndex = id.index(after: id.startIndex)
            let secondChar = id[secondIndex]

            if let expectedLang = languageByPrefix[firstChar] {
                XCTAssertEqual(
                    voice.language, expectedLang,
                    "voice '\(id)': first char '\(firstChar)' should encode language '\(expectedLang)' but got '\(voice.language)'"
                )
            } else {
                XCTFail("voice '\(id)' has unrecognised first-char prefix '\(firstChar)'")
            }

            if let expectedGender = genderBySecondChar[secondChar] {
                XCTAssertEqual(
                    voice.gender, expectedGender,
                    "voice '\(id)': second char '\(secondChar)' should encode gender '\(expectedGender)' but got '\(voice.gender)'"
                )
            } else {
                XCTFail("voice '\(id)' has unrecognised second-char gender char '\(secondChar)'")
            }
        }
    }

    // MARK: - Default voice IDs exist in Voice.all

    func testDefaultVoiceAfHeartExists() {
        XCTAssertTrue(Voice.all.contains { $0.id == "af_heart" })
    }

    func testDefaultVoiceZfXiaobeiExists() {
        XCTAssertTrue(Voice.all.contains { $0.id == "zf_xiaobei" })
    }

    func testDefaultVoiceJfAlphaExists() {
        XCTAssertTrue(Voice.all.contains { $0.id == "jf_alpha" })
    }

    func testDefaultVoiceEfDoraExists() {
        XCTAssertTrue(Voice.all.contains { $0.id == "ef_dora" })
    }

    func testDefaultVoiceFfSiwisExists() {
        XCTAssertTrue(Voice.all.contains { $0.id == "ff_siwis" })
    }
}
