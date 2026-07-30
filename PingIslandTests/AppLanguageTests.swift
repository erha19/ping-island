import XCTest
@testable import NotchCode

final class AppLanguageTests: XCTestCase {
    func testSystemLanguagePrefersSimplifiedChineseForChineseLocales() {
        XCTAssertEqual(
            AppLanguage.system.resolvedLanguageCode(preferredLanguages: ["zh-Hans-CN"]),
            "zh-Hans"
        )
        XCTAssertEqual(
            AppLanguage.system.resolvedLanguageCode(preferredLanguages: ["zh-TW"]),
            "zh-Hans"
        )
    }

    func testSystemLanguageFallsBackToEnglishForNonChineseLocales() {
        XCTAssertEqual(
            AppLanguage.system.resolvedLanguageCode(preferredLanguages: ["en-US"]),
            "en"
        )
        XCTAssertEqual(
            AppLanguage.system.resolvedLanguageCode(preferredLanguages: ["ja-JP"]),
            "en"
        )
    }

    func testExplicitLanguageSelectionsStayStable() {
        XCTAssertEqual(AppLanguage.simplifiedChinese.resolvedLanguageCode(), "zh-Hans")
        XCTAssertEqual(AppLanguage.english.resolvedLanguageCode(), "en")
    }
}
