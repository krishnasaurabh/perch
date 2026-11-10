import Foundation
import XCTest
@testable import PlannerCore

final class DayKeyValidationTests: XCTestCase {
    private struct Envelope: Decodable {
        let day: DayKey
    }

    func testMalformedStringsReportTypedCorruptionAtTheDayField() throws {
        let invalid = [
            "", "2026-02-29", "2026-04-31", "2026-12-32", "2026-13-01",
            "2026-11-9", "2026/11/09", "+026-11-09", "2026-11-09 ",
            " 2026-11-09", "2026-11-09\n", "2026-11-09\u{0}",
            "٢٠٢٦-١١-٠٩", "2026–11–09"
        ]
        for raw in invalid {
            // A runtime String exercises the failable initializer, not the literal overload.
            XCTAssertNil(DayKey(raw), raw)
            let data = try JSONEncoder().encode(["day": raw])
            XCTAssertThrowsError(try JSONDecoder().decode(Envelope.self, from: data), raw) { error in
                guard case DecodingError.dataCorrupted(let context) = error else {
                    return XCTFail("Expected typed data corruption for \(raw), got \(error)")
                }
                XCTAssertEqual(context.codingPath.map(\.stringValue), ["day"])
            }
        }
    }

    func testEveryTaskDayFieldRetainsItsCorruptionPath() throws {
        for key in ["day", "deadline", "carriedFrom", "repeatAnchor"] {
            let data = Data("""
                {"id":"00000000-0000-0000-0000-000000000001",
                 "title":"Synthetic date validation", "createdAt":"2026-11-09T12:00:00Z",
                 "\(key)":"2026-02-30"}
                """.utf8)
            XCTAssertThrowsError(try PlannerFile.decoder.decode(PlanTask.self, from: data), key) { error in
                guard case DecodingError.dataCorrupted(let context) = error else {
                    return XCTFail("Expected typed data corruption at \(key), got \(error)")
                }
                XCTAssertEqual(context.codingPath.map(\.stringValue), [key])
            }
        }
    }

    func testDayKeyUsesGregorianDatesForEveryFoundationCalendar() throws {
        let identifiers: [Calendar.Identifier] = [
            .gregorian, .buddhist, .chinese, .coptic, .ethiopicAmeteMihret,
            .ethiopicAmeteAlem, .hebrew, .iso8601, .indian, .islamic,
            .islamicCivil, .japanese, .persian, .republicOfChina,
            .islamicTabular, .islamicUmmAlQura
        ]
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-02-29T12:00:00Z"))
        for identifier in identifiers {
            for locale in ["ar_EG", "th_TH", "he_IL", "ja_JP"] {
                var calendar = Calendar(identifier: identifier)
                calendar.locale = Locale(identifier: locale)
                calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
                let label = "\(identifier), \(locale)"
                let day = DayKey(instant, calendar: calendar)
                XCTAssertEqual(day.raw, "2024-02-29", label)
                XCTAssertEqual(day.date(calendar: calendar), instant.addingTimeInterval(-12 * 3600), label)
                XCTAssertEqual(day.adding(days: 1, calendar: calendar).raw, "2024-03-01", label)
                XCTAssertEqual(try JSONDecoder().decode(DayKey.self, from: JSONEncoder().encode(day)), day, label)
            }
        }
    }

    func testStorageCalendarKeepsLocalZoneAndWeekSettingsWithoutChangingPresentation() throws {
        var userCalendar = Calendar(identifier: .hebrew)
        userCalendar.locale = Locale(identifier: "he_IL")
        userCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        userCalendar.firstWeekday = 4
        userCalendar.minimumDaysInFirstWeek = 5
        let original = userCalendar
        let storage = userCalendar.plannerStorage
        XCTAssertEqual(storage.identifier, .gregorian)
        XCTAssertEqual(storage.locale?.identifier, "en_US_POSIX")
        XCTAssertEqual(storage.timeZone, original.timeZone)
        XCTAssertEqual(storage.firstWeekday, original.firstWeekday)
        XCTAssertEqual(storage.minimumDaysInFirstWeek, original.minimumDaysInFirstWeek)
        XCTAssertEqual(storage.plannerStorage, storage)
        XCTAssertEqual(userCalendar, original)

        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-09T12:00:00Z"))
        XCTAssertEqual(DayKey(instant, calendar: userCalendar).raw, "2026-11-10")
        XCTAssertEqual(userCalendar, original)
    }

    func testLocalizedMonthNamesRemainIndependentOfStorageLocale() throws {
        let day: DayKey = "2026-11-09"
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var userCalendar = Calendar(identifier: .gregorian)
        userCalendar.locale = Locale(identifier: "fr_FR")
        userCalendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = try XCTUnwrap(userCalendar.locale)
        formatter.calendar = userCalendar
        formatter.timeZone = zone
        formatter.dateFormat = "d MMMM yyyy"

        XCTAssertEqual(formatter.string(from: day.date(calendar: userCalendar)), "9 novembre 2026")
        XCTAssertEqual(day.raw, "2026-11-09")
        XCTAssertEqual(userCalendar.locale?.identifier, "fr_FR")
        XCTAssertEqual(userCalendar.plannerStorage.locale?.identifier, "en_US_POSIX")
    }

    func testNonHourDSTTransitionsPreserveDayArithmetic() throws {
        var calendar = Calendar(identifier: .japanese)
        calendar.locale = Locale(identifier: "ja_JP")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Lord_Howe"))
        for (raw, expectedDuration) in [("2026-04-05", 24.5 * 3600), ("2026-10-04", 23.5 * 3600)] {
            let day = try XCTUnwrap(DayKey(raw))
            let next = day.adding(days: 1, calendar: calendar)
            XCTAssertEqual(next.date(calendar: calendar).timeIntervalSince(day.date(calendar: calendar)), expectedDuration)
            XCTAssertEqual(DayKey(day.start(resetHour: 2, calendar: calendar), resetHour: 2, calendar: calendar), day)
            XCTAssertEqual(next.adding(days: -1, calendar: calendar), day)
        }
        let transition = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-03T15:30:00Z"))
        let spring: DayKey = "2026-10-04"
        XCTAssertEqual(spring.start(resetHour: 2, calendar: calendar), transition)
        XCTAssertEqual(DayKey(transition.addingTimeInterval(-1), resetHour: 2, calendar: calendar).raw, "2026-10-03")
        XCTAssertEqual(DayKey(transition, resetHour: 2, calendar: calendar), spring)
        XCTAssertEqual(spring.reminderDate(hour: 2, minute: 0, resetHour: 2, calendar: calendar), transition)
        XCTAssertEqual(spring.reminderDate(hour: 2, minute: 15, resetHour: 2, calendar: calendar), transition)
    }
}
