import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class PlannerUndoConsistencyTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!
    private var pipeline: PlannerCommandPipeline!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func scheduledTask() throws -> PlanTask {
        let task = PlanTask(
            title: "Write", day: "2026-11-09", remindAt: Fixture.date("2026-11-09 19:00"),
            startAt: Fixture.date("2026-11-09 17:00"))
        var planner = Planner()
        planner.tasks = [task]
        try file.save(planner)
        return task
    }

    private func assertSchedule(_ day: DayKey?, _ start: String?, _ reminder: String?, line: UInt = #line) throws {
        let task = try XCTUnwrap(file.load().tasks.first, line: line)
        XCTAssertEqual(task.day, day, line: line)
        XCTAssertEqual(Fixture.hm(task.startAt), start, line: line)
        XCTAssertEqual(Fixture.hm(task.remindAt), reminder, line: line)
    }

    func testConflictingStartPreventsMoveUndoFromRestoringOldReminderDay() throws {
        let task = try scheduledTask()
        try pipeline.execute(.move(task.id, .day("2026-11-10")), origin: .user)
        try pipeline.execute(.setStart(task.id, Fixture.date("2026-11-10 18:00")), origin: .background)
        _ = try pipeline.undo()
        try assertSchedule("2026-11-10", "2026-11-10 18:00", "2026-11-10 19:00")
        XCTAssertFalse(pipeline.canRedo)
    }

    func testConflictingStartPreventsMoveRedoFromRestoringNewReminderDay() throws {
        let task = try scheduledTask()
        try pipeline.execute(.move(task.id, .day("2026-11-10")), origin: .user)
        _ = try pipeline.undo()
        try assertSchedule("2026-11-09", "2026-11-09 17:00", "2026-11-09 19:00")
        try pipeline.execute(.setStart(task.id, Fixture.date("2026-11-09 18:00")), origin: .background)
        _ = try pipeline.redo()
        try assertSchedule("2026-11-09", "2026-11-09 18:00", "2026-11-09 19:00")
        XCTAssertFalse(pipeline.canRedo)
    }

    func testConflictingReminderPreventsMoveUndoAndRedo() throws {
        let task = try scheduledTask()
        for redo in [false, true] {
            try file.mutate { $0.tasks = [task] }
            pipeline = PlannerCommandPipeline(
                file: file, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)
            try pipeline.execute(.move(task.id, .day("2026-11-10")), origin: .user)
            if redo { _ = try pipeline.undo() }
            let day = redo ? "2026-11-09" : "2026-11-10"
            var changes = TaskChanges()
            changes.remindAt = .set(Fixture.date("\(day) 20:00"))
            try pipeline.execute(.editTask(task.id, changes), origin: .background)
            if redo { _ = try pipeline.redo() } else { _ = try pipeline.undo() }
            try assertSchedule(DayKey(day), "\(day) 17:00", "\(day) 20:00")
        }
    }

    func testReminderAddedAfterMovePreventsUndoFromMovingItToAnotherDay() throws {
        var task = try scheduledTask()
        task.remindAt = nil
        try file.mutate { $0.tasks = [task] }
        try pipeline.execute(.move(task.id, .day("2026-11-10")), origin: .user)
        var changes = TaskChanges()
        changes.remindAt = .set(Fixture.date("2026-11-10 20:00"))
        try pipeline.execute(.editTask(task.id, changes), origin: .background)
        _ = try pipeline.undo()
        try assertSchedule("2026-11-10", "2026-11-10 17:00", "2026-11-10 20:00")
    }

    func testSameDayStartAndReminderEditsRemainIndependent() throws {
        let task = try scheduledTask()
        try pipeline.execute(.setStart(task.id, Fixture.date("2026-11-09 18:00")), origin: .user)
        var changes = TaskChanges()
        changes.remindAt = .set(Fixture.date("2026-11-09 20:00"))
        try pipeline.execute(.editTask(task.id, changes), origin: .background)
        _ = try pipeline.undo()
        try assertSchedule("2026-11-09", "2026-11-09 17:00", "2026-11-09 20:00")
        _ = try pipeline.redo()
        try assertSchedule("2026-11-09", "2026-11-09 18:00", "2026-11-09 20:00")
        changes.remindAt = .set(Fixture.date("2026-11-09 21:00"))
        try pipeline.execute(.editTask(task.id, changes), origin: .user)
        try pipeline.execute(.setStart(task.id, Fixture.date("2026-11-09 16:00")), origin: .background)
        _ = try pipeline.undo()
        try assertSchedule("2026-11-09", "2026-11-09 16:00", "2026-11-09 20:00")
        _ = try pipeline.redo()
        try assertSchedule("2026-11-09", "2026-11-09 16:00", "2026-11-09 21:00")
    }

    func testMoveWithBothTimesAndInboxRoundTrips() throws {
        let task = try scheduledTask()
        for destination in [DayRef.day("2026-11-10"), .inbox] {
            try pipeline.execute(.move(task.id, destination), origin: .user)
            for _ in 0..<2 {
                _ = try pipeline.undo()
                try assertSchedule("2026-11-09", "2026-11-09 17:00", "2026-11-09 19:00")
                _ = try pipeline.redo()
                if destination == .inbox {
                    try assertSchedule(nil, nil, nil)
                } else {
                    try assertSchedule("2026-11-10", "2026-11-10 17:00", "2026-11-10 19:00")
                }
            }
            _ = try pipeline.undo()
        }
    }

    private func seedThoughts() throws -> [ParkedThought] {
        let thoughts = ["A", "B", "C", "D"].map { ParkedThought(text: $0, createdAt: Fixture.now) }
        var planner = Planner()
        planner.parkedThoughts = thoughts
        try file.save(planner)
        pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)
        return thoughts
    }

    func testMixedPromotionDeletionAndReorderingRestoresExactParkingOrder() throws {
        for promotedIndex in 0..<4 {
            for deletedIndex in 0..<4 where deletedIndex != promotedIndex {
                for reorder in [false, true] {
                    let thoughts = try seedThoughts()
                    let task = try pipeline.perform(origin: .user) { commands in
                        let task = try commands.promoteThought(thoughts[promotedIndex].id)
                        try commands.removeThought(thoughts[deletedIndex].id)
                        if reorder {
                            let remaining = commands.planner.parkedThoughts
                            try commands.reorderThought(remaining[1].id, before: remaining[0].id)
                        }
                        return task
                    }.value
                    let after = try file.load().parkedThoughts
                    for _ in 0..<2 {
                        _ = try pipeline.undo()
                        XCTAssertEqual(try file.load().parkedThoughts, thoughts)
                        XCTAssertTrue(try file.load().tasks.isEmpty)
                        _ = try pipeline.redo()
                        XCTAssertEqual(try file.load().parkedThoughts, after)
                        XCTAssertEqual(try file.load().tasks.map(\.id), [task.id])
                    }
                }
            }
        }
    }

    func testMixedTaskDeletionPromotionAndReorderRestoresTaskOrder() throws {
        let thoughts = try seedThoughts()
        let originals = ["One", "Two", "Three"].map { PlanTask(title: $0, day: "2026-11-09") }
        try file.mutate { $0.tasks = originals }
        let promoted = try pipeline.perform(origin: .user) { commands in
            let task = try commands.promoteThought(thoughts[1].id)
            try commands.delete(originals[0].id, on: .day(commands.today))
            try commands.reorder(originals[2].id, before: originals[1].id)
            return task
        }.value
        let afterIDs = try file.load().tasks.map(\.id)
        for _ in 0..<2 {
            _ = try pipeline.undo()
            XCTAssertEqual(try file.load().tasks.map(\.id), originals.map(\.id))
            XCTAssertEqual(try file.load().parkedThoughts, thoughts)
            _ = try pipeline.redo()
            XCTAssertEqual(try file.load().tasks.map(\.id), afterIDs)
            XCTAssertEqual(try file.load().tasks.last?.id, promoted.id)
            XCTAssertEqual(try file.load().parkedThoughts, [thoughts[0], thoughts[2], thoughts[3]])
        }
    }

    func testMixedParkingUndoPreservesExternalOrderAndNewThought() throws {
        let thoughts = try seedThoughts()
        try pipeline.perform(origin: .user) { commands in
            try commands.promoteThought(thoughts[1].id)
            try commands.removeThought(thoughts[0].id)
        }
        let external = try pipeline.execute(.parkThought("External"), origin: .background).value.thoughts[0]
        try pipeline.execute(.reorderThought(thoughts[3].id, before: thoughts[2].id), origin: .background)
        _ = try pipeline.undo()
        let restored = try file.load().parkedThoughts
        XCTAssertEqual(Set(restored.map(\.id)), Set(thoughts.map(\.id) + [external.id]))
        XCTAssertEqual(
            restored.filter { [thoughts[2].id, thoughts[3].id, external.id].contains($0.id) },
            [thoughts[3], thoughts[2], external])
        _ = try pipeline.redo()
        XCTAssertEqual(try file.load().parkedThoughts, [thoughts[3], thoughts[2], external])
    }

    func testMixedParkingUndoKeepsExternalDeletionWithoutLosingRestoredOrder() throws {
        let thoughts = try seedThoughts()
        let task = try pipeline.perform(origin: .user) { commands in
            let task = try commands.promoteThought(thoughts[1].id)
            try commands.removeThought(thoughts[0].id)
            return task
        }.value
        try pipeline.execute(.removeThought(thoughts[3].id), origin: .background)
        for _ in 0..<2 {
            _ = try pipeline.undo()
            XCTAssertEqual(try file.load().parkedThoughts, Array(thoughts.prefix(3)))
            XCTAssertTrue(try file.load().tasks.isEmpty)
            _ = try pipeline.redo()
            XCTAssertEqual(try file.load().parkedThoughts, [thoughts[2]])
            XCTAssertEqual(try file.load().tasks.map(\.id), [task.id])
        }
    }

    func testConflictedPromotionStillRestoresUnrelatedDeletionInOrder() throws {
        let thoughts = try seedThoughts()
        let task = try pipeline.perform(origin: .user) { commands in
            let task = try commands.promoteThought(thoughts[1].id)
            try commands.removeThought(thoughts[0].id)
            return task
        }.value
        try pipeline.execute(.rename(task.id, "External task"), origin: .background)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().parkedThoughts, [thoughts[0], thoughts[2], thoughts[3]])
        XCTAssertEqual(try file.load().tasks.first?.title, "External task")
        _ = try pipeline.redo()
        XCTAssertEqual(try file.load().parkedThoughts, [thoughts[2], thoughts[3]])
        XCTAssertEqual(try file.load().tasks.map(\.id), [task.id])
    }
}
