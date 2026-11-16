import Foundation
import PlannerCore
import XCTest
@testable import PerchUI

final class NotchStripActionsTests: XCTestCase {
    private final class Time { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    func testReminderChoicesUseLivePreferencesAndPersistAtomically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let time = Time()
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { time.now })
        let task = try pipeline.perform(origin: .user) { commands in
            let task = try commands.addTasks(["Call the bank"], on: .day(commands.today), literal: true)[0]
            try commands.updateTask(task.id) { $0.remindAt = time.now.addingTimeInterval(1) }
            try commands.updatePrefs { $0.snoozeMinutes = .fifteenMinutes }
            return task
        }.value
        time.now.addTimeInterval(1)
        func perform(_ action: NotchStripAction) throws {
            try pipeline.perform(origin: .user) { try NotchStripActions.perform(action, taskID: task.id, commands: $0) }
        }
        try perform(.snooze)
        XCTAssertEqual(try file.load().tasks.first?.remindAt, time.now.addingTimeInterval(900))
        try perform(.notToday)
        XCTAssertNil(try file.load().tasks.first?.remindAt)
        XCTAssertFalse(try file.load().tasks.first!.done)
        try perform(.start)
        XCTAssertEqual(try file.load().focus?.taskID, task.id)
        XCTAssertEqual(try file.load().tasks.first?.startAt, time.now)
        time.now.addTimeInterval(30)
        try perform(.done)
        XCTAssertTrue(try file.load().tasks.first!.done)
        XCTAssertEqual(try file.load().tasks.first?.focusedSeconds, 30)
    }

    func testFinishedBlockExtensionResumesAndKeepsFocusCredit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let time = Time()
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { time.now })
        let task = try pipeline.perform(origin: .user) { commands in
            let task = try commands.addTasks(["Write notes"], on: .day(commands.today), literal: true)[0]
            try commands.startTimer(task: task.id, minutes: 1)
            return task
        }.value
        time.now.addTimeInterval(60)
        try pipeline.perform(origin: .background) { try $0.tick() }
        try pipeline.perform(origin: .user) { try NotchStripActions.perform(.extend, taskID: task.id, commands: $0) }
        let result = try file.load()
        XCTAssertEqual(result.focus?.state, .running)
        XCTAssertEqual(result.focus?.remaining(at: time.now), 600)
        XCTAssertEqual(result.tasks.first?.focusedSeconds, 60)
    }

    func testLastStepTransferAndThoughtPromotionUndoWithoutDuplicatingSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let pipeline = PlannerCommandPipeline(file: file)
        let task = try pipeline.perform(origin: .user) { commands in
            let task = try commands.addTasks(["Write notes"], on: .day(commands.today), literal: true)[0]
            try commands.updateTask(task.id) {
                $0.steps = [Subtask(title: "Finished", done: true), Subtask(title: "Share notes")]
            }
            return task
        }.value
        let before = try file.load()
        try pipeline.perform(origin: .user) {
            try NotchStripActions.perform(.moveLastStep, taskID: task.id, commands: $0)
        }
        XCTAssertEqual(try file.load().tasks.count, 2)
        XCTAssertEqual(try file.load().tasks[0].steps.count, 1)
        XCTAssertEqual(try file.load().tasks[1].title, "Share notes")
        XCTAssertEqual(try file.load().tasks[1].day, before.tasks[0].day!.adding(days: 1))
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().tasks[0].steps, before.tasks[0].steps)
        XCTAssertEqual(try file.load().tasks.count, 1)
        let thought = try pipeline.perform(origin: .user) { try $0.parkThought("Order printer ink") }.value
        try pipeline.perform(origin: .user) {
            try NotchStripActions.perform(.promoteThoughts, taskID: task.id, thoughtIDs: [thought.id], commands: $0)
        }
        XCTAssertTrue(try file.load().parkedThoughts.isEmpty)
        XCTAssertEqual(try file.load().tasks.filter { $0.title == thought.text }.count, 1)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().parkedThoughts.map(\.id), [thought.id])
        XCTAssertEqual(try file.load().tasks.count, 1)
    }
}
