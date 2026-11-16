import Foundation
import PlannerCore
import XCTest
@testable import PerchUI

/// Exercise the same persisted command path used by Settings, not a second preference model.
final class CalendarReminderRuntimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func exercise(_ body: (PlannerCommandPipeline, PlannerFile) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(url: root.appendingPathComponent("planner.json"))
        let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { self.now })
        _ = try pipeline.execute(
            .addTasks(["Synthetic reminder"], day: nil, literal: true, agentID: nil), origin: .user)
        try body(pipeline, file)
    }

    func testStoredMeetingVisibilityChangesEmittedActivitiesWithoutRestart() throws {
        try exercise { pipeline, file in
            let event = NotchActivityTimeline.Event(id: "meeting", title: "Review", start: now)
            func activities() throws -> [NotchActivity] {
                NotchActivityTimeline(planner: try file.load(), events: [event]).activities
            }
            XCTAssertEqual(try activities().count, 2, "Default keeps both meeting phases")
            _ = try pipeline.perform(origin: .user) { try $0.updatePreference(.showCalendarMeetings(false)) }
            XCTAssertTrue(try activities().isEmpty)
            _ = try pipeline.perform(origin: .user) { try $0.updatePreference(.showCalendarMeetings(true)) }
            XCTAssertEqual(try activities().count, 2)
        }
    }

    func testStoredMeetingHeadsUpChangesEligibilityAndDeadlineWithoutRestart() throws {
        try exercise { pipeline, file in
            let start = now.addingTimeInterval(480)
            let event = NotchActivityTimeline.Event(id: "meeting", title: "Review", start: start)
            func timeline() throws -> NotchActivityTimeline {
                NotchActivityTimeline(planner: try file.load(), events: [event])
            }
            XCTAssertNil(try timeline().showing(at: now), "Default heads-up is five minutes")
            XCTAssertEqual(try timeline().nextChange(after: now), start.addingTimeInterval(-300))
            _ = try pipeline.perform(origin: .user) { try $0.updatePreference(.meetingHeadsUp(.tenMinutes)) }
            XCTAssertEqual(try timeline().showing(at: now)?.kind, .eventSoon)
            XCTAssertEqual(try timeline().showing(at: now)?.end, start)
            XCTAssertEqual(try timeline().nextChange(after: now), start)
            _ = try pipeline.perform(origin: .user) { try $0.updatePreference(.meetingHeadsUp(.off)) }
            XCTAssertNil(try timeline().showing(at: now))
            XCTAssertEqual(try timeline().showing(at: start)?.kind, .eventNow)
        }
    }

    func testStoredNotifyWhenClosedCancelsAndRearmsOnlyFutureOwnedRequests() throws {
        try exercise { pipeline, file in
            let id = try XCTUnwrap(file.load().tasks.first?.id)
            _ = try pipeline.perform(origin: .user) { try $0.snooze(id, minutes: 10) }
            func plan(_ pending: [ScheduledReminder]) throws -> ReminderSchedule.Plan {
                ReminderSchedule.reconcile(
                    planner: try file.load(), now: now, pending: pending, delivered: [], records: [:], authorized: true)
            }
            let request = try XCTUnwrap(plan([]).requests.first)
            let unrelated = ScheduledReminder(id: "timer", date: now, title: "Timer", body: "")
            _ = try pipeline.perform(origin: .user) { try $0.updatePreference(.notifyWhenClosed(false)) }
            let disabled = try plan([request, unrelated])
            XCTAssertTrue(disabled.requests.isEmpty)
            XCTAssertEqual(disabled.remove, [request.id])
            XCTAssertNil(disabled.records[request.id], "Opt-out must not consume the future occurrence")
            XCTAssertEqual(try file.load().tasks.first?.remindAt, request.date)
            _ = try pipeline.perform(origin: .user) { try $0.updatePreference(.notifyWhenClosed(true)) }
            XCTAssertEqual(try plan([]).requests, [request])
        }
    }

    func testStoredPersistentReminderControlsRetentionWithoutRestart() throws {
        try exercise { pipeline, file in
            let id = try XCTUnwrap(file.load().tasks.first?.id)
            _ = try pipeline.perform(origin: .user) { try $0.snooze(id, minutes: 1) }
            let due = now.addingTimeInterval(60), later = due.addingTimeInterval(3600)
            func timeline() throws -> NotchActivityTimeline { NotchActivityTimeline(planner: try file.load()) }
            let reminder = try XCTUnwrap(timeline().showing(at: later))
            XCTAssertEqual(reminder.taskID, id, "Default retains the reminder until answered")
            XCTAssertNil(try timeline().showing(at: later, dismissed: [reminder.id]))
            XCTAssertNil(try timeline().nextChange(after: later), "Retention does not need an expiry timer")
            let task = try XCTUnwrap(file.load().tasks.first)
            let records = [ScheduledReminder(task: task).id: ReminderRecord(date: due, state: .missed)]
            XCTAssertEqual(
                NotchReminderPresentation.missedTask(in: try file.load(), records: records, now: later)?.id, id)
            _ = try pipeline.perform(origin: .user) { try $0.updatePreference(.persistentReminders(false)) }
            XCTAssertNil(NotchReminderPresentation.missedTask(in: try file.load(), records: records, now: later))
            XCTAssertNotNil(try timeline().showing(at: due))
            XCTAssertNil(try timeline().showing(at: due.addingTimeInterval(60)))
            _ = try pipeline.perform(origin: .user) { try $0.updatePreference(.persistentReminders(true)) }
            XCTAssertEqual(try timeline().showing(at: later)?.taskID, id)
            _ = try pipeline.execute(.complete(id), origin: .user)
            XCTAssertNil(try timeline().showing(at: later))
        }
    }

    func testStoredSnoozeControlsCommandDeadlineWithoutRestartAndExplicitOverrideStillWorks() throws {
        try exercise { pipeline, file in
            let id = try XCTUnwrap(file.load().tasks.first?.id)
            _ = try pipeline.perform(origin: .user) { try $0.snooze(id) }
            XCTAssertEqual(try file.load().tasks.first?.remindAt, now.addingTimeInterval(600))
            for value in SnoozeDuration.allCases {
                _ = try pipeline.perform(origin: .user) { try $0.updatePreference(.snoozeMinutes(value)) }
                _ = try pipeline.perform(origin: .user) { try $0.snooze(id) }
                XCTAssertEqual(
                    try file.load().tasks.first?.remindAt, now.addingTimeInterval(Double(value.rawValue * 60)))
            }
            _ = try pipeline.perform(origin: .user) { try $0.snooze(id, minutes: 2) }
            XCTAssertEqual(try file.load().tasks.first?.remindAt, now.addingTimeInterval(120))
        }
    }
}
