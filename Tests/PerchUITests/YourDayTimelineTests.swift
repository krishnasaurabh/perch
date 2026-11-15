import Foundation
import PlannerCore
import XCTest
@testable import PerchUI

final class YourDayTimelineTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private let day: DayKey = "2026-11-13"
    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: hour, minute: minute))!
    }
    private func task(_ hour: Int, _ minute: Int = 0, minutes: Int = 30) -> PlanTask {
        PlanTask(title: "Write the notes", day: day, createdAt: date(8), minutes: minutes, startAt: date(hour, minute))
    }
    private func build(
        _ tasks: [PlanTask], meetings: [YourDayTimeline.Meeting] = [], now: Date? = nil,
        preview: YourDayTimeline.Preview? = nil, focus: FocusSession? = nil
    ) -> YourDayTimeline {
        YourDayTimeline(
            tasks: tasks, meetings: meetings, day: day, now: now ?? date(9),
            calendar: calendar, resetHour: 4, defaultMinutes: 45, focus: focus, preview: preview)
    }

    func testOnlyTodayWithAnIndependentStartTimeAppears() {
        var reminderOnly = task(10); reminderOnly.startAt = nil; reminderOnly.remindAt = date(10)
        var yesterday = task(11); yesterday.day = day.adding(days: -1)
        var wrongStartDay = task(12); wrongStartDay.startAt = date(12).addingTimeInterval(86400)
        let scheduled = task(13)
        let value = build([reminderOnly, yesterday, scheduled, wrongStartDay])
        XCTAssertEqual(value.items.filter { $0.taskID != nil }.map(\.taskID), [scheduled.id])
    }

    func testChronologicalOrderingAndEqualTimeTieBreakAreStable() {
        let early = task(10), late = task(14)
        let meeting = YourDayTimeline.Meeting(id: "meeting", title: "Review", start: date(10), end: date(11))
        let value = build([late, early], meetings: [meeting])
        let occupied = value.items.filter { $0.kind != .gap }
        XCTAssertEqual(occupied.map(\.start), [date(10), date(10), date(14)])
        XCTAssertEqual(occupied[0].taskID, early.id)
        XCTAssertEqual(build([late, early], meetings: [meeting]).items, value.items)
    }

    func testGapsUseTheUnionOfOverlappingIntervals() {
        let value = build([task(10, minutes: 120), task(10, 30, minutes: 15), task(12, 15)], now: date(10))
        XCTAssertEqual(value.items.filter { $0.kind == .gap }.first?.start, date(12))
        XCTAssertEqual(value.items.filter { $0.kind == .gap }.first?.end, date(12, 15))
        XCTAssertEqual(value.items.filter { $0.overlaps }.count, 2)
    }

    func testTouchingBlocksDoNotOverlapAndShortGapsAreOmitted() {
        let value = build([task(10), task(10, 30), task(11, 10)], now: date(10))
        XCTAssertTrue(value.items.allSatisfy { !$0.overlaps })
        XCTAssertFalse(value.items.contains { $0.kind == .gap && $0.start == date(11) })
    }

    func testPastGapsAreNotOfferedAndEmptyDayIsOpenFromNow() {
        let value = build([task(8), task(10)], now: date(9, 15))
        XCTAssertEqual(value.items.first(where: { $0.kind == .gap })?.start, date(9, 15))
        let empty = build([], now: date(9))
        XCTAssertEqual(empty.items.count, 1)
        XCTAssertEqual(empty.items[0].start, date(9))
        XCTAssertEqual(empty.items[0].end, day.adding(days: 1).start(resetHour: 4, calendar: calendar))
    }

    func testDoneAndCarriedArePreservedAndSummaryCountsOpenBlocks() {
        var done = task(9); done.done = true
        var carried = task(10); carried.carriedFrom = day.adding(days: -1)
        let value = build([done, carried])
        XCTAssertTrue(value.items.first(where: { $0.taskID == done.id })!.done)
        XCTAssertTrue(value.items.first(where: { $0.taskID == carried.id })!.carried)
        XCTAssertEqual(value.blockCount, 1)
    }

    func testRunningIntervalComesFromTheFocusClockNotThePlannedStart() {
        let scheduled = task(11)
        let focus = FocusSession(taskID: scheduled.id, limit: 45 * 60, now: date(10))
        let row = build([scheduled], now: date(10, 15), focus: focus).items.first { $0.taskID == scheduled.id }!
        XCTAssertTrue(row.running)
        XCTAssertEqual(row.start, date(10))
        XCTAssertEqual(row.end, date(10, 45))
    }

    func testUnscheduledRunningTaskIsStillExcluded() {
        var unscheduled = task(10); unscheduled.startAt = nil
        let focus = FocusSession(taskID: unscheduled.id, limit: 1800, now: date(10))
        XCTAssertFalse(build([unscheduled], focus: focus).items.contains { $0.taskID != nil })
    }

    func testPreviewIsOrderedAndDoesNotIncreaseSummary() {
        let preview = YourDayTimeline.Preview(start: date(13, 30), minutes: 20)
        let value = build([task(14)], preview: preview)
        let row = value.items.first { $0.kind == .preview }!
        XCTAssertEqual(row.start, date(13, 30))
        XCTAssertEqual(row.end, date(13, 50))
        XCTAssertEqual(value.blockCount, 1)
        XCTAssertFalse(
            build([], preview: .init(start: date(13).addingTimeInterval(86400), minutes: 20))
                .items.contains { $0.kind == .preview })
    }

    func testAllDayMultidayAndInvalidMeetingsAreExcluded() {
        let meetings = [
            YourDayTimeline.Meeting(id: "all", title: "All day", start: date(0), end: date(23), allDay: true),
            YourDayTimeline.Meeting(
                id: "multi", title: "Trip", start: date(0).addingTimeInterval(-86400), end: date(23)),
            YourDayTimeline.Meeting(id: "bad", title: "Invalid", start: date(12), end: date(11)),
            YourDayTimeline.Meeting(id: "valid", title: "Review", start: date(14), end: date(15)),
        ]
        let value = build([], meetings: meetings)
        XCTAssertEqual(value.meetingCount, 1)
        XCTAssertEqual(value.items.filter { $0.kind == .meeting }.map(\.id), ["meeting:valid"])
    }

    func testMissingDurationUsesPreferenceAndQuarterHourDropSnaps() {
        var scheduled = task(10); scheduled.minutes = nil
        let value = build([scheduled])
        XCTAssertEqual(value.items.first { $0.taskID == scheduled.id }!.minutes, 45)
        XCTAssertEqual(value.snapped(date(13, 7), calendar: calendar), date(13))
        XCTAssertEqual(value.snapped(date(13, 8), calendar: calendar), date(13, 15))
        XCTAssertEqual(
            value.snapped(date(23, 59).addingTimeInterval(5 * 3600), calendar: calendar),
            value.end.addingTimeInterval(-15 * 60))
    }

    func testStopwatchEndDoesNotDriftWithEveryClockTick() {
        let scheduled = task(10)
        let focus = FocusSession(taskID: scheduled.id, limit: nil, now: date(10))
        let first = build([scheduled], now: date(10, 15), focus: focus)
        let later = build([scheduled], now: date(10, 20), focus: focus)
        XCTAssertEqual(first.items.first { $0.taskID == scheduled.id }?.end, date(10, 30))
        XCTAssertEqual(later.items.first { $0.taskID == scheduled.id }?.end, date(10, 30))
    }

    func testDropSlotMapsGapPositionAndBlockEdgesThenSnaps() {
        let scheduled = task(10)
        let value = build([scheduled], now: date(9))
        let gap = value.items.first { $0.kind == .gap }!
        XCTAssertEqual(value.dropTime(in: gap, fraction: 0.52, calendar: calendar), date(9, 30))
        let block = value.items.first { $0.taskID == scheduled.id }!
        XCTAssertEqual(value.dropTime(in: block, fraction: 0.1, calendar: calendar), date(10))
        XCTAssertEqual(value.dropTime(in: block, fraction: 0.9, calendar: calendar), date(10, 30))
        XCTAssertEqual(value.dropTime(in: gap, fraction: .nan, calendar: calendar), date(9))
    }

    func testPreviewParticipatesInOverlapAndNextMorningBelongsToLogicalDay() {
        let value = build([task(10)], preview: .init(start: date(10, 15), minutes: 20))
        XCTAssertEqual(value.items.filter(\.overlaps).count, 2)
        let nextMorning = date(2).addingTimeInterval(86400)
        let nextMeeting = YourDayTimeline.Meeting(
            id: "next-morning", title: "Review", start: nextMorning,
            end: nextMorning.addingTimeInterval(1800))
        let outside = YourDayTimeline.Meeting(
            id: "next-day", title: "Later", start: date(6).addingTimeInterval(86400),
            end: date(7).addingTimeInterval(86400))
        let schedule = build([], meetings: [nextMeeting, outside])
        XCTAssertEqual(schedule.meetingCount, 1)
        XCTAssertTrue(schedule.items.contains { $0.id == "meeting:next-morning" })
    }

    func testMultilinePreviewMatchesTheFirstScheduledTaskFromSubmission() throws {
        let inputs = [
            "Read today at 10am\nWrite today at 1pm for 20 min",
            "  • Read today at 10am\r\n\r\n2. Write today at 1pm for 20 min\r\nPlan today at 2pm for 45 min",
            "Write today at 1pm for 20 min\nPlan today at 2pm for 45 min",
        ]
        for text in inputs {
            var engine = PlannerEngine(planner: Planner(), now: { self.date(9) }, calendar: calendar)
            let capture = TaskCapture(now: date(9), resetHour: 4, calendar: calendar)
            let preview = try XCTUnwrap(
                YourDayTimeline.capturePreview(text, using: capture, language: .english, day: day))
            let added = try engine.addTasks([text], on: .day(day), language: .english)
            let scheduled = try XCTUnwrap(added.first { $0.startAt != nil && $0.day == day })
            XCTAssertEqual(preview.start, scheduled.startAt, text)
            XCTAssertEqual(preview.minutes, scheduled.minutes, text)
            XCTAssertEqual(preview.start, date(13))
            XCTAssertEqual(preview.minutes, 20)
        }
    }

    func testPreviewNeverBorrowsDurationFromAnotherLine() throws {
        let text = "Read today at 10am\nWrite for 20 min"
        let capture = TaskCapture(now: date(9), resetHour: 4, calendar: calendar)
        XCTAssertNil(YourDayTimeline.capturePreview(text, using: capture, language: .english, day: day))
        var engine = PlannerEngine(planner: Planner(), now: { self.date(9) }, calendar: calendar)
        XCTAssertTrue(try engine.addTasks([text]).allSatisfy { $0.startAt == nil })
    }

    func testCapturePreviewSkipsInboxAndOtherDays() throws {
        let capture = TaskCapture(now: date(9), resetHour: 4, calendar: calendar)
        let text = "Read #inbox today at 10am for 30 min\nPlan tomorrow at 11am for 45 min"
        XCTAssertNil(YourDayTimeline.capturePreview(text, using: capture, language: .english, day: day))
        let preview = try XCTUnwrap(
            YourDayTimeline.capturePreview(
                text + "\nWrite today at 1pm for 20 min", using: capture, language: .english, day: day))
        XCTAssertEqual(preview.start, date(13))
        XCTAssertEqual(preview.minutes, 20)
    }

    func testEmptyLateDayHasASnappedDropSlotWithoutAShortGapPill() throws {
        let now = date(3, 50).addingTimeInterval(86400)
        var unscheduled = task(10); unscheduled.startAt = nil
        let value = build([unscheduled], now: now)
        XCTAssertTrue(value.items.isEmpty)
        let slot = try XCTUnwrap(value.emptyDropTime(at: now, calendar: calendar))
        XCTAssertEqual(slot, date(3, 45).addingTimeInterval(86400))
        XCTAssertEqual(DayKey(slot, resetHour: 4, calendar: calendar), day)
        XCTAssertNil(build([unscheduled]).emptyDropTime(at: date(9), calendar: calendar))
    }

    func testLateDaySnapshotKeepsAnUnscheduledTaskAndNoVisibleGap() throws {
        let fixture = try PlannerPreviewScenarios.make("today-late")
        XCTAssertFalse(fixture.planner.tasks.isEmpty)
        XCTAssertTrue(fixture.planner.tasks.allSatisfy { $0.startAt == nil })
        let value = YourDayTimeline(
            tasks: fixture.planner.tasks, meetings: [], day: fixture.day, now: fixture.now,
            calendar: PlannerPreviewScenarios.calendar, resetHour: fixture.planner.preferences.resetHour,
            defaultMinutes: fixture.planner.preferences.defaultFocusMinutes)
        XCTAssertEqual(value.end.timeIntervalSince(fixture.now), 10 * 60)
        XCTAssertTrue(value.items.isEmpty)
        XCTAssertNotNil(value.emptyDropTime(at: fixture.now, calendar: PlannerPreviewScenarios.calendar))
    }

    func testDSTDayBoundsAndWallTimeSnap() {
        var local = calendar; local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let spring: DayKey = "2026-03-08"
        let start = spring.start(resetHour: 0, calendar: local)
        let value = YourDayTimeline(
            tasks: [], meetings: [], day: spring, now: start,
            calendar: local, resetHour: 0, defaultMinutes: 25)
        XCTAssertEqual(value.end.timeIntervalSince(value.start), 23 * 3600)
        let input = local.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 3, minute: 8))!
        let snapped = value.snapped(input, calendar: local)
        XCTAssertEqual(local.component(.hour, from: snapped), 3)
        XCTAssertEqual(local.component(.minute, from: snapped), 15)
    }
}
