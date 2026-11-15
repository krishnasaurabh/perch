import Foundation
import XCTest
@testable import PerchUI
@testable import PlannerCore

final class WeekRedesignTests: XCTestCase {
    private let today: DayKey = "2026-11-13"
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    func testWeekPreviewProvidesTimesAndDaylessThoughts() throws {
        let fixture = try PlannerPreviewScenarios.make("week-full")
        XCTAssertEqual(fixture.planner.parkedThoughts.count, 3)
        XCTAssertTrue(fixture.planner.tasks.contains { $0.day == fixture.day && $0.startAt != nil })
    }

    func testEightColumnsUseTheAuthoredSharesAndEightPointGaps() {
        let days = WeekColumnLayout.days(today: today, calendar: calendar)
        let layout = WeekColumnLayout.columns(days: days, today: today, available: 1252)
        XCTAssertEqual(layout.days, days)
        XCTAssertEqual(layout.omittedPastDays, 0)
        XCTAssertEqual(layout.width(for: today) / layout.parkingWidth, 1.7, accuracy: 0.0001)
        XCTAssertEqual(layout.width(for: days[0]) / layout.parkingWidth, 0.85, accuracy: 0.0001)
        XCTAssertEqual(layout.width(for: days[5]), layout.parkingWidth)
        XCTAssertEqual(layout.gap, 8)
        XCTAssertEqual(
            days.reduce(layout.parkingWidth) { $0 + layout.width(for: $1) } + 7 * layout.gap,
            1252, accuracy: 0.0001)
    }

    func testNarrowLayoutDropsOnlyEarliestPastDaysAndKeepsThemReachable() {
        let days = WeekColumnLayout.days(today: today, calendar: calendar)
        let layout = WeekColumnLayout.columns(days: days, today: today, available: 932)
        XCTAssertGreaterThan(layout.omittedPastDays, 0)
        XCTAssertEqual(layout.backingDays, days)
        XCTAssertEqual(layout.days, Array(days.dropFirst(layout.omittedPastDays)))
        XCTAssertTrue(days.filter { $0 >= today }.allSatisfy(layout.days.contains))
        XCTAssertGreaterThanOrEqual(layout.parkingWidth, 140)
        let fewer = WeekColumnLayout.columns(
            days: days, today: today, available: 932,
            revealedPastDays: 1)
        XCTAssertEqual(fewer.days.first, days[layout.omittedPastDays - 1])
        XCTAssertTrue(fewer.needsHorizontalScroll)
    }

    func testTinyScreensNeverDropTodayOrComingDays() {
        for firstWeekday in 1...7 {
            var cal = calendar; cal.firstWeekday = firstWeekday
            let days = WeekColumnLayout.days(today: today, calendar: cal)
            let layout = WeekColumnLayout.columns(days: days, today: today, available: 256)
            XCTAssertEqual(layout.days, days.filter { $0 >= today })
            XCTAssertTrue(layout.needsHorizontalScroll)
            XCTAssertGreaterThanOrEqual(layout.parkingWidth, 140)
        }
        XCTAssertEqual(WeekColumnLayout.windowWidth(screenWidth: 1024), 960)
        XCTAssertEqual(WeekColumnLayout.windowWidth(screenWidth: 2000), 1280)
    }

    func testPastAndFutureWeeksKeepTheirRegionalDates() {
        for offset in [-1, 0, 1] {
            let days = WeekColumnLayout.days(today: today, weekOffset: offset, calendar: calendar)
            let layout = WeekColumnLayout.columns(days: days, today: today, available: 1252)
            XCTAssertEqual(layout.backingDays.count, 7)
            XCTAssertEqual(layout.backingDays.first?.weekday(calendar: calendar), 2)
            XCTAssertFalse(layout.days.isEmpty)
        }
    }

    func testSummariesLimitPastToTwoTodayToFiveButNotComingDays() {
        let past = today.adding(days: -1, calendar: calendar)
        var tasks = (0..<8).map { PlanTask(title: "Task \($0)", day: past, done: $0 < 4) }
        let moved = PlanTask(title: "Carried task", day: today, carriedFrom: past)
        tasks.append(moved)
        let history = WeekTaskPolicy.summary(day: past, today: today, tasks: tasks)
        XCTAssertEqual(history.tasks.count, 2)
        XCTAssertTrue(history.tasks.allSatisfy(\.done))
        XCTAssertEqual(history.count, "4 done")
        XCTAssertEqual(history.more, "and 2 more")
        XCTAssertEqual(history.carried.map(\.id), [moved.id])
        tasks = (0..<6).map { PlanTask(title: "Task \($0)", day: today, done: $0 == 5) }
        let current = WeekTaskPolicy.summary(day: today, today: today, tasks: tasks)
        XCTAssertEqual(current.tasks.count, 5)
        XCTAssertEqual(current.count, "1 of 6 done")
        XCTAssertEqual(current.more, "1 more")
        let expanded = WeekTaskPolicy.summary(day: today, today: today, tasks: tasks, expanded: true)
        XCTAssertEqual(expanded.tasks.count, 6)
        XCTAssertNil(expanded.more)
        let future = today.adding(days: 1, calendar: calendar)
        tasks = tasks.map {
            var t = $0; t.day = future; return t
        }
        let coming = WeekTaskPolicy.summary(day: future, today: today, tasks: tasks)
        XCTAssertEqual(coming.tasks.count, 6)
        XCTAssertEqual(coming.count, "5 to do")
    }

    func testCarryNotesDoNotDuplicateAnExistingSourceTask() {
        let past = today.adding(days: -1, calendar: calendar)
        let source = PlanTask(title: "Read", day: past)
        let copy = PlanTask(title: "Read", day: today, carriedFrom: past, carriedTaskID: source.id)
        let summary = WeekTaskPolicy.summary(day: past, today: today, tasks: [source, copy])
        XCTAssertTrue(summary.tasks.isEmpty)
        XCTAssertEqual(summary.carried.map(\.id), [copy.id])
    }

    func testCarryNotesRemainAfterRolloverAndASecondCarry() throws {
        let sourceDay = today.adding(days: -1, calendar: calendar)
        let nextDay = today.adding(days: 1, calendar: calendar)
        let source = PlanTask(title: "Read", day: sourceDay)
        var planner = Planner()
        planner.tasks = [source]
        var engine = PlannerEngine(
            planner: planner, now: { self.today.date(calendar: self.calendar) }, calendar: calendar)
        let first = try XCTUnwrap(engine.carryForward([source.id], to: today).first)
        let second = try XCTUnwrap(engine.carryForward([first.id], to: nextDay).first)
        let encoded = try JSONEncoder().encode(engine.planner)
        let saved = try JSONDecoder().decode(Planner.self, from: encoded)
        let sourceSummary = WeekTaskPolicy.summary(day: sourceDay, today: nextDay, tasks: saved.tasks)
        XCTAssertTrue(sourceSummary.tasks.isEmpty)
        XCTAssertEqual(sourceSummary.carried.map(\.id), [first.id])
        let intermediate = WeekTaskPolicy.summary(day: today, today: nextDay, tasks: saved.tasks)
        XCTAssertTrue(intermediate.tasks.isEmpty)
        XCTAssertEqual(intermediate.carried.map(\.id), [second.id])
        XCTAssertTrue(WeekTaskPolicy.summary(day: nextDay, today: nextDay, tasks: saved.tasks).carried.isEmpty)
    }

    func testCarryNoteRemainsAfterCompletionAndRescheduling() {
        let source = today.adding(days: -1, calendar: calendar)
        let later = today.adding(days: 2, calendar: calendar)
        let copy = PlanTask(title: "Read", day: later, done: true, carriedFrom: source)
        XCTAssertEqual(
            WeekTaskPolicy.summary(day: source, today: later.adding(days: 1, calendar: calendar), tasks: [copy]).carried
                .map(\.id), [copy.id])
    }

    func testMoveDestinationsFollowDisplayedWeekAndRejectPastAndSameDay() {
        let nextWeek = WeekColumnLayout.days(today: today, weekOffset: 1, calendar: calendar)
        let task = PlanTask(title: "Read", day: nextWeek[1])
        XCTAssertEqual(
            WeekTaskPolicy.moveDestinations(for: task, displayedDays: nextWeek, today: today),
            nextWeek.filter { $0 != task.day })
        let currentWeek = WeekColumnLayout.days(today: today, calendar: calendar)
        XCTAssertEqual(
            WeekTaskPolicy.moveDestinations(for: task, displayedDays: currentWeek, today: today),
            currentWeek.filter { $0 >= today })
        var finished = task
        finished.done = true
        XCTAssertTrue(WeekTaskPolicy.moveDestinations(for: finished, displayedDays: nextWeek, today: today).isEmpty)
    }

    func testTypedIdentityPoliciesRejectStaleAndInvalidMoves() {
        let task = PlanTask(title: "Same title", day: today)
        let future = today.adding(days: 1, calendar: calendar)
        XCTAssertNotNil(WeekTaskPolicy.moveAction(id: task.id, to: .day(future), tasks: [task], today: today))
        XCTAssertNil(WeekTaskPolicy.moveAction(id: UUID(), to: .day(future), tasks: [task], today: today))
        XCTAssertNil(WeekTaskPolicy.moveAction(id: task.id, to: .day(today), tasks: [task], today: today))
        XCTAssertNil(
            WeekTaskPolicy.moveAction(id: task.id, to: .day(today.adding(days: -1)), tasks: [task], today: today))
    }
}
