import PlannerTestSupport
@testable import PlannerCore
import XCTest

final class TaskParserLanguageTests: XCTestCase {
    func testSupportedLanguagesAreExplicitAndPseudolocalizationUsesEnglishGrammar() {
        XCTAssertEqual(TaskParserLanguage.allCases, [.english])
        XCTAssertEqual(TaskParserLanguage(languageCode: "en"), .english)
        XCTAssertEqual(TaskParserLanguage(languageCode: "en-US"), .english)
        XCTAssertEqual(TaskParserLanguage(languageCode: "EN_gb"), .english)
        XCTAssertEqual(TaskParserLanguage(languageCode: "zz"), .english)
        XCTAssertNil(TaskParserLanguage(languageCode: "fr"))
        XCTAssertNil(TaskParserLanguage(languageCode: "ar-SA"))
        XCTAssertNil(TaskParserLanguage(languageCode: ""))
    }

    func testUnsupportedLanguageThrowsInsteadOfParsingWithEnglishRules() throws {
        let capture = TaskCapture(now: Fixture.now, calendar: Fixture.calendar)
        XCTAssertThrowsError(try capture.parse("Repair tomorrow at 5pm", languageCode: "fr")) { error in
            XCTAssertEqual(error as? UnsupportedTaskParserLanguage, UnsupportedTaskParserLanguage(languageCode: "fr"))
        }
        let parsed = try capture.parse("Repair tomorrow at 5pm", languageCode: "zz")
        XCTAssertEqual(parsed.title, "Repair")
        XCTAssertEqual(parsed.day, "2026-11-10")
    }

    func testPresentationCalendarDoesNotChangeGregorianStorageOrParserDates() throws {
        var calendar = Calendar(identifier: .islamicCivil)
        calendar.timeZone = Fixture.calendar.timeZone
        calendar.locale = Locale(identifier: "ar-SA")
        let capture = TaskCapture(now: Fixture.now, calendar: calendar)
        let parsed = capture.parse("Plan on november 20", language: .english)
        XCTAssertEqual(parsed.day, "2026-11-20")
        XCTAssertEqual(
            parsed.day?.date(calendar: calendar).timeIntervalSince1970,
            DayKey("2026-11-20").date(calendar: calendar).timeIntervalSince1970)
    }
}
