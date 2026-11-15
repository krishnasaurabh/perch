import Foundation
import XCTest
@testable import PerchUI
@testable import PlannerCore

final class WeekScheduledCompletionTests: XCTestCase {
    private let today: DayKey = "2026-11-13"
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func engine(_ tasks: [PlanTask]) -> PlannerEngine {
        var planner = Planner(); planner.tasks = tasks
        return PlannerEngine(
            planner: planner, now: { self.today.start(resetHour: 4, calendar: self.calendar) }, calendar: calendar)
    }

    func testScheduledPolicyAllowsTodayAndFutureButNotHistoryOrInbox() throws {
        for day in [today, today.adding(days: 1, calendar: calendar)] {
            let task = PlanTask(title: "Same title", day: day)
            let other = PlanTask(title: task.title, day: day)
            var engine = engine([task, other])
            try engine.execute(XCTUnwrap(WeekTaskPolicy.scheduledCompletionAction(for: task, today: today)))
            XCTAssertTrue(try engine.task(task.id).done)
            XCTAssertFalse(try engine.task(other.id).done)
            let checked = try engine.task(task.id)
            try engine.execute(XCTUnwrap(WeekTaskPolicy.scheduledCompletionAction(for: checked, today: today)))
            XCTAssertFalse(try engine.task(task.id).done)
            XCTAssertNil(try engine.task(task.id).completedAt)
        }
        for day: DayKey? in [nil, today.adding(days: -1, calendar: calendar)] {
            XCTAssertNil(
                WeekTaskPolicy.scheduledCompletionAction(for: PlanTask(title: "Read only", day: day), today: today))
        }
    }

    func testOrdinaryCompleteAndReopenStillRejectFutureDays() throws {
        let future = today.adding(days: 1, calendar: calendar)
        let open = PlanTask(title: "Open", day: future)
        let done = PlanTask(title: "Done", day: future, done: true)
        var engine = engine([open, done])
        let before = engine.planner
        XCTAssertThrowsError(try engine.execute(.complete(open.id)))
        XCTAssertThrowsError(try engine.execute(.reopen(done.id)))
        XCTAssertEqual(engine.planner, before)
    }

    func testScheduledCompletionRejectsStaleDayHistoryInboxAndMissingIdentity() throws {
        let future = today.adding(days: 1, calendar: calendar)
        let tasks = [
            PlanTask(title: "Moved", day: future), PlanTask(title: "Past", day: today.adding(days: -1)),
            PlanTask(title: "Inbox", day: nil),
        ]
        var engine = engine(tasks)
        let before = engine.planner
        for (id, expected) in [
            (tasks[0].id, today), (tasks[1].id, tasks[1].day!), (tasks[2].id, today), (UUID(), today),
        ] {
            for completed in [true, false] {
                XCTAssertThrowsError(
                    try engine.execute(.setScheduledCompletion(id, expectedDay: expected, completed: completed)))
                XCTAssertEqual(engine.planner, before)
            }
        }
    }

    func testCompletionHasTheSameStepsFocusAndRepeatEffects() throws {
        let now = today.start(resetHour: 4, calendar: calendar)
        let task = PlanTask(
            title: "Repeat", day: today, repeatRule: .daily,
            steps: [Subtask(title: "First"), Subtask(title: "Second", done: true)])
        var original = engine([task])
        try original.execute(.startTimer(task.id, minutes: 25))
        original.now = { now.addingTimeInterval(60) }
        var scheduled = original
        try original.execute(.complete(task.id))
        try scheduled.execute(.setScheduledCompletion(task.id, expectedDay: today, completed: true))
        XCTAssertEqual(try scheduled.task(task.id), try original.task(task.id))
        XCTAssertNil(scheduled.planner.focus)
        XCTAssertEqual(scheduled.planner.focusSegments, original.planner.focusSegments)
        XCTAssertEqual(scheduled.planner.tasks.count, 2)
        let next = try XCTUnwrap(scheduled.planner.tasks.first { $0.id != task.id })
        XCTAssertEqual(next.day, today.adding(days: 1, calendar: calendar))
        XCTAssertTrue(next.steps.allSatisfy { !$0.done })
        XCTAssertTrue(try scheduled.task(task.id).steps.allSatisfy(\.done))
    }

    func testFutureRepeatCompletionAndUndoAreOneTransaction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let future = today.adding(days: 1, calendar: calendar)
        let start = future.date(calendar: calendar).addingTimeInterval(9 * 3600)
        let task = PlanTask(
            title: "Future repeat", day: future, repeatRule: .daily, steps: [Subtask(title: "Step")], startAt: start)
        var planner = Planner(); planner.tasks = [task]
        try file.save(planner)
        let pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { self.today.start(resetHour: 4, calendar: self.calendar) },
            calendar: calendar)
        let before = try file.load()
        try pipeline.execute(.setScheduledCompletion(task.id, expectedDay: future, completed: true), origin: .user)
        let after = try file.load()
        XCTAssertTrue(after.tasks.first { $0.id == task.id }!.done)
        let next = try XCTUnwrap(after.tasks.first { $0.id != task.id })
        XCTAssertEqual(next.day, future.adding(days: 1, calendar: calendar))
        XCTAssertEqual(next.startAt, start.addingTimeInterval(86400))
        XCTAssertTrue(pipeline.canUndo)
        _ = try pipeline.undo()
        let undone = try file.load()
        XCTAssertEqual(undone.tasks.map(\.id), before.tasks.map(\.id))
        XCTAssertEqual(undone.tasks[0].done, before.tasks[0].done)
        XCTAssertEqual(undone.tasks[0].steps, before.tasks[0].steps)
        XCTAssertEqual(undone.repeatOccurrences, before.repeatOccurrences)
        _ = try pipeline.redo()
        XCTAssertEqual(try file.load().tasks.map(\.id), after.tasks.map(\.id))
    }

    func testLockedLatestStateAndLogicalDayAreRevalidated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        var planner = Planner(); planner.preferences.resetHour = 4
        let task = PlanTask(title: "At reset", day: today)
        planner.tasks = [task]; try file.save(planner)
        var now = today.adding(days: 1, calendar: calendar).start(resetHour: 4, calendar: calendar).addingTimeInterval(
            -1)
        let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { now }, calendar: calendar)
        try pipeline.execute(.setScheduledCompletion(task.id, expectedDay: today, completed: true), origin: .user)
        _ = try pipeline.undo()
        now = now.addingTimeInterval(1)
        let before = try file.load()
        XCTAssertThrowsError(
            try pipeline.execute(.setScheduledCompletion(task.id, expectedDay: today, completed: true), origin: .user))
        XCTAssertEqual(try file.load(), before)
        XCTAssertTrue(pipeline.canRedo, "Failed stale commands must not destroy redo")
        // A different writer moves the task after a view chose its expected day.
        try file.mutate { $0.tasks[0].day = today.adding(days: 2, calendar: calendar) }
        let moved = try file.load()
        XCTAssertThrowsError(
            try pipeline.execute(.setScheduledCompletion(task.id, expectedDay: today, completed: true), origin: .user))
        XCTAssertEqual(try file.load(), moved)
    }
}
