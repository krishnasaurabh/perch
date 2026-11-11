import Foundation
@testable import PerchUI
@testable import PlannerCore
import XCTest

final class TaskDetailsPickerDraftTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2028-02-28T18:00:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var today: DayKey { DayKey(now, calendar: calendar) }

    private func fixture(_ body: (PlannerCommandPipeline, PlannerFile, URL, PlanTask) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
        let task = PlanTask(title: "Review checklist", day: today, createdAt: now)
        var planner = Planner()
        planner.preferences.resetHour = 0
        planner.tasks = [task]
        try file.save(planner)
        let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { self.now }, calendar: calendar)
        try body(pipeline, file, directory, task)
    }

    private func snapshot(_ directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let entries = try XCTUnwrap(
            FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]))
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            if values.isRegularFile == true {
                result[url.lastPathComponent] =
                    "\(values.contentModificationDate!.timeIntervalSince1970):\(try Data(contentsOf: url).base64EncodedString())"
            }
        }
        return result
    }

    func testPickerEditsEmitTypedActionsAndSaveAsOneUndoableTransaction() throws {
        try fixture { pipeline, file, _, task in
            let project = TaskProject(name: "Planning")
            try file.mutate { $0.projects = [project] }
            var draft = TaskDetailsPickerDraft(task: task, today: today, calendar: calendar)
            var date = draft.scheduledDate
            date.type("2028-02-29")
            let engine = PlannerEngine(planner: try file.load(), now: { self.now }, calendar: calendar)
            try draft.setScheduledDate(date, using: engine)
            draft.deadline.type("2028-03-02")
            draft.repeatRule.select(.quarterly)
            draft.details.priority = .high
            draft.details.projectID = project.id
            let transaction = try draft.validatedDetails(today: today, now: now, projects: [project])
            let actions = try transaction.actions()
            XCTAssertEqual(actions.count, 3)
            guard case let .move(id, .day(day)) = actions[0] else { return XCTFail("Expected a typed move") }
            XCTAssertEqual(id, task.id); XCTAssertEqual(day, "2028-02-29")
            guard case let .update(repeatID, edit) = actions[1] else {
                return XCTFail("Expected a typed repeat update")
            }
            XCTAssertEqual(repeatID, task.id)
            XCTAssertEqual(edit.repeatRule, TaskRepeat(unit: .month, interval: 3).description)
            guard case let .editTask(editID, changes) = actions[2] else {
                return XCTFail("Expected typed field changes")
            }
            XCTAssertEqual(editID, task.id)
            guard case .set(.high) = changes.priority,
                case .set(let projectID) = changes.projectID,
                case .set(let deadline) = changes.deadline
            else { return XCTFail("Priority, project and deadline must be explicit changes") }
            XCTAssertEqual(projectID, project.id); XCTAssertEqual(deadline, "2028-03-02")
            XCTAssertEqual(try file.load().tasks[0], task)
            try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
            let saved = try file.load().tasks[0]
            XCTAssertEqual(saved.day, "2028-02-29");
            XCTAssertEqual(saved.repeatRule, TaskRepeat(unit: .month, interval: 3))
            XCTAssertEqual(saved.deadline, "2028-03-02"); XCTAssertEqual(saved.projectID, project.id)
            XCTAssertEqual(saved.priority, .high)
            _ = try pipeline.undo()
            XCTAssertEqual(try file.load().tasks[0], task)
        }
    }

    func testQuarterlyPickerSaveMaterializesClampedMonthsWithoutDrift() throws {
        try assertSavedRepeat(
            frequency: .quarterly, anchor: "2027-11-30", zone: "America/Los_Angeles",
            expected: ["2028-02-29", "2028-05-30", "2028-08-30", "2028-11-30"])
    }

    func testYearlyPickerSaveReturnsToLeapDayAfterThreeClampedYears() throws {
        try assertSavedRepeat(
            frequency: .yearly, anchor: "2028-02-29", zone: "America/Los_Angeles",
            expected: ["2029-02-28", "2030-02-28", "2031-02-28", "2032-02-29"])
    }

    func testSavedRepeatPreviewAndMaterializationAgreeAcrossDSTTransitions() throws {
        let cases: [(String, DayKey, RepeatPickerDraft.Frequency, [DayKey])] = [
            ("America/Los_Angeles", "2027-03-13", .daily, ["2027-03-14", "2027-03-15", "2027-03-16"]),
            ("America/Los_Angeles", "2026-10-25", .weekly, ["2026-11-01", "2026-11-08", "2026-11-15"]),
            ("Australia/Lord_Howe", "2026-10-03", .daily, ["2026-10-04", "2026-10-05", "2026-10-06"]),
            ("Australia/Lord_Howe", "2027-04-03", .daily, ["2027-04-04", "2027-04-05", "2027-04-06"]),
            ("America/Santiago", "2026-09-05", .daily, ["2026-09-06", "2026-09-07", "2026-09-08"]),
        ]
        for (zone, anchor, frequency, expected) in cases {
            try assertSavedRepeat(frequency: frequency, anchor: anchor, zone: zone, expected: expected)
        }
    }

    /// Exercise the integrated date/repeat adapter, disk transaction and real repeat engine.
    /// Iterate a bounded civil-day range, so a missing occurrence fails rather than hanging.
    private func assertSavedRepeat(
        frequency: RepeatPickerDraft.Frequency, anchor: DayKey, zone: String, expected: [DayKey],
        file sourceFile: StaticString = #filePath, line: UInt = #line
    ) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        let today = anchor.adding(days: -1, calendar: calendar)
        let instant = today.date(calendar: calendar).addingTimeInterval(12 * 3600)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = PlannerFile(url: directory.appendingPathComponent("planner.json"))
        let task = PlanTask(title: "Synthetic recurring checklist", day: today, createdAt: instant)
        var planner = Planner()
        planner.preferences.resetHour = 0
        planner.tasks = [task]
        try storage.save(planner)
        let pipeline = PlannerCommandPipeline(
            file: storage, clock: ClosurePlannerClock { instant }, calendar: calendar)
        var draft = TaskDetailsPickerDraft(task: task, today: today, calendar: calendar)
        var date = draft.scheduledDate
        date.type(anchor.raw)
        try draft.setScheduledDate(date, using: PlannerEngine(planner: planner, now: { instant }, calendar: calendar))
        draft.repeatRule.select(frequency)
        XCTAssertTrue(draft.errors(today: today, now: instant, projects: []).isEmpty, file: sourceFile, line: line)
        XCTAssertEqual(
            draft.repeatRule.preview(count: expected.count), .scheduled(expected), file: sourceFile, line: line)
        try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
        let saved = try storage.load()
        let savedTask = try XCTUnwrap(saved.tasks.first(where: { $0.id == task.id }))
        XCTAssertEqual(savedTask.day, anchor, file: sourceFile, line: line)
        XCTAssertEqual(savedTask.repeatRule, draft.repeatRule.rule, file: sourceFile, line: line)
        XCTAssertEqual(savedTask.repeatAnchor, anchor, file: sourceFile, line: line)
        XCTAssertEqual(
            RepeatPickerDraft(task: savedTask, calendar: calendar).preview(count: expected.count), .scheduled(expected),
            file: sourceFile, line: line)
        var engine = PlannerEngine(planner: saved, now: { instant }, calendar: calendar)
        var day = anchor
        let last = try XCTUnwrap(expected.last)
        var actual: [DayKey] = []
        while day < last {
            day = day.adding(days: 1, calendar: calendar)
            actual += engine.applyRepeats(on: day).compactMap(\.day)
        }
        XCTAssertEqual(actual, expected, "\(zone): \(frequency)", file: sourceFile, line: line)
        XCTAssertTrue(
            engine.applyRepeats(on: last).isEmpty, "Materialization is idempotent", file: sourceFile, line: line)
        _ = try pipeline.undo()
        XCTAssertEqual(try storage.load().tasks, [task], file: sourceFile, line: line)
    }

    func testRepeatWithoutDateBlocksThenRecoversThroughDateSelection() throws {
        try fixture { pipeline, file, directory, task in
            var draft = TaskDetailsPickerDraft(task: task, today: today, calendar: calendar)
            let engine = PlannerEngine(planner: try file.load(), now: { self.now }, calendar: calendar)
            var date = draft.scheduledDate
            date.clear()
            try draft.setScheduledDate(date, using: engine)
            draft.repeatRule.select(.quarterly)
            let before = try snapshot(directory)
            XCTAssertEqual(draft.repeatRule.visibleIssue, .missingAnchor)
            XCTAssertEqual(
                draft.errors(today: today, now: now, projects: [])[.recurrence],
                "Choose a date for this task before setting a repeat.")
            XCTAssertThrowsError(try pipeline.perform(origin: .user) { try draft.apply(using: $0) })
            XCTAssertEqual(try snapshot(directory), before)
            XCTAssertFalse(pipeline.canUndo)
            date.type("2028-02-29")
            try draft.setScheduledDate(date, using: engine)
            XCTAssertNil(draft.repeatRule.visibleIssue)
            XCTAssertTrue(draft.errors(today: today, now: now, projects: []).isEmpty)
            try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
            let saved = try file.load().tasks[0]
            XCTAssertEqual(saved.day, "2028-02-29")
            XCTAssertEqual(saved.repeatRule, TaskRepeat(unit: .month, interval: 3))
            _ = try pipeline.undo()
            XCTAssertEqual(try file.load().tasks[0], task)
        }
    }

    func testEmptyAndMalformedRepeatIntervalsBlockAllEditsWithoutWrites() throws {
        try fixture { pipeline, file, directory, task in
            let before = try snapshot(directory)
            for text in ["", " ", "0", "-1", "1.5", "1000", "999999999999999999999999999", "two"] {
                var draft = TaskDetailsPickerDraft(task: task, today: today, calendar: calendar)
                draft.details.title = "Must not escape invalid repeat validation"
                draft.deadline.type("2028-03-01")
                draft.repeatRule.select(.custom)
                draft.repeatRule.typeInterval(text)
                XCTAssertNotNil(draft.repeatRule.visibleIssue, text)
                XCTAssertNotNil(draft.errors(today: today, now: now, projects: [])[.recurrence], text)
                XCTAssertThrowsError(try pipeline.perform(origin: .user) { try draft.apply(using: $0) }, text)
                XCTAssertEqual(try snapshot(directory), before, text)
                XCTAssertEqual(try file.load().tasks[0], task, text)
            }
            XCTAssertFalse(pipeline.canUndo)
        }
    }

    func testUntouchedStoredRuleOutsidePickerRangeSurvivesOtherEdits() throws {
        for moveDate in [false, true] {
            try fixture { pipeline, file, _, task in
                var repeated = task
                repeated.repeatRule = TaskRepeat(unit: .day, interval: 1000)
                repeated.repeatAnchor = today
                try file.mutate { $0.tasks = [repeated] }
                var draft = TaskDetailsPickerDraft(task: repeated, today: today, calendar: calendar)
                draft.details.title = "Updated title"
                if moveDate {
                    var date = draft.scheduledDate
                    date.type("2028-02-29")
                    try draft.setScheduledDate(
                        date, using: PlannerEngine(planner: try file.load(), now: { self.now }, calendar: calendar))
                }
                XCTAssertTrue(draft.errors(today: today, now: now, projects: []).isEmpty)
                try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
                let saved = try file.load().tasks[0]
                XCTAssertEqual(saved.title, "Updated title")
                XCTAssertEqual(saved.repeatRule, repeated.repeatRule)
                XCTAssertEqual(saved.repeatAnchor, repeated.repeatAnchor)
                XCTAssertEqual(saved.day, moveDate ? "2028-02-29" : today)
            }
        }
    }

    func testCancelAfterPickerChangesLeavesFilesAndModelUntouched() throws {
        try fixture { _, file, directory, task in
            let before = try snapshot(directory)
            var draft = TaskDetailsPickerDraft(task: task, today: today, calendar: calendar)
            var date = draft.scheduledDate; date.clear()
            try draft.setScheduledDate(date, using: PlannerEngine(planner: try file.load(), now: { self.now }))
            draft.deadline.type("2028-03-01"); draft.repeatRule.select(.monthly)
            draft.details.title = "Discard me"
            XCTAssertTrue(draft.hasChanges)
            draft = TaskDetailsPickerDraft(task: task, today: today, calendar: calendar)
            XCTAssertFalse(draft.hasChanges)
            XCTAssertEqual(try file.load().tasks[0], task)
            XCTAssertEqual(try snapshot(directory), before)
        }
    }

    func testInvalidPickerInputBlocksTheEntireTransactionWithoutWrites() throws {
        try fixture { pipeline, file, directory, task in
            let before = try snapshot(directory)
            for field in [TaskDetailsField.day, .deadline, .recurrence] {
                var draft = TaskDetailsPickerDraft(task: task, today: today, calendar: calendar)
                draft.details.title = "Must not save"
                switch field {
                case .day:
                    var date = draft.scheduledDate; date.type("2028-02-30")
                    try draft.setScheduledDate(date, using: PlannerEngine(planner: try file.load(), now: { self.now }))
                case .deadline: draft.deadline.type("not a date")
                default: draft.repeatRule.select(.custom); draft.repeatRule.typeInterval("0")
                }
                XCTAssertNotNil(draft.errors(today: today, now: now, projects: [])[field])
                XCTAssertThrowsError(try pipeline.perform(origin: .user) { try draft.apply(using: $0) })
                XCTAssertEqual(try snapshot(directory), before)
                XCTAssertEqual(try file.load().tasks[0], task)
            }
            XCTAssertFalse(pipeline.canUndo)
        }
    }

    func testClearingScheduledDateStopsRepeatAndClearsReminderAtomically() throws {
        try fixture { pipeline, file, _, task in
            var repeated = task
            repeated.repeatRule = .daily; repeated.repeatAnchor = today
            repeated.remindAt = now.addingTimeInterval(3600)
            try file.mutate { $0.tasks = [repeated] }
            var draft = TaskDetailsPickerDraft(task: repeated, today: today, calendar: calendar)
            var date = draft.scheduledDate; date.clear()
            try draft.setScheduledDate(date, using: PlannerEngine(planner: try file.load(), now: { self.now }))
            XCTAssertNil(draft.repeatRule.anchor)
            XCTAssertEqual(draft.repeatRule.frequency, .none)
            XCTAssertTrue(draft.errors(today: today, now: now, projects: []).isEmpty)
            try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
            let saved = try file.load().tasks[0]
            XCTAssertNil(saved.day); XCTAssertNil(saved.repeatRule); XCTAssertNil(saved.remindAt)
            _ = try pipeline.undo()
            XCTAssertEqual(try file.load().tasks[0], repeated)
        }
    }

    func testDateMoveKeepsSeriesAnchorAndPreviewMatchesSavedRule() throws {
        try fixture { pipeline, file, _, task in
            var repeated = task
            repeated.day = "2028-03-31"; repeated.repeatRule = .monthly; repeated.repeatAnchor = "2028-01-31"
            try file.mutate { $0.tasks = [repeated] }
            var draft = TaskDetailsPickerDraft(task: repeated, today: today, calendar: calendar)
            var date = draft.scheduledDate; date.type("2028-04-04")
            try draft.setScheduledDate(date, using: PlannerEngine(planner: try file.load(), now: { self.now }))
            XCTAssertEqual(draft.repeatRule.anchor, "2028-04-04")
            XCTAssertEqual(draft.repeatRule.seriesAnchor, "2028-01-31")
            XCTAssertEqual(draft.repeatRule.preview(count: 1), .scheduled(["2028-04-30"]))
            try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
            let saved = try file.load().tasks[0]
            XCTAssertEqual(saved.repeatAnchor, repeated.repeatAnchor)
            XCTAssertEqual(
                RepeatPickerDraft(task: saved, calendar: calendar).preview(count: 1), draft.repeatRule.preview(count: 1)
            )
        }
    }

    func testReminderAndDayEditsStaySynchronizedInEitherOrder() throws {
        try fixture { pipeline, file, _, task in
            var draft = TaskDetailsPickerDraft(task: task, today: today, calendar: calendar)
            let engine = PlannerEngine(planner: try file.load(), now: { self.now }, calendar: calendar)
            draft.setReminder(now.addingTimeInterval(3600), using: engine)
            var date = draft.scheduledDate; date.type("2028-02-29")
            try draft.setScheduledDate(date, using: engine)
            XCTAssertEqual(draft.details.remindAt, ISO8601DateFormatter().date(from: "2028-02-29T19:00:00Z"))
            let finalReminder = ISO8601DateFormatter().date(from: "2028-03-01T20:00:00Z")!
            draft.setReminder(finalReminder, using: engine)
            XCTAssertEqual(draft.scheduledDate.entry, .day("2028-03-01"))
            XCTAssertEqual(draft.repeatRule.anchor, "2028-03-01")
            try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
            XCTAssertEqual(try file.load().tasks[0].day, "2028-03-01")
            XCTAssertEqual(try file.load().tasks[0].remindAt, finalReminder)
        }
    }

    func testPastDayRemainsReadOnlyEvenAfterPickerMovesToToday() throws {
        try fixture { pipeline, file, directory, task in
            var past = task; past.day = today.adding(days: -1, calendar: calendar)
            try file.mutate { $0.tasks = [past] }
            let before = try snapshot(directory)
            var draft = TaskDetailsPickerDraft(task: past, today: today, calendar: calendar)
            var date = draft.scheduledDate; date.type(today.raw)
            try draft.setScheduledDate(date, using: PlannerEngine(planner: try file.load(), now: { self.now }))
            XCTAssertThrowsError(try pipeline.perform(origin: .user) { try draft.apply(using: $0) })
            XCTAssertEqual(try snapshot(directory), before)
        }
    }

    func testActiveAndFinishedFocusAccountingSurvivesPickerSave() throws {
        final class Clock { var date: Date; init(_ date: Date) { self.date = date } }
        for finishBeforeSave in [false, true] {
            try fixture { _, file, _, task in
                let clock = Clock(now)
                let pipeline = PlannerCommandPipeline(
                    file: file, clock: ClosurePlannerClock { clock.date }, calendar: calendar)
                try pipeline.execute(.startStopwatch(task.id), origin: .user)
                var draft = TaskDetailsPickerDraft(task: try file.load().tasks[0], today: today, calendar: calendar)
                var date = draft.scheduledDate; date.type("2028-02-29")
                try draft.setScheduledDate(date, using: PlannerEngine(planner: try file.load(), now: { self.now }))
                draft.repeatRule.select(.quarterly); draft.details.priority = .high
                clock.date = now.addingTimeInterval(30)
                try pipeline.execute(finishBeforeSave ? .stopTimer : .checkpointFocus, origin: .background)
                let accounting = try file.load()
                try pipeline.perform(origin: .user) { try draft.apply(using: $0) }
                let saved = try file.load()
                XCTAssertEqual(saved.focus, accounting.focus)
                XCTAssertEqual(saved.focusSegments, accounting.focusSegments)
                XCTAssertEqual(saved.tasks[0].focusedSeconds, 30, accuracy: 0.001)
                if !finishBeforeSave {
                    clock.date = now.addingTimeInterval(45)
                    try pipeline.execute(.stopTimer, origin: .user)
                    XCTAssertEqual(try file.load().tasks[0].focusedSeconds, 45, accuracy: 0.001)
                }
            }
        }
    }
}
