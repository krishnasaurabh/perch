import XCTest
@testable import PlannerCore

/// Repeat arithmetic at month ends, leap years, weekday lists and DST boundaries.
/// Fixture calendar: America/Los_Angeles.
final class TaskRepeatEdgeTests: XCTestCase {
    private let cal = Fixture.calendar
    private func day(_ s: String) -> DayKey { DayKey(stringLiteral: s) }
    private func next(_ r: TaskRepeat, after planned: String, completed: String? = nil) -> String {
        r.next(after: day(planned), completed: day(completed ?? planned), calendar: cal).raw
    }

    // MARK: Month ends and leap years

    func testMonthlyClampsToTheEndOfShorterMonths() {
        XCTAssertEqual(next(.monthly, after: "2026-01-31"), "2026-02-28")
        XCTAssertEqual(next(.monthly, after: "2028-01-31"), "2028-02-29")
        XCTAssertEqual(next(.monthly, after: "2026-08-31"), "2026-09-30")
        XCTAssertEqual(next(.monthly, after: "2027-03-31"), "2027-04-30")
        XCTAssertEqual(next(.monthly, after: "2026-05-31"), "2026-06-30")
        XCTAssertEqual(next(.monthly, after: "2026-04-30"), "2026-05-30")
        XCTAssertEqual(next(.monthly, after: "2026-12-31"), "2027-01-31")
    }

    func testMonthlyWithIntervals() {
        XCTAssertEqual(next(TaskRepeat(unit: .month, interval: 2), after: "2027-01-31"), "2027-03-31")
        XCTAssertEqual(next(TaskRepeat(unit: .month, interval: 3), after: "2026-11-30"), "2027-02-28")
        XCTAssertEqual(next(TaskRepeat(unit: .month, interval: 12), after: "2027-02-28"), "2028-02-28")
    }

    func testMonthlyClampingIsSticky() {
        // Once a month-end rule lands on the 28th, later months follow the 28th.
        var d = day("2026-01-31")
        var chain: [String] = []
        for _ in 0..<4 {
            d = TaskRepeat.monthly.next(after: d, completed: d, calendar: cal)
            chain.append(d.raw)
        }
        XCTAssertEqual(chain, ["2026-02-28", "2026-03-28", "2026-04-28", "2026-05-28"])
    }

    func testDailyAcrossLeapDayAndYearEnd() {
        XCTAssertEqual(next(.daily, after: "2028-02-28"), "2028-02-29")
        XCTAssertEqual(next(.daily, after: "2027-02-28"), "2027-03-01")
        XCTAssertEqual(next(.daily, after: "2028-02-29"), "2028-03-01")
        XCTAssertEqual(next(.daily, after: "2026-12-31"), "2027-01-01")
    }

    // MARK: Weekday lists

    func testWeekdayListStepsThroughTheWeek() {
        let mwf = TaskRepeat(unit: .week, weekdays: [2, 4, 6])
        XCTAssertEqual(next(mwf, after: "2026-11-09"), "2026-11-11")  // Mon -> Wed
        XCTAssertEqual(next(mwf, after: "2026-11-10"), "2026-11-11")  // Tue -> Wed
        XCTAssertEqual(next(mwf, after: "2026-11-11"), "2026-11-13")  // Wed -> Fri
        XCTAssertEqual(next(mwf, after: "2026-11-12"), "2026-11-13")  // Thu -> Fri
        XCTAssertEqual(next(mwf, after: "2026-11-13"), "2026-11-16")  // Fri -> Mon
        XCTAssertEqual(next(mwf, after: "2026-11-14"), "2026-11-16")  // Sat -> Mon
        XCTAssertEqual(next(mwf, after: "2026-11-15"), "2026-11-16")  // Sun -> Mon
    }

    func testSingleWeekdayListsWrapCorrectly() {
        let sunday = TaskRepeat(unit: .week, weekdays: [1])
        XCTAssertEqual(next(sunday, after: "2026-11-15"), "2026-11-22")
        XCTAssertEqual(next(sunday, after: "2026-11-09"), "2026-11-15")
        XCTAssertEqual(next(sunday, after: "2026-11-14"), "2026-11-15")

        let saturday = TaskRepeat(unit: .week, weekdays: [7])
        XCTAssertEqual(next(saturday, after: "2026-11-14"), "2026-11-21")
        XCTAssertEqual(next(saturday, after: "2026-11-09"), "2026-11-14")

        let monday = TaskRepeat(unit: .week, weekdays: [2])
        XCTAssertEqual(next(monday, after: "2026-11-09"), "2026-11-16")
        XCTAssertEqual(next(monday, after: "2026-11-10"), "2026-11-16")

        let weekend = TaskRepeat(unit: .week, weekdays: [1, 7])
        XCTAssertEqual(next(weekend, after: "2026-11-14"), "2026-11-15")
        XCTAssertEqual(next(weekend, after: "2026-11-15"), "2026-11-21")
    }

    func testIntervalWeekdayListsKeepThePhase() {
        let biweeklyTue = TaskRepeat(unit: .week, interval: 2, weekdays: [3])
        XCTAssertEqual(next(biweeklyTue, after: "2026-11-10"), "2026-11-24")
        XCTAssertEqual(next(biweeklyTue, after: "2026-11-11"), "2026-11-24")
        let everyThreeWeeksMonday = TaskRepeat(unit: .week, interval: 3, weekdays: [2])
        XCTAssertEqual(next(everyThreeWeeksMonday, after: "2026-11-09"), "2026-11-30")
        XCTAssertEqual(next(everyThreeWeeksMonday, after: "2026-11-10"), "2026-11-30")
    }

    func testFirstOccurrenceSnapsWeekdayRulesForward() {
        let mwf = TaskRepeat(unit: .week, weekdays: [2, 4, 6])
        XCTAssertEqual(mwf.firstOccurrence(onOrAfter: day("2026-11-09"), calendar: cal).raw, "2026-11-09")
        XCTAssertEqual(mwf.firstOccurrence(onOrAfter: day("2026-11-10"), calendar: cal).raw, "2026-11-11")
        XCTAssertEqual(mwf.firstOccurrence(onOrAfter: day("2026-11-14"), calendar: cal).raw, "2026-11-16")

        let biweeklyTue = TaskRepeat(unit: .week, interval: 2, weekdays: [3])
        XCTAssertEqual(biweeklyTue.firstOccurrence(onOrAfter: day("2026-11-10"), calendar: cal).raw, "2026-11-10")
        XCTAssertEqual(biweeklyTue.firstOccurrence(onOrAfter: day("2026-11-11"), calendar: cal).raw, "2026-11-17")

        XCTAssertEqual(
            TaskRepeat.weekdaysRule.firstOccurrence(onOrAfter: day("2026-11-14"), calendar: cal).raw, "2026-11-16")
        XCTAssertEqual(
            TaskRepeat.monthly.firstOccurrence(onOrAfter: day("2026-02-28"), calendar: cal).raw, "2026-02-28")
    }

    func testWeekdaysOnlySkipsWeekends() {
        XCTAssertEqual(next(.weekdaysRule, after: "2026-11-13"), "2026-11-16")  // Fri -> Mon
        XCTAssertEqual(next(.weekdaysRule, after: "2026-11-14"), "2026-11-16")  // Sat -> Mon
        XCTAssertEqual(next(.weekdaysRule, after: "2026-11-15"), "2026-11-16")  // Sun -> Mon
        XCTAssertEqual(
            next(
                TaskRepeat(unit: .day, weekdaysOnly: true, fromCompletion: true), after: "2026-11-13",
                completed: "2026-11-14"), "2026-11-16")
    }

    func testWeekdayFreeWeeklyAndIntervalClamp() {
        XCTAssertEqual(next(.weekly, after: "2026-11-09"), "2026-11-16")
        XCTAssertEqual(next(TaskRepeat(unit: .week, interval: 2), after: "2026-11-09"), "2026-11-23")
        XCTAssertEqual(next(TaskRepeat(unit: .week, interval: 0), after: "2026-11-09"), "2026-11-16")
        XCTAssertEqual(next(TaskRepeat(unit: .day, interval: 0), after: "2026-11-09"), "2026-11-10")
        XCTAssertEqual(next(TaskRepeat(unit: .day, interval: -5), after: "2026-11-09"), "2026-11-10")
    }

    func testFromCompletionUsesTheCompletionDay() {
        XCTAssertEqual(
            next(
                TaskRepeat(unit: .day, interval: 3, fromCompletion: true), after: "2026-11-01", completed: "2026-11-09"),
            "2026-11-12")
        XCTAssertEqual(
            next(
                TaskRepeat(unit: .week, interval: 2, fromCompletion: true), after: "2026-11-01", completed: "2026-11-09"
            ), "2026-11-23")
        XCTAssertEqual(
            next(TaskRepeat(unit: .month, fromCompletion: true), after: "2026-01-31", completed: "2026-11-30"),
            "2026-12-30")
    }

    // MARK: DST boundaries

    func testRepeatStepsStayOnTheWallClockAcrossDST() {
        XCTAssertEqual(next(.daily, after: "2027-03-13"), "2027-03-14")
        XCTAssertEqual(next(.daily, after: "2027-03-14"), "2027-03-15")
        XCTAssertEqual(next(.daily, after: "2026-10-31"), "2026-11-01")
        XCTAssertEqual(next(.daily, after: "2026-11-01"), "2026-11-02")
        XCTAssertEqual(next(.weekdaysRule, after: "2027-03-12"), "2027-03-15")  // Fri -> Mon
        XCTAssertEqual(next(.weekly, after: "2027-03-08"), "2027-03-15")
        XCTAssertEqual(next(.monthly, after: "2027-02-13"), "2027-03-13")
        // A 23-hour spring-forward day and a 25-hour fall-back day.
        let spring = day("2027-03-15").date(calendar: cal).timeIntervalSince(day("2027-03-14").date(calendar: cal))
        let fall = day("2026-11-02").date(calendar: cal).timeIntervalSince(day("2026-11-01").date(calendar: cal))
        XCTAssertEqual(spring, 23 * 3600, accuracy: 1)
        XCTAssertEqual(fall, 25 * 3600, accuracy: 1)
    }

    // MARK: Parsing

    func testRuleParsingVariants() {
        XCTAssertEqual(TaskRepeat.find(in: "every week on mon, wed")?.0, TaskRepeat(unit: .week, weekdays: [2, 4]))
        XCTAssertEqual(
            TaskRepeat.find(in: "every 2 weeks on tue, thu")?.0, TaskRepeat(unit: .week, interval: 2, weekdays: [3, 5]))
        XCTAssertEqual(
            TaskRepeat.find(in: "every other week on fri")?.0, TaskRepeat(unit: .week, interval: 2, weekdays: [6]))
        XCTAssertEqual(TaskRepeat.find(in: "every sunday")?.0, TaskRepeat(unit: .week, weekdays: [1]))
        XCTAssertEqual(TaskRepeat.find(in: "every tues")?.0, TaskRepeat(unit: .week, weekdays: [3]))
        XCTAssertEqual(TaskRepeat.find(in: "every thurs")?.0, TaskRepeat(unit: .week, weekdays: [5]))
        XCTAssertEqual(TaskRepeat.find(in: "every sun, sat")?.0, TaskRepeat(unit: .week, weekdays: [1, 7]))
        XCTAssertEqual(TaskRepeat.find(in: "every! week")?.0, TaskRepeat(unit: .week, fromCompletion: true))
        XCTAssertEqual(TaskRepeat.find(in: "every 0 days")?.0, .daily, "0 is clamped to a 1-day interval")
        XCTAssertNil(
            TaskRepeat.find(in: "every 1000 days"),
            "BUG-adjacent: counts are capped at 3 digits and the phrase is silently ignored")
    }

    func testDuplicateWeekdaysCollapse() {
        XCTAssertEqual(TaskRepeat.find(in: "every mon, mon and monday")?.0, TaskRepeat(unit: .week, weekdays: [2]))
    }

    func testStandaloneRuleParsingIsStrict() {
        XCTAssertEqual(TaskRepeat.parseRule("none")!, nil)
        XCTAssertEqual(TaskRepeat.parseRule("never")!, nil)
        XCTAssertEqual(TaskRepeat.parseRule("")!, nil)
        XCTAssertNil(TaskRepeat.parseRule("sometimes"))
        XCTAssertNil(TaskRepeat.parseRule("every day please"))
        XCTAssertEqual(TaskRepeat.parseRule("  every day  ")!!, .daily)
        XCTAssertEqual(TaskRepeat.parseRule("every mon, wed")!!, TaskRepeat(unit: .week, weekdays: [2, 4]))
        XCTAssertEqual(TaskRepeat.parseRule("monthly")!!, .monthly)
    }

    func testDescriptionRoundTripsThroughTheParser() {
        let rules: [TaskRepeat] = [
            .daily, .weekly, .monthly, .weekdaysRule,
            TaskRepeat(unit: .day, interval: 3),
            TaskRepeat(unit: .week, interval: 2),
            TaskRepeat(unit: .week, weekdays: [2, 4, 6]),
            TaskRepeat(unit: .week, interval: 2, weekdays: [3]),
            TaskRepeat(unit: .day, interval: 3, fromCompletion: true),
            TaskRepeat(unit: .month, interval: 3),
        ]
        for rule in rules {
            XCTAssertEqual(TaskRepeat.parseRule(rule.description)!!, rule, rule.description)
        }
    }

    func testNextCopyStaysValidForAYear() {
        var d = day("2026-01-31")
        for _ in 0..<12 {
            let n = TaskRepeat.monthly.next(after: d, completed: d, calendar: cal)
            XCTAssertGreaterThan(n, d)
            XCTAssertEqual(Int(n.raw.suffix(2))! >= 1, true)
            d = n
        }
        XCTAssertEqual(d.raw, "2027-01-28")
    }
}
