import Foundation
@testable import PlannerCore
import XCTest
@testable import PerchUI

final class TaskDetailsDraftTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2028-02-28T18:00:00Z")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var today: DayKey { DayKey(now, calendar: calendar) }
    private var task: PlanTask { PlanTask(title: "Draft a checklist", day: today, createdAt: now) }

    private func withPipeline(
        task: PlanTask? = nil, projects: [TaskProject] = [], calendar: Calendar? = nil,
        _ body: (PlannerCommandPipeline, PlannerFile, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
        var planner = Planner(); planner.preferences.resetHour = 0
        planner.tasks = [task ?? self.task]; planner.projects = projects
        try file.save(planner)
        let pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { self.now }, calendar: calendar ?? self.calendar)
        try body(pipeline, file, directory)
    }

    /// Includes nested snapshots, sidecars and timestamps: even identical-byte rewrites are detectable.
    private func snapshot(_ directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let entries = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])!
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            if values.isRegularFile == true {
                result[url.path] =
                    "\(values.contentModificationDate!.timeIntervalSince1970):\(try Data(contentsOf: url).base64EncodedString())"
            }
        }
        return result
    }

    func testDraftValidationAndIncompleteSelectionsNeverWrite() throws {
        try withPipeline { _, file, directory in
            let original = try snapshot(directory)
            var draft = TaskDetailsDraft(task: try file.load().tasks[0])
            draft.title = "Uncommitted title"; draft.notes = "Uncommitted notes"
            draft.day = nil; draft.hasReminder = true; draft.remindAt = nil
            draft.hasDeadline = true; draft.deadline = nil
            draft.recurrence.frequency = .weekly; draft.recurrence.selectWeekdays = true
            let errors = draft.errors(today: today, now: now, projects: [])
            XCTAssertNotNil(errors[.day]); XCTAssertNotNil(errors[.reminder])
            XCTAssertNotNil(errors[.deadline]); XCTAssertNotNil(errors[.recurrence])
            XCTAssertEqual(try snapshot(directory), original)
            XCTAssertEqual(try file.load().tasks[0].title, task.title)
        }
    }

    func testInvalidValuesAndExplicitNoneAreDistinct() throws {
        for value in ["", "0", "-1", "1000", "one", "1.5"] {
            var repeatDraft = TaskRecurrenceDraft(.daily)
            repeatDraft.frequency = .custom; repeatDraft.interval = value
            XCTAssertThrowsError(try repeatDraft.rule(), value)
        }
        XCTAssertNil(try TaskRecurrenceDraft().rule())
        var draft = TaskDetailsDraft(task: task)
        draft.title = " \n "; draft.projectID = UUID(); draft.minutes = 721
        let errors = draft.errors(today: today, now: now, projects: [])
        XCTAssertNotNil(errors[.title]); XCTAssertNotNil(errors[.project]); XCTAssertNotNil(errors[.minutes])
    }

    func testAllSupportedRulesRoundTripWithoutTextParsingAmbiguity() throws {
        for rule in [
            TaskRepeat.daily, .weekdaysRule, .weekly, .monthly,
            TaskRepeat(unit: .month, interval: 3), TaskRepeat(unit: .month, interval: 12),
            TaskRepeat(unit: .week, interval: 2, weekdays: [2, 4], fromCompletion: true),
            TaskRepeat(unit: .day, interval: 999, fromCompletion: true),
        ] {
            XCTAssertEqual(try TaskRecurrenceDraft(rule).rule(), rule)
        }
    }

    func testQuarterlyLeapAndCompletionBasedRecurrence() throws {
        var repeatDraft = TaskRecurrenceDraft(); repeatDraft.frequency = .quarterly
        let quarterly = try XCTUnwrap(repeatDraft.rule())
        XCTAssertEqual(quarterly.next(after: "2028-01-31", completed: "2028-02-01", calendar: calendar), "2028-04-30")
        repeatDraft.frequency = .yearly
        let yearly = try XCTUnwrap(repeatDraft.rule())
        XCTAssertEqual(yearly.next(after: "2028-02-29", completed: "2028-03-01", calendar: calendar), "2029-02-28")
        repeatDraft.frequency = .monthly; repeatDraft.fromCompletion = true
        XCTAssertEqual(
            try repeatDraft.rule()?.next(after: "2028-01-31", completed: "2028-02-29", calendar: calendar), "2028-03-29"
        )
    }

    func testAtomicSaveAndUndoAcrossAllDetailFields() throws {
        let project = TaskProject(name: "Checklists")
        try withPipeline(projects: [project]) { pipeline, file, _ in
            let original = try file.load().tasks[0]
            var draft = TaskDetailsDraft(task: original)
            draft.title = "Review checklist"; draft.notes = "Review each item"
            draft.day = today.adding(days: 1, calendar: calendar)
            draft.priority = .high; draft.projectID = project.id; draft.minutes = 30
            draft.hasDeadline = true; draft.deadline = today.adding(days: 3, calendar: calendar)
            draft.recurrence.frequency = .quarterly
            draft.steps = [Subtask(title: "Verify input")]
            try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
            let saved = try file.load().tasks[0]
            XCTAssertEqual(saved.title, draft.title); XCTAssertEqual(saved.day, draft.day)
            XCTAssertEqual(saved.repeatRule, TaskRepeat(unit: .month, interval: 3))
            XCTAssertEqual(saved.projectID, project.id); XCTAssertEqual(saved.priority, .high)
            XCTAssertEqual(saved.deadline, draft.deadline); XCTAssertEqual(saved.minutes, 30)
            XCTAssertEqual(saved.steps, draft.steps); XCTAssertEqual(saved.notes, draft.notes)
            _ = try pipeline.undo()
            let restored = try file.load().tasks[0]
            XCTAssertEqual(restored.title, original.title); XCTAssertEqual(restored.day, original.day)
            XCTAssertNil(restored.repeatRule); XCTAssertNil(restored.projectID)
            XCTAssertEqual(restored.steps, original.steps); XCTAssertNil(restored.minutes)
        }
    }

    func testRejectedLateEditRollsBackEarlierScheduleAndRepeatActions() throws {
        var done = task; done.done = true; done.completedAt = now
        try withPipeline(task: done) { pipeline, file, directory in
            var draft = TaskDetailsDraft(task: done)
            draft.recurrence.frequency = .quarterly
            draft.minutes = 25  // Rejected by the typed edit after recurrence was staged.
            let before = try snapshot(directory)
            XCTAssertThrowsError(try pipeline.perform(origin: .user) { try draft.apply(using: $0) })
            XCTAssertEqual(try file.load().tasks[0], done)
            XCTAssertEqual(try snapshot(directory), before)
            XCTAssertFalse(pipeline.canUndo)
        }
    }

    func testPastDayTaskCannotBeRenamedRescheduledOrDeletedThroughDraft() throws {
        var past = task; past.day = today.adding(days: -1, calendar: calendar)
        try withPipeline(task: past) { pipeline, file, directory in
            var draft = TaskDetailsDraft(task: past); draft.title = "Changed"; draft.day = today
            let before = try snapshot(directory)
            XCTAssertThrowsError(try pipeline.perform(origin: .user) { try draft.apply(using: $0) })
            XCTAssertEqual(try snapshot(directory), before)
            XCTAssertEqual(try file.load().tasks[0], past)
        }
    }

    func testClearOptionalFieldsAndStopSeriesWhenMovingToInbox() throws {
        var repeating = task
        repeating.repeatRule = .daily; repeating.repeatAnchor = today
        repeating.remindAt = now.addingTimeInterval(3600); repeating.deadline = today
        repeating.projectID = UUID(); repeating.priority = .high
        let project = TaskProject(id: repeating.projectID!, name: "Drafts")
        try withPipeline(task: repeating, projects: [project]) { pipeline, file, _ in
            var draft = TaskDetailsDraft(task: repeating); draft.moveToInbox()
            draft.hasDeadline = false; draft.projectID = nil; draft.priority = .none
            try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
            let saved = try file.load().tasks[0]
            XCTAssertNil(saved.day); XCTAssertNil(saved.remindAt); XCTAssertNil(saved.repeatRule)
            XCTAssertNil(saved.deadline); XCTAssertNil(saved.projectID); XCTAssertEqual(saved.priority, .none)
        }
    }

    func testConcurrentTaskEditsDoNotGetOverwritten() throws {
        try withPipeline { pipeline, file, directory in
            let task = try file.load().tasks[0]
            var draft = TaskDetailsDraft(task: task); draft.notes = "My draft"
            try pipeline.execute(.rename(task.id, "Another edit"), origin: .background)
            let before = try snapshot(directory)
            XCTAssertThrowsError(try pipeline.perform(origin: .user) { try draft.apply(using: $0) })
            XCTAssertEqual(try snapshot(directory), before)
            XCTAssertEqual(try file.load().tasks[0].title, "Another edit")
        }
    }

    func testEditingDuringActiveFocusPreservesCheckpointAndFinalAccounting() throws {
        final class Clock { var date: Date; init(_ date: Date) { self.date = date } }
        let clock = Clock(now)
        try withPipeline { _, file, _ in
            let pipeline = PlannerCommandPipeline(
                file: file, clock: ClosurePlannerClock { clock.date }, calendar: calendar)
            let task = try file.load().tasks[0]
            try pipeline.execute(.startStopwatch(task.id), origin: .user)
            var draft = TaskDetailsDraft(task: try file.load().tasks[0]); draft.priority = .high
            draft.day = today.adding(days: 1, calendar: calendar)
            clock.date = now.addingTimeInterval(30)
            try pipeline.execute(.checkpointFocus, origin: .background)
            let checkpoint = try file.load()
            try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
            let saved = try file.load()
            XCTAssertEqual(saved.focus, checkpoint.focus)
            XCTAssertEqual(saved.focusSegments, checkpoint.focusSegments)
            XCTAssertEqual(saved.tasks[0].focusedSeconds, 30, accuracy: 0.001)
            clock.date = now.addingTimeInterval(45)
            try pipeline.execute(.stopTimer, origin: .user)
            XCTAssertEqual(try file.load().tasks[0].focusedSeconds, 45, accuracy: 0.001)
        }
    }

    func testReminderMovesUseDomainDSTPolicyAndKeepRepeatAnchor() throws {
        var la = calendar; la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var scheduled = task
        scheduled.day = "2028-03-11"
        scheduled.remindAt = ISO8601DateFormatter().date(from: "2028-03-11T10:30:00Z")!
        scheduled.repeatRule = .daily; scheduled.repeatAnchor = scheduled.day
        try withPipeline(task: scheduled, calendar: la) { pipeline, file, _ in
            var draft = TaskDetailsDraft(task: scheduled); draft.day = "2028-03-12"
            try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
            let saved = try file.load().tasks[0]
            XCTAssertEqual(saved.day, "2028-03-12")
            XCTAssertEqual(saved.repeatAnchor, scheduled.day)
            XCTAssertEqual(saved.remindAt, ISO8601DateFormatter().date(from: "2028-03-12T10:00:00Z"))
            XCTAssertEqual(saved.repeatRule?.next(after: saved.day!, completed: saved.day!, calendar: la), "2028-03-13")
        }
    }

    func testLastDayChoiceAlsoMovesAnExplicitlyEditedReminder() throws {
        try withPipeline { pipeline, file, _ in
            var draft = TaskDetailsDraft(task: try file.load().tasks[0])
            draft.hasReminder = true
            draft.remindAt = now.addingTimeInterval(3600)
            let engine = PlannerEngine(planner: try file.load(), now: { self.now }, calendar: calendar)
            try draft.selectDay("2028-03-02", using: engine)
            XCTAssertEqual(draft.remindAt, ISO8601DateFormatter().date(from: "2028-03-02T19:00:00Z"))
            try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
            let saved = try file.load().tasks[0]
            XCTAssertEqual(saved.day, "2028-03-02")
            XCTAssertEqual(saved.remindAt, draft.remindAt)
        }
    }

    func testNonHourDSTDayPreviewAndSaveAgree() throws {
        var island = calendar; island.timeZone = TimeZone(identifier: "Australia/Lord_Howe")!
        var scheduled = task; scheduled.day = "2028-09-30"
        scheduled.remindAt = ISO8601DateFormatter().date(from: "2028-09-29T15:30:00Z")!
        try withPipeline(task: scheduled, calendar: island) { pipeline, file, _ in
            var draft = TaskDetailsDraft(task: scheduled)
            let engine = PlannerEngine(planner: try file.load(), now: { self.now }, calendar: island)
            try draft.selectDay("2028-10-01", using: engine)
            XCTAssertEqual(draft.remindAt, ISO8601DateFormatter().date(from: "2028-09-30T15:30:00Z"))
            try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
            XCTAssertEqual(try file.load().tasks[0].day, "2028-10-01")
            XCTAssertEqual(try file.load().tasks[0].remindAt, draft.remindAt)
        }
    }

    func testInvalidSelectionsAndPastRemindersRejectWithoutChanges() throws {
        try withPipeline { pipeline, file, directory in
            let task = try file.load().tasks[0]
            let before = try snapshot(directory)
            for kind in ["no-day", "no-weekday", "past-reminder", "inbox-repeat"] {
                var draft = TaskDetailsDraft(task: task)
                switch kind {
                case "no-day": draft.day = nil
                case "no-weekday":
                    draft.recurrence.frequency = .weekly; draft.recurrence.selectWeekdays = true
                case "past-reminder": draft.hasReminder = true; draft.remindAt = now
                default: draft.moveToInbox(); draft.recurrence.frequency = .daily
                }
                XCTAssertThrowsError(try pipeline.perform(origin: .user) { try draft.apply(using: $0) }, kind)
                XCTAssertEqual(try snapshot(directory), before, kind)
            }
            XCTAssertFalse(pipeline.canUndo)
        }
    }

    func testReminderChangesRespectLogicalDayResetHour() throws {
        try withPipeline { pipeline, file, _ in
            var preferences = try file.load().preferences; preferences.resetHour = 4
            try pipeline.execute(.preferences(preferences), origin: .background)
            var draft = TaskDetailsDraft(task: try file.load().tasks[0])
            draft.hasReminder = true
            draft.remindAt = ISO8601DateFormatter().date(from: "2028-03-01T02:00:00Z")!
            try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
            XCTAssertEqual(try file.load().tasks[0].day, "2028-02-29")
        }
    }
}
