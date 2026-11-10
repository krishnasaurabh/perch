import Foundation
import XCTest
import PlannerCore
@testable import PerchUI

final class ReminderScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private func task(_ seconds: Double = 600) -> PlanTask {
        PlanTask(
            title: "Synthetic reminder", day: DayKey(now, calendar: calendar), remindAt: now.addingTimeInterval(seconds)
        )
    }
    private func plan(
        _ tasks: [PlanTask], at: Date? = nil, pending: [ScheduledReminder] = [],
        delivered: Set<String> = [], records: [String: ReminderRecord] = [:], authorized: Bool = true
    ) -> ReminderSchedule.Plan {
        var planner = Planner(); planner.tasks = tasks
        return ReminderSchedule.reconcile(
            planner: planner, now: at ?? now, calendar: calendar,
            pending: pending, delivered: delivered, records: records, authorized: authorized)
    }
    func testFutureRequestExistsBeforeDueAndDoesNotDependOnPresentationWindow() {
        let t = task()
        let request = plan([t]).requests.first!
        XCTAssertEqual(request.date, t.remindAt)
        XCTAssertEqual(plan([t], pending: [request]).requests, [request])
        XCTAssertTrue(plan([t], pending: [request]).remove.isEmpty)
    }
    func testIdentityStableAcrossTitleEditsButChangesForSnooze() {
        var t = task(); let original = ScheduledReminder(task: t)
        t.title = "Edited fixture"
        let edited = plan([t], pending: [original])
        XCTAssertEqual(edited.requests[0].id, original.id)
        XCTAssertNotEqual(edited.requests[0], original)
        t.remindAt = now.addingTimeInterval(900)
        let snoozed = plan([t], pending: [original])
        XCTAssertNotEqual(snoozed.requests[0].id, original.id)
        XCTAssertEqual(snoozed.remove, [original.id])
    }
    func testCompletionDeletionInboxAndClearedReminderCancel() {
        let t = task(); let pending = [ScheduledReminder(task: t)]
        var completed = t; completed.done = true
        var inbox = t; inbox.day = nil
        var cleared = t; cleared.remindAt = nil
        for tasks in [[], [completed], [inbox], [cleared]] {
            let result = plan(tasks, pending: pending)
            XCTAssertTrue(result.requests.isEmpty)
            XCTAssertEqual(result.remove, [pending[0].id])
        }
    }
    func testDeniedPermissionCancelsPendingWithoutConsumingFutureReminder() {
        let t = task(); let pending = ScheduledReminder(task: t)
        let denied = plan([t], pending: [pending], authorized: false)
        XCTAssertTrue(denied.requests.isEmpty)
        XCTAssertEqual(denied.remove, [pending.id])
        XCTAssertNil(denied.records[pending.id])
        XCTAssertEqual(plan([t], records: denied.records).requests, [pending])
    }
    func testSleepPastDueRecordsMissedWithoutCatchupNoise() {
        let t = task(); let request = ScheduledReminder(task: t)
        let result = plan([t], at: now.addingTimeInterval(720), pending: [request])
        XCTAssertTrue(result.requests.isEmpty)
        XCTAssertEqual(result.records[request.id]?.state, .missed)
        XCTAssertEqual(result.remove, [request.id])
    }
    func testPendingAtExactDueGetsGraceButIsNeverReplayed() {
        let t = task(); let request = ScheduledReminder(task: t)
        XCTAssertEqual(plan([t], at: request.date, pending: [request]).requests, [request])
        XCTAssertTrue(plan([t], at: request.date).requests.isEmpty)
        XCTAssertTrue(plan([t], at: request.date.addingTimeInterval(60), pending: [request]).requests.isEmpty)
    }
    func testDeliveredWhileAppQuitIsRememberedAcrossLaunchAndClockRewind() throws {
        let t = task(); let request = ScheduledReminder(task: t)
        let delivered = plan([t], at: now.addingTimeInterval(720), delivered: [request.id])
        XCTAssertEqual(delivered.records[request.id]?.state, .delivered)
        let persisted = try JSONDecoder().decode(
            [String: ReminderRecord].self,
            from: JSONEncoder().encode(delivered.records))
        XCTAssertTrue(plan([t], records: persisted).requests.isEmpty)
    }
    func testMissedStatusSurvivesClockRewind() {
        let t = task(); let request = ScheduledReminder(task: t)
        let missed = plan([t], at: now.addingTimeInterval(720))
        XCTAssertEqual(missed.records[request.id]?.state, .missed)
        XCTAssertTrue(plan([t], records: missed.records).requests.isEmpty)
    }
    func testCapDeterministicallyKeepsNearestRequestsAndRenewsFreedSlots() {
        let tasks = (1...70).map { task(Double($0 * 60)) }
        let first = plan(tasks)
        XCTAssertEqual(first.requests.count, 60)
        XCTAssertEqual(first.requests.last?.date, tasks[59].remindAt)
        let next = plan(Array(tasks.dropFirst()), pending: first.requests)
        XCTAssertEqual(next.requests.count, 60)
        XCTAssertEqual(next.requests.last?.date, tasks[60].remindAt)
        XCTAssertEqual(next.remove, [ScheduledReminder(task: tasks[0]).id])
    }
    func testHorizonRenewsAndDoesNotCancelUnrelatedNotificationIDs() {
        let distant = task(20 * 86_400)
        let unrelated = ScheduledReminder(id: "focus-fixture", date: now, title: "Timer", body: "")
        XCTAssertTrue(plan([distant], pending: [unrelated]).requests.isEmpty)
        XCTAssertTrue(plan([distant], pending: [unrelated]).remove.isEmpty)
        XCTAssertEqual(plan([distant], at: now.addingTimeInterval(7 * 86_400)).requests.count, 1)
    }
    func testKnownDeliveryWinsEvenIfTaskWasCompleted() {
        var t = task(); let request = ScheduledReminder(task: t); t.done = true
        let result = plan([t], pending: [request], delivered: [request.id])
        XCTAssertEqual(result.records[request.id]?.state, .delivered)
        XCTAssertEqual(result.remove, [request.id])
    }
    func testRecordsAreBoundedByRetention() {
        let old = ReminderRecord(date: now.addingTimeInterval(-31 * 86_400), state: .delivered)
        XCTAssertTrue(plan([], records: ["old": old]).records.isEmpty)
    }
    func testHorizonUsesCivilDaysAcrossDSTAndNonHourTransitions() {
        for (zone, day, expectedHours) in [
            ("America/Los_Angeles", "2026-03-07", 335.0),
            ("America/Los_Angeles", "2026-10-31", 337.0),
            ("Australia/Lord_Howe", "2026-10-03", 335.5),
        ] {
            var cal = calendar; cal.timeZone = TimeZone(identifier: zone)!
            let start = DayKey(day)!.start(resetHour: 4, calendar: cal)
            let end = DayKey(day)!.adding(days: ReminderSchedule.horizonDays, calendar: cal).start(
                resetHour: 4, calendar: cal)
            XCTAssertEqual(end.timeIntervalSince(start) / 3600, expectedHours)
            XCTAssertEqual(ReminderSchedule.days(today: DayKey(day)!, calendar: cal).count, 14)
        }
    }
}
