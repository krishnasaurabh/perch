import XCTest
import PlannerCore
@testable import PerchUI

final class WeekPresentationTests: XCTestCase {
    private func calendar(_ zone: String = "America/Los_Angeles", firstWeekday: Int = 2) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        value.firstWeekday = firstWeekday
        return value
    }

    func testEveryWeekdaySelectsTheSameSevenDays() {
        let cal = calendar()
        let monday: DayKey = "2026-11-09"
        let expected = (0..<7).map { monday.adding(days: $0, calendar: cal) }
        for day in expected {
            XCTAssertEqual(WeekColumnLayout.days(today: day, calendar: cal), expected)
        }
    }

    func testSundayFirstAndYearBoundaryWithAdjacentWeeks() {
        let cal = calendar(firstWeekday: 1)
        let days = WeekColumnLayout.days(today: "2026-01-01", calendar: cal)
        XCTAssertEqual(
            days.map(\.raw),
            [
                "2025-12-28", "2025-12-29", "2025-12-30", "2025-12-31",
                "2026-01-01", "2026-01-02", "2026-01-03",
            ])
        XCTAssertEqual(WeekColumnLayout.days(today: "2026-01-01", weekOffset: 1, calendar: cal).first, "2026-01-04")
        XCTAssertEqual(WeekColumnLayout.days(today: "2026-01-01", weekOffset: -1, calendar: cal).last, "2025-12-27")
    }

    func testDSTAndResetHourChooseTheLogicalWeekNotTheWallDate() {
        let cal = calendar()
        for raw in ["2026-03-09", "2026-11-02"] {
            let monday = DayKey(raw)!
            let reset = monday.start(resetHour: 4, calendar: cal)
            let before = DayKey(reset.addingTimeInterval(-1), resetHour: 4, calendar: cal)
            let after = DayKey(reset, resetHour: 4, calendar: cal)
            XCTAssertEqual(
                WeekColumnLayout.days(today: before, calendar: cal).last,
                monday.adding(days: -1, calendar: cal))
            XCTAssertEqual(WeekColumnLayout.days(today: after, calendar: cal).first, monday)
            XCTAssertEqual(Set(WeekColumnLayout.days(today: before, calendar: cal)).count, 7)
        }
    }

    func testHalfHourDSTAndNonGregorianPresentationKeepGregorianDays() {
        var cal = Calendar(identifier: .buddhist)
        cal.timeZone = TimeZone(identifier: "Australia/Lord_Howe")!
        cal.firstWeekday = 2
        let days = WeekColumnLayout.days(today: "2026-10-04", calendar: cal)
        XCTAssertEqual(days.first, "2026-09-28")
        XCTAssertEqual(days.last, "2026-10-04")
        XCTAssertEqual(Set(days).count, 7)
    }

    func testNarrowAndWideLayoutsNeverCompressTheMinimumTitleSpace() {
        for available in [320.0, 620, 820, 1440, 2048] {
            let width = WeekColumnLayout.columnWidth(available: available)
            XCTAssertGreaterThanOrEqual(width, 248)
            XCTAssertGreaterThanOrEqual(width - 2 * ThemeTokens.cardPadding - 2 * ThemeTokens.minimumTarget - 24, 140)
        }
        XCTAssertEqual(WeekColumnLayout.columnWidth(available: 620), WeekColumnLayout.columnWidth(available: 820))
    }

    func testCheckingIsTodayOnlyAndPreservesDuplicateTitleIdentity() throws {
        let cal = calendar()
        let today: DayKey = "2026-11-11"
        let first = PlanTask(title: "Same title", day: today)
        let other = PlanTask(title: "Same title", day: today)
        var planner = Planner(); planner.tasks = [first, other]
        var engine = PlannerEngine(planner: planner, now: { today.start(resetHour: 0, calendar: cal) }, calendar: cal)
        let action = try XCTUnwrap(WeekTaskPolicy.completionAction(for: first, today: today))
        try engine.execute(action)
        XCTAssertTrue(try engine.task(first.id).done)
        XCTAssertFalse(try engine.task(other.id).done)
        let reopen = try XCTUnwrap(WeekTaskPolicy.completionAction(for: engine.task(first.id), today: today))
        try engine.execute(reopen)
        XCTAssertFalse(try engine.task(first.id).done)
        for day: DayKey? in [nil, "2026-11-10", "2026-11-12"] {
            XCTAssertNil(WeekTaskPolicy.completionAction(for: PlanTask(title: "Not today", day: day), today: today))
        }
    }

    func testDropsRejectUnknownPartialPastCompletedAndNoOpPayloads() {
        let today: DayKey = "2026-11-11"
        let open = PlanTask(title: "Plan", day: today)
        let past = PlanTask(title: "Past", day: "2026-11-10")
        var done = PlanTask(title: "Done", day: today); done.done = true
        let tasks = [open, past, done]
        for payload in [
            "Plan", String(open.id.uuidString.prefix(8)), UUID().uuidString, past.id.uuidString, done.id.uuidString,
        ] {
            XCTAssertNil(WeekTaskPolicy.moveAction(payload: payload, to: .inbox, tasks: tasks, today: today))
        }
        for destination in [DayRef.day(today), .day("2026-11-10")] {
            XCTAssertNil(
                WeekTaskPolicy.moveAction(payload: open.id.uuidString, to: destination, tasks: tasks, today: today))
        }
    }

    func testMoveRoundTripUsesCommandsAndRetainsIdentityAndContent() throws {
        let cal = calendar()
        let today: DayKey = "2026-11-11"
        var task = PlanTask(title: "Line one\nLine two with a long descriptive title", day: today)
        task.notes = "Keep this note"; task.minutes = 40
        var planner = Planner(); planner.tasks = [task, PlanTask(title: task.title, day: today)]
        var engine = PlannerEngine(planner: planner, now: { today.start(resetHour: 0, calendar: cal) }, calendar: cal)
        for destination in [DayRef.inbox, .day("2026-11-13"), .day(today)] {
            let action = try XCTUnwrap(
                WeekTaskPolicy.moveAction(
                    payload: task.id.uuidString, to: destination,
                    tasks: engine.planner.tasks, today: today))
            try engine.execute(action)
            let moved = try engine.task(task.id)
            XCTAssertEqual(moved.day, destination.key)
            XCTAssertEqual(moved.title, task.title)
            XCTAssertEqual(moved.notes, task.notes)
            XCTAssertEqual(moved.minutes, task.minutes)
            XCTAssertEqual(engine.planner.tasks.count, 2)
        }
    }

    func testStaleCheckAndDropAreRevalidatedByTheEngine() throws {
        let cal = calendar()
        let today: DayKey = "2026-11-11"
        let task = PlanTask(title: "Stale row", day: today)
        var planner = Planner(); planner.tasks = [task]
        var engine = PlannerEngine(planner: planner, now: { today.start(resetHour: 0, calendar: cal) }, calendar: cal)
        let check = try XCTUnwrap(WeekTaskPolicy.completionAction(for: task, today: today))
        try engine.execute(.move(task.id, .day("2026-11-12")))
        XCTAssertThrowsError(try engine.execute(check))
        XCTAssertFalse(try engine.task(task.id).done)
        let drop = try XCTUnwrap(
            WeekTaskPolicy.moveAction(
                payload: task.id.uuidString, to: .inbox,
                tasks: engine.planner.tasks, today: today))
        try engine.execute(.delete(task.id))
        XCTAssertThrowsError(try engine.execute(drop))
        XCTAssertTrue(engine.planner.tasks.isEmpty)
    }
}
