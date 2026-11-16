import Foundation
import PlannerCore
import XCTest
@testable import PerchUI

final class YourWeekModelTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        value.firstWeekday = 2
        return value
    }
    private func model(_ tasks: [PlanTask], today: DayKey = "2026-11-13", firstWeekday: Int = 2) -> YourWeekModel {
        var planner = Planner()
        planner.tasks = tasks
        var calendar = calendar
        calendar.firstWeekday = firstWeekday
        let now = today.date(calendar: calendar).addingTimeInterval(12 * 3600)
        return YourWeekModel(engine: PlannerEngine(planner: planner, now: { now }, calendar: calendar))
    }
    private func task(_ day: DayKey, done: Bool = true, carry: Int = 0) -> PlanTask {
        PlanTask(title: "Sample", day: day, done: done, createdAt: day.date(calendar: calendar), carryCount: carry)
    }

    func testCalendarWeekIsNotRollingSevenDaysAndFutureDaysStayEmpty() {
        let value = model([
            task("2026-11-08"), task("2026-11-09"), task("2026-11-09"), task("2026-11-13"), task("2026-11-14"),
        ])
        XCTAssertEqual(value.days.map(\.day), (0..<7).map { DayKey("2026-11-09").adding(days: $0, calendar: calendar) })
        XCTAssertEqual(value.days.map(\.done), [2, 0, 0, 0, 1, 0, 0])
        XCTAssertEqual(value.days.map(\.isFuture), [false, false, false, false, false, true, true])
        XCTAssertEqual(value.done, 3)
        XCTAssertEqual(value.previousDone, 1)
        XCTAssertEqual(value.nextWeekStart, "2026-11-16")
    }

    func testRegionalFirstWeekdayAndYearBoundary() {
        let value = model([], today: "2027-01-01", firstWeekday: 1)
        XCTAssertEqual(value.weekStart, "2026-12-27")
        XCTAssertEqual(value.weekEnd, "2027-01-02")
        XCTAssertEqual(value.nextWeekStart, "2027-01-03")
    }

    func testKeptGoingSkipsAnyUnplannedDayNotJustWeekends() {
        let value = model([task("2026-11-06"), task("2026-11-09"), task("2026-11-11"), task("2026-11-13")])
        XCTAssertEqual(value.keptGoing, 4)
        XCTAssertEqual(model([]).keptGoing, 0)
    }

    func testPlannedDayWithNoCompletionBreaksKeptGoing() {
        XCTAssertEqual(model([task("2026-11-09"), task("2026-11-10", done: false), task("2026-11-13")]).keptGoing, 1)
        XCTAssertEqual(model([task("2026-11-12"), task("2026-11-13", done: false)]).keptGoing, 0)
    }

    func testCompletionsUseActualLogicalDayAndLegacyFallback() {
        var completed = task("2026-11-09")
        completed.completedAt = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 2))!
        let value = model([completed, task("2026-11-13")])
        XCTAssertEqual(value.days.map(\.done), [0, 0, 0, 1, 1, 0, 0])
        XCTAssertEqual(value.activeDays, 2)
    }

    func testStillWaitingOnlyIncludesEditableOpenTasksCarriedAtLeastTwice() {
        let waiting = task("2026-11-13", done: false, carry: 2)
        let value = model([
            waiting, task("2026-11-12", done: false, carry: 3), task("2026-11-13", carry: 3),
            task("2026-11-13", done: false, carry: 1),
        ])
        XCTAssertEqual(value.stillWaiting.map(\.id), [waiting.id])
    }

    func testBlockTimeUsesRecordedIntervalsNotPlannedLengthsAndClipsAtWeekBoundary() {
        var planner = Planner()
        let start = DayKey("2026-11-09").start(resetHour: 4, calendar: calendar)
        planner.tasks = [PlanTask(title: "Not run", day: "2026-11-13", minutes: 60)]
        planner.focusSegments = [
            FocusSegment(taskID: nil, start: start.addingTimeInterval(-600), end: start.addingTimeInterval(1800)),
            FocusSegment(taskID: nil, start: start.addingTimeInterval(3600), end: start.addingTimeInterval(4200)),
        ]
        let now = DayKey("2026-11-13").date(calendar: calendar).addingTimeInterval(12 * 3600)
        let value = YourWeekModel(engine: PlannerEngine(planner: planner, now: { now }, calendar: calendar))
        XCTAssertEqual(value.focusSeconds, 2400, accuracy: 0.001)
        XCTAssertEqual(value.blockHours, 0)
        XCTAssertEqual(value.blockMinutes, 40)
    }
}
