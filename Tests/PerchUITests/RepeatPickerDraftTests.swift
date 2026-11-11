import Foundation
import PlannerCore
import PlannerTestSupport
import XCTest

@testable import PerchUI

final class RepeatPickerDraftTests: XCTestCase {
    private let today: DayKey = "2026-11-09"
    private let posix = Locale(identifier: "en_US_POSIX")

    /// America/Santiago skips local midnight when daylight time begins on 2026-09-06.
    private let santiago: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Santiago")!
        return c
    }()

    private func draft(
        _ original: TaskRepeat?, anchor: DayKey? = "2026-11-09", calendar: Calendar = Fixture.calendar
    ) -> RepeatPickerDraft {
        RepeatPickerDraft(original: original, anchor: anchor, calendar: calendar)
    }

    private func days(_ preview: RepeatPickerDraft.Preview) -> [String] {
        guard case .scheduled(let days) = preview else { return [] }
        return days.map(\.raw)
    }

    // MARK: Does not repeat

    func testNoRepeatIsAnExplicitState() {
        let d = draft(nil)
        XCTAssertEqual(d.frequency, .none)
        XCTAssertNil(d.rule)
        XCTAssertNil(d.issue)
        XCTAssertFalse(d.hasChanges)
        XCTAssertEqual(d.summary, "Does not repeat")
        XCTAssertEqual(d.preview(), .none)
        XCTAssertEqual(RepeatPickerDraft.Frequency.none.title, "Does not repeat")
    }

    func testChoosingDoesNotRepeatClearsAnExistingRule() {
        var d = draft(.weekly)
        d.select(.none)
        XCTAssertNil(d.rule)
        XCTAssertTrue(d.hasChanges)
        XCTAssertEqual(d.commit(), .cleared)
    }

    func testNoRepeatNeedsNoDate() {
        var d = draft(nil, anchor: nil)
        d.select(.none)
        XCTAssertNil(d.visibleIssue)
        XCTAssertEqual(d.commit(), .unchanged)
    }

    // MARK: Mapping the core model

    func testExistingRulesOpenOnTheMatchingFrequency() {
        XCTAssertEqual(draft(.daily).frequency, .daily)
        XCTAssertEqual(draft(.weekdaysRule).frequency, .weekdays)
        XCTAssertEqual(draft(.weekly).frequency, .weekly)
        XCTAssertEqual(draft(TaskRepeat(unit: .week, weekdays: [2, 4])).frequency, .weekly)
        XCTAssertEqual(draft(.monthly).frequency, .monthly)
        XCTAssertEqual(draft(TaskRepeat(unit: .month, interval: 3)).frequency, .quarterly)
        XCTAssertEqual(draft(TaskRepeat(unit: .month, interval: 12)).frequency, .yearly)
        let custom = draft(TaskRepeat(unit: .week, interval: 2, weekdays: [3, 5]))
        XCTAssertEqual(custom.frequency, .custom)
        XCTAssertEqual(custom.customUnit, .week)
        XCTAssertEqual(custom.intervalText, "2")
        XCTAssertEqual(custom.weekdays, [3, 5])
    }

    func testUntouchedDraftCommitsUnchanged() {
        for rule in [
            TaskRepeat.daily, .weekdaysRule, .weekly, .monthly, TaskRepeat(unit: .month, interval: 3),
            TaskRepeat(unit: .month, interval: 12), TaskRepeat(unit: .day, interval: 4, fromCompletion: true),
            TaskRepeat(unit: .week, interval: 2, weekdays: [2, 6]),
        ] {
            var d = draft(rule)
            XCTAssertFalse(d.hasChanges, rule.description)
            XCTAssertEqual(d.rule, rule, rule.description)
            XCTAssertEqual(d.commit(), .unchanged, rule.description)
        }
    }

    func testUntouchedRuleOutsideTheEditableRangeIsKept() {
        let stored = TaskRepeat(unit: .day, interval: 1000)
        var d = draft(stored)
        XCTAssertEqual(d.frequency, .custom)
        XCTAssertEqual(d.intervalText, "1000")
        XCTAssertNil(d.visibleIssue)
        XCTAssertFalse(d.hasChanges)
        XCTAssertEqual(d.commit(), .unchanged, "Opening the editor must not clear the stored rule")
        d.setAnchor("2026-11-20")
        XCTAssertNil(d.visibleIssue, "A new date does not rewrite the kept rule")
        XCTAssertEqual(d.commit(), .unchanged)
        d.setAnchor(nil)
        XCTAssertEqual(d.visibleIssue, .missingAnchor)
        XCTAssertNil(d.commit())
        d.setAnchor("2026-11-20")
        d.select(.custom)
        XCTAssertEqual(d.visibleIssue, .invalidInterval("1000"), "Editing the rule requires a supported interval")
        XCTAssertNil(d.commit())
    }

    func testEveryFrequencyRoundTripsThroughTheRepeatTransport() {
        var rules: [TaskRepeat] = []
        for frequency in RepeatPickerDraft.Frequency.allCases where frequency != .none {
            for fromCompletion in [false, true] {
                var d = draft(nil)
                d.select(frequency)
                if frequency == .weekly || frequency == .custom { d.toggleWeekday(2); d.toggleWeekday(5) }
                if frequency == .custom { d.setCustomUnit(.week); d.typeInterval("3") }
                d.setFromCompletion(fromCompletion)
                guard case .set(let rule)? = d.commit() else { return XCTFail("\(frequency) did not commit") }
                XCTAssertEqual(TaskRepeat.parseRule(rule.description), .rule(rule), rule.description)
                XCTAssertEqual(draft(rule).frequency, frequency == .custom ? .custom : frequency, rule.description)
                rules.append(rule)
            }
        }
        XCTAssertEqual(Set(rules.map(\.description)).count, rules.count, "Each choice is a distinct rule")
    }

    // MARK: Interval validation

    func testInvalidIntervalShowsAnInlineErrorAndBlocksCommit() {
        for text in ["0", "-2", "abc", "2.5", "1000", ""] {
            var d = draft(nil)
            d.select(.custom)
            d.typeInterval(text)
            XCTAssertEqual(d.visibleIssue, .invalidInterval(text), text)
            XCTAssertEqual(d.visibleIssue?.field, .interval, text)
            XCTAssertNil(d.rule, text)
            XCTAssertNil(d.commit(), text)
            XCTAssertEqual(d.preview(), .unavailable, text)
        }
        var d = draft(nil)
        d.select(.custom)
        d.typeInterval("abc")
        XCTAssertEqual(d.visibleIssue?.message, "“abc” is not a valid interval. Enter a whole number from 1 to 999.")
        d.typeInterval(" ")
        XCTAssertEqual(d.visibleIssue?.message, "Enter how often it repeats, from 1 to 999.")
    }

    func testFixingTheIntervalClearsTheError() {
        var d = draft(nil)
        d.select(.custom)
        d.typeInterval("0")
        XCTAssertNotNil(d.visibleIssue)
        d.typeInterval(" 10 ")
        XCTAssertNil(d.visibleIssue)
        XCTAssertEqual(d.commit(), .set(TaskRepeat(unit: .day, interval: 10)))
    }

    func testInvalidCustomTextDoesNotBlockAPresetFrequency() {
        var d = draft(nil)
        d.select(.custom)
        d.typeInterval("zero")
        d.select(.monthly)
        XCTAssertNil(d.issue)
        XCTAssertEqual(d.intervalText, "zero", "The typed text is kept for the custom choice")
        XCTAssertEqual(d.commit(), .set(.monthly))
    }

    func testStepperClampsToTheSupportedRange() {
        var d = draft(TaskRepeat(unit: .day, interval: 998))
        d.stepInterval(by: 1)
        d.stepInterval(by: 1)
        XCTAssertEqual(d.intervalText, "999")
        d.typeInterval("bad")
        d.stepInterval(by: -1)
        XCTAssertEqual(d.intervalText, "1", "Stepping recovers from invalid text")
        d.stepInterval(by: -1)
        XCTAssertEqual(d.intervalText, "1")
    }

    func testCustomStartsFromTheCurrentCadence() {
        var d = draft(TaskRepeat(unit: .month, interval: 3))
        d.select(.custom)
        XCTAssertEqual(d.customUnit, .month)
        XCTAssertEqual(d.intervalText, "3")
        XCTAssertFalse(d.hasChanges, "Same cadence, different control")
        var fresh = draft(nil)
        fresh.select(.custom)
        XCTAssertEqual(fresh.customUnit, .day)
        XCTAssertEqual(fresh.intervalText, "2")
    }

    // MARK: Anchor date

    func testRepeatWithoutADateShowsAnInlineErrorAndBlocksCommit() {
        var d = draft(nil, anchor: nil)
        d.select(.weekly)
        XCTAssertEqual(d.visibleIssue, .missingAnchor)
        XCTAssertEqual(d.visibleIssue?.field, .frequency)
        XCTAssertEqual(d.visibleIssue?.message, "Choose a date for this task before setting a repeat.")
        XCTAssertNil(d.commit())
        XCTAssertEqual(d.preview(), .unavailable)
        d.select(.none)
        XCTAssertNil(d.visibleIssue)
        XCTAssertEqual(d.commit(), .unchanged)
    }

    func testIntervalErrorsAreReportedBeforeAMissingDate() {
        var d = draft(nil, anchor: nil)
        d.select(.custom)
        d.typeInterval("0")
        XCTAssertEqual(d.issue, .invalidInterval("0"))
    }

    func testUntouchedFieldsDoNotOpenWithAnError() {
        var d = draft(.weekly, anchor: nil)
        XCTAssertEqual(d.issue, .missingAnchor)
        XCTAssertNil(d.visibleIssue, "Opening the editor is not an edit")
        XCTAssertEqual(d.commit(), .unchanged)
    }

    func testClearingTheDateWhileEditingShowsTheErrorAndChoosingOneFixesIt() {
        var d = draft(nil, anchor: "2026-11-09")
        d.select(.weekly)
        XCTAssertNil(d.visibleIssue)
        d.setAnchor(nil)
        XCTAssertEqual(d.visibleIssue, .missingAnchor)
        XCTAssertNil(d.commit())
        XCTAssertTrue(d.attemptedCommit)
        d.setAnchor("2026-11-10")
        XCTAssertNil(d.visibleIssue)
        XCTAssertEqual(days(d.preview()), ["2026-11-17", "2026-11-24", "2026-12-01"])
        XCTAssertEqual(d.commit(), .set(.weekly))
    }

    private func materializedDays(
        _ engine: inout PlannerEngine, after day: DayKey, through end: DayKey
    ) -> [String] {
        var cursor = day
        var result: [String] = []
        while cursor < end {
            cursor = cursor.adding(days: 1, calendar: Fixture.calendar)
            result += engine.applyRepeats(on: cursor).compactMap { $0.day?.raw }
        }
        return result
    }

    func testChangingTheDateKeepsTheSeriesSchedule() throws {
        let task = PlanTask(title: "Synthetic monthly task", day: today, repeatRule: .monthly)
        var planner = Planner()
        planner.tasks = [task]
        var engine = PlannerEngine(planner: planner, now: { Fixture.now }, calendar: Fixture.calendar)
        var d = draft(task.repeatRule, anchor: task.day)
        d.setAnchor("2026-11-30")
        XCTAssertFalse(d.hasChanges)
        XCTAssertNil(d.visibleIssue)
        XCTAssertEqual(d.commit(), .unchanged)
        let moved = try engine.move(task.id, from: .day(today), to: .day("2026-11-30"))
        XCTAssertEqual(moved.repeatAnchor, today)
        let actual = materializedDays(&engine, after: "2026-11-30", through: "2027-01-31")
        XCTAssertEqual(actual, ["2026-12-09", "2027-01-09"])
        XCTAssertEqual(days(d.preview(count: 2)), actual)
    }

    func testClampedOccurrencePreviewsAfterItsDayFromTheSeriesAnchor() throws {
        let task = PlanTask(title: "Synthetic month end", day: "2027-01-31", repeatRule: .monthly)
        var planner = Planner()
        planner.tasks = [task]
        var engine = PlannerEngine(planner: planner, now: { Fixture.now }, calendar: Fixture.calendar)
        let occurrence = try XCTUnwrap(engine.applyRepeats(on: "2027-02-28").first)
        XCTAssertEqual(occurrence.repeatAnchor, "2027-01-31")
        var d = draft(occurrence.repeatRule, anchor: occurrence.repeatAnchor)
        d.setAnchor(occurrence.day)
        XCTAssertEqual(d.commit(), .unchanged)
        let actual = materializedDays(&engine, after: "2027-02-28", through: "2027-04-30")
        XCTAssertEqual(actual, ["2027-03-31", "2027-04-30"])
        XCTAssertEqual(days(d.preview(count: 2)), actual)
    }

    func testTaskInitializerKeepsOccurrenceAndSeriesDatesSeparate() throws {
        let task = PlanTask(
            title: "Synthetic clamped occurrence", day: "2027-02-28", repeatRule: .monthly,
            repeatAnchor: "2027-01-31")
        var d = RepeatPickerDraft(task: task, calendar: Fixture.calendar)
        XCTAssertEqual(d.anchor, "2027-02-28")
        XCTAssertEqual(d.seriesAnchor, "2027-01-31")
        XCTAssertEqual(days(d.preview(count: 2)), ["2027-03-31", "2027-04-30"])
        XCTAssertEqual(d.commit(), .unchanged)
    }

    func testUnchangedCadencesMatchTheEngineAfterMovingTheirOccurrence() throws {
        let cases: [(TaskRepeat, DayKey, DayKey, [String])] = [
            (
                TaskRepeat(unit: .day, interval: 3), today, "2026-11-10",
                ["2026-11-12", "2026-11-15", "2026-11-18"]
            ),
            (
                TaskRepeat(unit: .day, interval: 3), "2027-03-12", "2027-03-15",
                ["2027-03-18", "2027-03-21", "2027-03-24"]
            ),
            (
                TaskRepeat(unit: .week, interval: 2), "2026-10-25", "2026-11-09",
                ["2026-11-22", "2026-12-06", "2026-12-20"]
            ),
            (
                TaskRepeat(unit: .week, interval: 2), today, "2026-11-20",
                ["2026-11-23", "2026-12-07", "2026-12-21"]
            ),
            (
                TaskRepeat(unit: .week, interval: 2, weekdays: [2, 6]), today, "2026-11-18",
                ["2026-11-23", "2026-11-27", "2026-12-07"]
            ),
            (
                TaskRepeat(unit: .month, interval: 3), "2027-01-31", "2027-04-30",
                ["2027-07-31", "2027-10-31", "2028-01-31"]
            ),
            (
                TaskRepeat(unit: .month, interval: 12), "2028-02-29", "2029-02-28",
                ["2030-02-28", "2031-02-28", "2032-02-29"]
            ),
        ]
        for (rule, start, movedDay, expected) in cases {
            let task = PlanTask(title: "Synthetic preserved schedule", day: start, repeatRule: rule)
            var planner = Planner()
            planner.tasks = [task]
            let now = Fixture.calendar.date(
                bySettingHour: 12, minute: 0, second: 0, of: start.date(calendar: Fixture.calendar))!
            var engine = PlannerEngine(planner: planner, now: { now }, calendar: Fixture.calendar)
            let moved = try engine.move(task.id, from: .day(start), to: .day(movedDay))
            var d = RepeatPickerDraft(task: moved, calendar: Fixture.calendar)
            XCTAssertEqual(d.commit(), .unchanged, rule.description)
            XCTAssertEqual(days(d.preview()), expected, rule.description)
            let end = try XCTUnwrap(DayKey(expected.last!))
            XCTAssertEqual(materializedDays(&engine, after: movedDay, through: end), expected, rule.description)
        }
    }

    func testChangingCadenceStartsAtTheEditedDayLikeTheEngine() throws {
        let task = PlanTask(title: "Synthetic new cadence", day: today, repeatRule: .monthly)
        var planner = Planner()
        planner.tasks = [task]
        var engine = PlannerEngine(planner: planner, now: { Fixture.now }, calendar: Fixture.calendar)
        var d = RepeatPickerDraft(task: task, calendar: Fixture.calendar)
        d.setAnchor("2026-11-30")
        d.select(.quarterly)
        let action = try XCTUnwrap(d.commit()?.action(taskID: task.id))
        _ = try engine.move(task.id, from: .day(today), to: .day("2026-11-30"))
        try engine.execute(action)
        XCTAssertEqual(try engine.task(task.id).repeatAnchor, "2026-11-30")
        let actual = materializedDays(&engine, after: "2026-11-30", through: "2027-05-30")
        XCTAssertEqual(actual, ["2027-02-28", "2027-05-30"])
        XCTAssertEqual(days(d.preview(count: 2)), actual)
    }

    func testReturningToOriginalCadenceOrCancellingRestoresThePreservedSchedule() {
        var d = RepeatPickerDraft(
            original: .weekly, anchor: "2026-11-20", seriesAnchor: today, calendar: Fixture.calendar)
        XCTAssertEqual(d.summary, "Every week on Monday")
        d.select(.monthly)
        XCTAssertEqual(days(d.preview(count: 1)), ["2026-12-20"])
        d.select(.weekly)
        XCTAssertEqual(d.commit(), .unchanged)
        XCTAssertEqual(days(d.preview(count: 1)), ["2026-11-23"])
        d.select(.monthly)
        d.revert()
        XCTAssertEqual(d.anchor, "2026-11-20", "The date field still owns the edited occurrence day")
        XCTAssertEqual(d.seriesAnchor, today)
        XCTAssertEqual(d.summary, "Every week on Monday")
        XCTAssertEqual(d.commit(), .unchanged)
        XCTAssertEqual(days(d.preview(count: 1)), ["2026-11-23"])
    }

    func testAnOccurrenceMovedBeforeTheSeriesStartDoesNotPreviewTheStartAsANewCopy() throws {
        let task = PlanTask(title: "Synthetic earlier move", day: "2026-11-30", repeatRule: .weekly)
        var planner = Planner()
        planner.tasks = [task]
        var engine = PlannerEngine(planner: planner, now: { Fixture.now }, calendar: Fixture.calendar)
        let moved = try engine.move(task.id, from: .day("2026-11-30"), to: .day(today))
        let d = RepeatPickerDraft(task: moved, calendar: Fixture.calendar)
        let actual = materializedDays(&engine, after: today, through: "2026-12-14")
        XCTAssertEqual(actual, ["2026-12-07", "2026-12-14"])
        XCTAssertEqual(days(d.preview(count: 2)), actual)
    }

    func testCompletionRelativePreviewUsesTheEditedDayNotTheSeriesAnchor() {
        var d = RepeatPickerDraft(
            original: TaskRepeat(unit: .month, fromCompletion: true), anchor: "2027-02-28",
            seriesAnchor: "2027-01-31", calendar: Fixture.calendar)
        XCTAssertEqual(d.preview(), .afterCompletion(completed: "2027-02-28", next: "2027-03-28"))
        d.setAnchor("2027-03-02")
        XCTAssertEqual(d.preview(), .afterCompletion(completed: "2027-03-02", next: "2027-04-02"))
        XCTAssertEqual(d.commit(), .unchanged)
    }

    // MARK: Quarterly

    func testQuarterlyIsEveryThreeMonthsFromTheTaskDate() {
        var d = draft(nil, anchor: "2026-11-15")
        d.select(.quarterly)
        XCTAssertEqual(d.rule, TaskRepeat(unit: .month, interval: 3))
        XCTAssertEqual(d.summary, "Every 3 months")
        XCTAssertEqual(days(d.preview()), ["2027-02-15", "2027-05-15", "2027-08-15"])
        XCTAssertEqual(d.commit(), .set(TaskRepeat(unit: .month, interval: 3)))
    }

    func testQuarterlyMonthEndClampsWithoutDrifting() {
        var d = draft(nil, anchor: "2026-11-30")
        d.select(.quarterly)
        XCTAssertEqual(days(d.preview(count: 4)), ["2027-02-28", "2027-05-30", "2027-08-30", "2027-11-30"])
    }

    // MARK: Leap day

    func testYearlyFromLeapDayLandsOnFebruary28ThenReturnsToLeapDay() {
        var d = draft(nil, anchor: "2028-02-29")
        d.select(.yearly)
        XCTAssertEqual(d.rule, TaskRepeat(unit: .month, interval: 12))
        XCTAssertEqual(d.summary, "Every year")
        XCTAssertEqual(days(d.preview(count: 4)), ["2029-02-28", "2030-02-28", "2031-02-28", "2032-02-29"])
    }

    func testMonthlyFromJanuary31ReachesLeapDay() {
        var d = draft(nil, anchor: "2028-01-31")
        d.select(.monthly)
        XCTAssertEqual(days(d.preview()), ["2028-02-29", "2028-03-31", "2028-04-30"])
    }

    func testQuarterlyIntoALeapFebruary() {
        var d = draft(nil, anchor: "2027-11-29")
        d.select(.quarterly)
        XCTAssertEqual(days(d.preview(count: 1)), ["2028-02-29"])
    }

    func testDailyAcrossLeapDay() {
        var d = draft(nil, anchor: "2028-02-28")
        d.select(.daily)
        XCTAssertEqual(days(d.preview()), ["2028-02-29", "2028-03-01", "2028-03-02"])
    }

    // MARK: DST boundaries

    func testWeeklyPreviewAnchoredOnAMidnightDSTDayStaysOnSundays() {
        var d = draft(nil, anchor: "2026-09-06", calendar: santiago)
        d.select(.weekly)
        let preview = d.preview()
        XCTAssertEqual(days(preview), ["2026-09-13", "2026-09-20", "2026-09-27"])
        XCTAssertEqual(
            RepeatPickerDraft.previewText(preview, anchor: "2026-09-06", locale: posix),
            "Next: Sun, Sep 13 · Sun, Sep 20 · Sun, Sep 27")
    }

    func testDailyPreviewCrossesTheSkippedMidnight() {
        var d = draft(nil, anchor: "2026-09-05", calendar: santiago)
        d.select(.daily)
        XCTAssertEqual(days(d.preview()), ["2026-09-06", "2026-09-07", "2026-09-08"])
        var monthly = draft(nil, anchor: "2026-08-06", calendar: santiago)
        monthly.select(.monthly)
        XCTAssertEqual(days(monthly.preview(count: 2)), ["2026-09-06", "2026-10-06"])
    }

    func testPacificSpringForwardAndFallBackKeepTheCivilDay() {
        var spring = draft(nil, anchor: "2027-03-13")
        spring.select(.daily)
        XCTAssertEqual(days(spring.preview()), ["2027-03-14", "2027-03-15", "2027-03-16"])
        var fall = draft(nil, anchor: "2026-10-25")
        fall.select(.weekly)
        XCTAssertEqual(days(fall.preview(count: 2)), ["2026-11-01", "2026-11-08"])
    }

    func testPreviewTextDoesNotDependOnTheProcessTimeZone() {
        let preview = RepeatPickerDraft.Preview.scheduled(["2026-09-06", "2027-03-14"])
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        for zone in ["America/Santiago", "America/Los_Angeles", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            XCTAssertEqual(
                RepeatPickerDraft.previewText(preview, anchor: "2026-09-01", locale: posix),
                "Next: Sun, Sep 6 · Sun, Mar 14, 2027", zone)
        }
    }

    func testPreviewMatchesEngineMaterializationAcrossDSTAndLeapDays() throws {
        let cases: [(TaskRepeat, DayKey, Int)] = [
            (.daily, "2027-03-12", 4),  // Spring forward on 2027-03-14.
            (.weekly, "2026-10-25", 3),  // Fall back on 2026-11-01.
            (TaskRepeat(unit: .week, weekdays: [1, 4]), "2027-03-10", 4),
            (.weekdaysRule, "2027-03-12", 3),
            (TaskRepeat(unit: .month, interval: 3), "2027-11-30", 2),
            (TaskRepeat(unit: .month, interval: 12), "2028-02-29", 1),
        ]
        for (rule, anchor, count) in cases {
            var d = draft(nil, anchor: anchor)
            for frequency in RepeatPickerDraft.Frequency.allCases where frequency != .none {
                var probe = draft(nil, anchor: anchor)
                probe.select(frequency)
                if frequency == .weekly { for w in rule.weekdays { probe.toggleWeekday(w) } }
                if probe.rule == rule { d = probe }
            }
            XCTAssertEqual(d.rule, rule, "No preset for \(rule)")
            let expected = days(d.preview(count: count))
            var planner = Planner()
            planner.tasks = [PlanTask(title: "Synthetic repeat", day: anchor, repeatRule: rule)]
            var engine = PlannerEngine(planner: planner, now: { Fixture.now }, calendar: Fixture.calendar)
            var day = anchor
            var made: [String] = []
            while made.count < count {
                day = day.adding(days: 1, calendar: Fixture.calendar)
                made += engine.applyRepeats(on: day).compactMap { $0.day?.raw }
            }
            XCTAssertEqual(made, expected, rule.description)
        }
    }

    func testDisplayCalendarDoesNotChangeDayArithmetic() {
        var hebrew = Calendar(identifier: .hebrew)
        hebrew.timeZone = Fixture.calendar.timeZone
        var d = draft(nil, anchor: "2026-11-30", calendar: hebrew)
        d.select(.quarterly)
        XCTAssertEqual(days(d.preview(count: 2)), ["2027-02-28", "2027-05-30"])
    }

    // MARK: Weekly days and completion-relative repeats

    func testWeeklyDaysAreToggledAndPreviewed() {
        var d = draft(nil, anchor: "2026-11-09")  // Monday
        d.select(.weekly)
        XCTAssertEqual(d.summary, "Every week on Monday", "No chosen day means the task's own weekday")
        d.toggleWeekday(2)
        d.toggleWeekday(4)
        d.toggleWeekday(4)
        d.toggleWeekday(6)
        XCTAssertEqual(d.weekdays, [2, 6])
        XCTAssertEqual(d.rule, TaskRepeat(unit: .week, weekdays: [2, 6]))
        XCTAssertEqual(d.summary, "Every week on Monday, Friday")
        XCTAssertEqual(days(d.preview()), ["2026-11-13", "2026-11-16", "2026-11-20"])
        d.toggleWeekday(9)
        XCTAssertEqual(d.weekdays, [2, 6], "Out-of-range weekdays are ignored")
    }

    func testWeekdaysAreOnlyPartOfWeeklyRules() {
        var d = draft(nil)
        d.select(.weekly)
        d.toggleWeekday(3)
        d.select(.daily)
        XCTAssertEqual(d.rule, .daily)
        d.select(.custom)
        d.setCustomUnit(.month)
        XCTAssertEqual(d.rule, TaskRepeat(unit: .month, interval: 2))
        d.setCustomUnit(.week)
        XCTAssertEqual(d.rule, TaskRepeat(unit: .week, interval: 2, weekdays: [3]))
    }

    func testWeekdaysOnlySkipsTheWeekend() {
        var d = draft(nil, anchor: "2026-11-13")  // Friday
        d.select(.weekdays)
        XCTAssertEqual(d.summary, "Every weekday")
        XCTAssertEqual(days(d.preview()), ["2026-11-16", "2026-11-17", "2026-11-18"])
    }

    func testCompletionRelativeRepeatPreviewsFromCompletion() {
        var d = draft(nil, anchor: "2026-11-09")
        d.select(.custom)
        d.typeInterval("4")
        d.setFromCompletion(true)
        XCTAssertEqual(d.rule, TaskRepeat(unit: .day, interval: 4, fromCompletion: true))
        XCTAssertEqual(d.summary, "Every 4 days after completion")
        XCTAssertEqual(d.preview(), .afterCompletion(completed: "2026-11-09", next: "2026-11-13"))
        XCTAssertEqual(
            RepeatPickerDraft.previewText(d.preview(), anchor: "2026-11-09", locale: posix),
            "If completed Mon, Nov 9, next is Fri, Nov 13")
    }

    func testPreviewTextIsAbsentWithoutASchedule() {
        XCTAssertNil(RepeatPickerDraft.previewText(.none, anchor: nil, locale: posix))
        XCTAssertNil(RepeatPickerDraft.previewText(.unavailable, anchor: nil, locale: posix))
        XCTAssertNil(RepeatPickerDraft.previewText(.scheduled([]), anchor: nil, locale: posix))
    }

    // MARK: Commit and cancel

    func testCancelRevertsTheDraft() {
        let original = TaskRepeat(unit: .week, weekdays: [2])
        var d = draft(original)
        let pristine = d
        d.select(.custom)
        d.setCustomUnit(.day)
        d.typeInterval("0")
        d.setFromCompletion(true)
        d.toggleWeekday(5)
        XCTAssertNil(d.commit())
        XCTAssertNotEqual(d, pristine)
        d.revert()
        XCTAssertEqual(d, pristine)
        XCTAssertEqual(d.frequency, .weekly)
        XCTAssertEqual(d.weekdays, [2])
        XCTAssertNil(d.visibleIssue, "Reverting also forgets the failed commit")
        XCTAssertFalse(d.attemptedCommit)
        XCTAssertFalse(d.hasChanges)
        XCTAssertEqual(d.commit(), .unchanged)
    }

    func testCancelRevertsToDoesNotRepeat() {
        var d = draft(nil)
        d.select(.yearly)
        XCTAssertTrue(d.hasChanges)
        d.revert()
        XCTAssertEqual(d.frequency, .none)
        XCTAssertEqual(d.commit(), .unchanged)
    }

    func testCommittingNeverChangesTheOriginal() {
        var d = draft(.daily)
        d.select(.monthly)
        XCTAssertEqual(d.commit(), .set(.monthly))
        XCTAssertEqual(d.original, .daily)
        d.revert()
        XCTAssertEqual(d.rule, .daily)
    }

    func testReturningToTheOriginalCadenceIsUnchanged() {
        var d = draft(.monthly)
        d.select(.daily)
        d.select(.monthly)
        XCTAssertFalse(d.hasChanges)
        XCTAssertEqual(d.commit(), .unchanged)
    }

    // MARK: Typed actions

    func testCommitsMapToTypedPlannerActions() throws {
        var planner = Planner()
        let task = PlanTask(title: "Synthetic plants", day: today, repeatRule: .weekly)
        planner.tasks = [task]
        var engine = PlannerEngine(planner: planner, now: { Fixture.now }, calendar: Fixture.calendar)

        XCTAssertNil(RepeatPickerDraft.Commit.unchanged.action(taskID: task.id))
        XCTAssertNil(RepeatPickerDraft.Commit.unchanged.transportText)

        var d = draft(.weekly, anchor: today)
        d.select(.quarterly)
        let quarterly = try XCTUnwrap(d.commit())
        XCTAssertEqual(quarterly.transportText, "every 3 months")
        guard case .update(let id, let edit)? = quarterly.action(taskID: task.id) else {
            return XCTFail("Expected an update action")
        }
        XCTAssertEqual(id, task.id)
        XCTAssertEqual(edit.repeatRule, "every 3 months")
        XCTAssertNil(edit.title)
        try engine.execute(.update(id, edit))
        XCTAssertEqual(try engine.task(task.id).repeatRule, TaskRepeat(unit: .month, interval: 3))

        var clear = draft(TaskRepeat(unit: .month, interval: 3), anchor: today)
        clear.select(.none)
        let cleared = try XCTUnwrap(clear.commit())
        XCTAssertEqual(cleared.transportText, "none")
        guard case .endRepeat(let endID)? = cleared.action(taskID: task.id) else {
            return XCTFail("Expected an end-repeat action")
        }
        try engine.execute(.endRepeat(endID))
        XCTAssertNil(try engine.task(task.id).repeatRule)
    }

    func testCommitCanBeMergedIntoAnExistingEdit() {
        var edit = TaskEdit()
        edit.title = "Synthetic title"
        RepeatPickerDraft.Commit.set(.daily).apply(to: &edit)
        XCTAssertEqual(edit.repeatRule, "every day")
        XCTAssertEqual(edit.title, "Synthetic title")
        RepeatPickerDraft.Commit.unchanged.apply(to: &edit)
        XCTAssertEqual(edit.repeatRule, "every day", "Unchanged leaves the field alone")
        RepeatPickerDraft.Commit.cleared.apply(to: &edit)
        XCTAssertEqual(edit.repeatRule, "none")
    }

    // MARK: Accessibility and compact layout

    func testEveryControlHasASpokenLabel() {
        XCTAssertEqual(RepeatPickerDraft.weekdayNames.count, 7)
        XCTAssertEqual(RepeatPickerDraft.weekdayNames[1], "Monday")
        XCTAssertEqual(RepeatPickerDraft.weekdayShortNames, ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"])
        for frequency in RepeatPickerDraft.Frequency.allCases { XCTAssertFalse(frequency.title.isEmpty) }
        for unit in RepeatPickerDraft.CustomUnit.allCases { XCTAssertFalse(unit.title(plural: true).isEmpty) }
        XCTAssertEqual(RepeatPickerDraft.CustomUnit.week.title(plural: false), "week")
        XCTAssertEqual(RepeatPickerDraft.CustomUnit.month.title(plural: true), "months")
    }

    func testCompactLayoutFitsTinyWindows() {
        XCTAssertLessThanOrEqual(RepeatPickerLayout.compactMinimumWidth, 240)
        XCTAssertGreaterThanOrEqual(RepeatPickerLayout.weekdayTarget, ThemeTokens.minimumTarget)
        XCTAssertEqual(
            RepeatPickerLayout.compactMinimumWidth,
            7 * RepeatPickerLayout.weekdayTarget + 6 * RepeatPickerLayout.weekdaySpacing)
        XCTAssertLessThan(RepeatPickerLayout.intervalFieldWidth, RepeatPickerLayout.compactMinimumWidth)
    }
}
