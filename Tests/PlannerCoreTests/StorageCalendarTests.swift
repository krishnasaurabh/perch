import Foundation
import XCTest
@testable import PlannerCore

final class StorageCalendarTests: XCTestCase {
    func testDecodedDayKeysRejectInvalidDatesAndShapes() throws {
        for raw in ["2026-02-30", "2026-13-01", "0000-01-01", "2026-1-01", "not-a-date", "2026-01-01x"] {
            let data = try JSONEncoder().encode(raw)
            XCTAssertThrowsError(try JSONDecoder().decode(DayKey.self, from: data), raw)
        }
    }

    func testStorageDateIsGregorianUnderOtherUserCalendars() throws {
        for id: Calendar.Identifier in [.buddhist, .hebrew, .islamic, .japanese, .persian] {
            var userCalendar = Calendar(identifier: id)
            userCalendar.timeZone = Fixture.calendar.timeZone
            userCalendar.locale = Locale(identifier: "th_TH")
            let date = Fixture.date("2026-11-09 15:00")
            let day = DayKey(date, calendar: userCalendar)
            XCTAssertEqual(day.raw, "2026-11-09", "\(id)")
            let knownDay: DayKey = "2026-11-09"
            XCTAssertEqual(knownDay.date(calendar: userCalendar), knownDay.date(calendar: Fixture.calendar), "\(id)")
            XCTAssertEqual(knownDay.adding(days: 1, calendar: userCalendar).raw, "2026-11-10", "\(id)")
            XCTAssertEqual(knownDay.weekday(calendar: userCalendar), 2)
            XCTAssertEqual(userCalendar.plannerStorage.identifier, .gregorian)
            XCTAssertEqual(userCalendar.plannerStorage.locale?.identifier, "en_US_POSIX")
            XCTAssertEqual(userCalendar.plannerStorage.timeZone, userCalendar.timeZone)
        }
    }

    func testResetHourUsesLocalWallTimeAcrossDSTInAnyCalendar() throws {
        let clock = ISO8601DateFormatter()
        for identifier: Calendar.Identifier in [.gregorian, .buddhist, .hebrew, .islamic] {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
            for (instant, expected) in [
                ("2026-03-08T09:59:00Z", "2026-03-07"),
                ("2026-03-08T10:00:00Z", "2026-03-08"),
                ("2026-11-01T08:30:00Z", "2026-10-31"),
                ("2026-11-01T09:30:00Z", "2026-10-31"),
                ("2026-11-01T10:00:00Z", "2026-11-01")
            ] {
                let date = try XCTUnwrap(clock.date(from: instant))
                XCTAssertEqual(DayKey(date, resetHour: 2, calendar: calendar).raw, expected, "\(identifier): \(instant)")
            }
            let spring: DayKey = "2026-03-08"
            let fall: DayKey = "2026-11-01"
            XCTAssertEqual(spring.adding(days: 1, calendar: calendar).date(calendar: calendar).timeIntervalSince(spring.date(calendar: calendar)), 23 * 3600)
            XCTAssertEqual(fall.adding(days: 1, calendar: calendar).date(calendar: calendar).timeIntervalSince(fall.date(calendar: calendar)), 25 * 3600)
            XCTAssertEqual(DayKey(spring.start(resetHour: 2, calendar: calendar), resetHour: 2, calendar: calendar), spring)
            XCTAssertEqual(DayKey(fall.start(resetHour: 2, calendar: calendar), resetHour: 2, calendar: calendar), fall)
        }
    }

    func testPresentationCanStillUseUserCalendarAndLocale() throws {
        var userCalendar = Calendar(identifier: .buddhist)
        userCalendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day: DayKey = "2026-11-09"
        let formatter = DateFormatter()
        formatter.calendar = userCalendar
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = userCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(formatter.string(from: day.date(calendar: userCalendar)), "2569-11-09")
        XCTAssertEqual(day.raw, "2026-11-09")
    }

    func testRepeatedLoadSaveKeepsGregorianStorageAndDatePrecision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = Fixture.calendar.timeZone
        calendar.locale = Locale(identifier: "th_TH")
        let date = Date(timeIntervalSinceReferenceDate: 815000000.125)
        var planner = Planner()
        planner.tasks = [PlanTask(title: "Calendar fixture", day: DayKey(date, calendar: calendar), createdAt: date)]
        for _ in 0..<8 {
            try file.save(planner)
            let loaded = try file.load()
            XCTAssertEqual(loaded, planner)
            XCTAssertEqual(loaded.tasks.first?.day, DayKey(date, calendar: Fixture.calendar))
            planner = loaded
        }
        XCTAssertTrue(try file.backupURLs().isEmpty)
    }

    func testDayKeyRoundTripAcceptsLeapDaysAndRejectsNonASCII() throws {
        for raw in ["2000-02-29", "2024-02-29", "9999-12-31", "0001-01-01"] {
            XCTAssertEqual(try JSONDecoder().decode(DayKey.self, from: JSONEncoder().encode(raw)).raw, raw)
        }
        for raw in ["1900-02-29", "2100-02-29", "２０２６-１１-０９", "2026-00-10", "2026-11-00", "-001-01-01"] {
            XCTAssertThrowsError(try JSONDecoder().decode(DayKey.self, from: JSONEncoder().encode(raw)), raw)
        }
    }
}
