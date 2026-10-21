import XCTest

@testable import ReadRead

/// Script census per unit (R3-09): Han vs Latin, other scripts unsupported.
final class LanguageDetectorTests: XCTestCase {
    func testCensus() {
        let census = LanguageDetector.census("中文 ABC café 123 かな 한국 Привет")
        XCTAssertEqual(census.han, 2)
        XCTAssertEqual(census.latin, 7)
        XCTAssertEqual(census.digits, 3)
        XCTAssertEqual(census.kana, 2)
        XCTAssertEqual(census.other, 8)
        XCTAssertEqual(LanguageDetector.census("×÷・ー").letters, 0, "signs and shared punctuation are no letters")
        XCTAssertEqual(LanguageDetector.census("〇").han, 1)
        XCTAssertEqual(LanguageDetector.census("ポケモンの").hiragana, 1)
        XCTAssertTrue(LanguageDetector.hasCJKLetters("Lu Xun 鲁迅"))
        XCTAssertTrue(LanguageDetector.hasCJKLetters("The word ポケモン"))
        XCTAssertFalse(LanguageDetector.hasCJKLetters("，。・ー「」 123 abc"), "CJK punctuation is no letter")
    }

    /// Katakana in a Chinese sentence is a loanword: the sentence stays Chinese (the zh
    /// pipeline drops the kana). Hiragana, or kana outnumbering Han, is Japanese.
    func testKatakanaLoanwordsInChineseStayChinese() {
        XCTAssertEqual(LanguageDetector.verdict("我喜欢玩ポケモン游戏，特别是皮卡丘。"), .zh)
        XCTAssertEqual(LanguageDetector.verdict("今天我们去看了ガンダム展览，人很多。"), .zh)
        XCTAssertEqual(LanguageDetector.verdict("这家店叫ラーメン屋，很好吃。"), .zh)
        XCTAssertEqual(LanguageDetector.verdict("我の世界"), .zh, "two or fewer kana never decide")
        XCTAssertEqual(LanguageDetector.verdict("ポケモンの世界"), .unsupported, "kana outnumber Han")
        XCTAssertEqual(LanguageDetector.verdict("東京で寿司を食べました。"), .unsupported, "hiragana")
    }

    func testChineseAndEnglish() {
        XCTAssertEqual(LanguageDetector.verdict("今天天气很好。"), .zh)
        XCTAssertEqual(LanguageDetector.verdict("The weather is nice today."), .en)
        XCTAssertEqual(LanguageDetector.verdict("我们用 Swift 写了一个朗读应用。"), .zh,
                       "the zh pipeline reads embedded English")
        XCTAssertEqual(LanguageDetector.verdict("我们用 Swift 和 Python 写 ReadRead 应用。"), .mixed,
                       "7 Han of 26 letters: under the share, read in the document's language")
        XCTAssertEqual(LanguageDetector.verdict("語音合成是將人類語音用人工的方式所產生。"), .zh, "Traditional Chinese")
    }

    func testTheHanShareThreshold() {
        // 3 Han of 10 letters: exactly 0.3 → zh; 2 of 10 → mixed.
        XCTAssertEqual(LanguageDetector.verdict("中文字abcdefg"), .zh)
        XCTAssertEqual(LanguageDetector.verdict("中文abcdefgh"), .mixed)
        XCTAssertEqual(LanguageDetector.verdict("This sentence mentions 北京 once."), .mixed)
    }

    func testDigitsAndNothing() {
        XCTAssertEqual(LanguageDetector.verdict("1999 — 2024"), .digitsOnly)
        XCTAssertEqual(LanguageDetector.verdict("……！？"), .unsupported)
        XCTAssertEqual(LanguageDetector.verdict(""), .unsupported)
    }

    func testOtherScriptsAreUnsupported() {
        XCTAssertEqual(LanguageDetector.verdict("これは日本語の文章です。"), .unsupported, "kana")
        XCTAssertEqual(LanguageDetector.verdict("吾輩は猫である。名前はまだ無い。"), .unsupported, "kanji with kana")
        XCTAssertEqual(LanguageDetector.verdict("안녕하세요, 반갑습니다."), .unsupported)
        XCTAssertEqual(LanguageDetector.verdict("Привет, как дела?"), .unsupported)
        XCTAssertEqual(LanguageDetector.verdict("مرحبا بالعالم"), .unsupported)
        XCTAssertEqual(LanguageDetector.verdict("สวัสดีครับ"), .unsupported)
        XCTAssertEqual(LanguageDetector.verdict("The word Привет means hello in Russian."), .en,
                       "a foreign word in an English sentence")
    }

    func testTheDocumentLanguageIsTheCharacterWeightedMajority() {
        XCTAssertEqual(LanguageDetector.documentLanguage([(.zh, 30), (.en, 20), (.en, 15)]), .en)
        XCTAssertEqual(LanguageDetector.documentLanguage([(.zh, 30), (.en, 29)]), .zh)
        XCTAssertEqual(LanguageDetector.documentLanguage([(.zh, 10), (.en, 10)]), .zh, "a tie is Chinese")
        XCTAssertEqual(LanguageDetector.documentLanguage([]), .zh)
    }

    func testUnitLanguages() {
        XCTAssertEqual(LanguageDetector.language(of: .zh, document: .en), .zh)
        XCTAssertEqual(LanguageDetector.language(of: .en, document: .zh), .en)
        XCTAssertEqual(LanguageDetector.language(of: .mixed, document: .en), .en)
        XCTAssertEqual(LanguageDetector.language(of: .digitsOnly, document: .zh), .zh)
        XCTAssertNil(LanguageDetector.language(of: .unsupported, document: .zh))
    }
}
