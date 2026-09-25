import XCTest
@testable import MellowCore

final class LanguageTests: XCTestCase {
    func testSystemFallbackAndExplicitChoice() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "zh-Hans-CN", "en-US"]), .chinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.chinese.resolved(preferredLanguages: ["en-US"]), .chinese)
    }

    func testExistingResultsAndErrorsCanChangeLanguage() {
        let message = Message("已保留 3 项", "Kept 3 items")
        XCTAssertEqual(message.rendered(in: .chinese), "已保留 3 项")
        XCTAssertEqual(message.rendered(in: .english), "Kept 3 items")
        let recovered = Message(error: CleanError.unsafe(message))
        XCTAssertEqual(recovered.prefixed("cache").rendered(in: .english), "cache: Kept 3 items")
    }
}
