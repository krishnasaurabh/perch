import Foundation
import PerchUI
import PlannerCore
import XCTest
@testable import PerchApp

final class NotchStripsTests: XCTestCase {
    @MainActor
    func testReminderChoicesPersistAndSnoozeUsesTheStoredMinutes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PlannerStore(
            file: PlannerFile(url: root.appendingPathComponent("planner.json")), now: { now }, watching: false)
        let task = try XCTUnwrap(store.addTasks(["Call the bank"], on: .day(store.today), literal: true)?.first)
        store.updateTask(task.id) { $0.remindAt = now.addingTimeInterval(1) }
        store.updatePrefs { $0.snoozeMinutes = .fifteenMinutes }
        XCTAssertTrue(NotchStrips.perform(.snooze, taskID: task.id, in: store))
        XCTAssertEqual(try store.file.load().tasks.first?.remindAt, now.addingTimeInterval(900))
        XCTAssertTrue(NotchStrips.perform(.notToday, taskID: task.id, in: store))
        XCTAssertNil(try store.file.load().tasks.first?.remindAt)
        XCTAssertFalse(try store.file.load().tasks.first!.done)
        XCTAssertTrue(NotchStrips.perform(.start, taskID: task.id, in: store))
        XCTAssertEqual(try store.file.load().focus?.taskID, task.id)
        XCTAssertEqual(try store.file.load().tasks.first?.startAt, now)
        XCTAssertTrue(NotchStrips.perform(.done, taskID: task.id, in: store))
        XCTAssertTrue(try store.file.load().tasks.first!.done)
    }

    @MainActor
    func testExtendingAFinishedBlockResumesItWithoutRewindingCreditedTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PlannerStore(
            file: PlannerFile(url: root.appendingPathComponent("planner.json")), now: { now }, watching: false)
        let task = try XCTUnwrap(store.addTasks(["Write notes"], on: .day(store.today), literal: true)?.first)
        store.apply { try $0.startTimer(task: task.id, minutes: 1) }
        now.addTimeInterval(60)
        store.apply { try $0.tick() }
        let credit = store.planner.tasks.first!.focusedSeconds
        XCTAssertEqual(store.planner.focus?.state, .finished)
        XCTAssertTrue(NotchStrips.perform(.extend, taskID: task.id, in: store))
        XCTAssertEqual(store.planner.focus?.state, .running)
        XCTAssertEqual(store.planner.focus?.remaining(at: now), 600)
        XCTAssertEqual(store.planner.tasks.first?.focusedSeconds, credit)
    }

    @MainActor
    func testMoveLastUnfinishedStepIsOneUndoableTransfer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        let task = try XCTUnwrap(store.addTasks(["Write notes"], on: .day(store.today), literal: true)?.first)
        let first = Subtask(title: "Finished", done: true)
        let last = Subtask(title: "Share notes")
        store.updateTask(task.id) { $0.steps = [first, last] }
        XCTAssertTrue(NotchStrips.perform(.moveLastStep, taskID: task.id, in: store))
        XCTAssertEqual(store.planner.tasks.first { $0.id == task.id }?.steps, [first])
        XCTAssertEqual(store.planner.tasks.first { $0.id != task.id }?.title, last.title)
        store.undo()
        XCTAssertEqual(store.planner.tasks.count, 1)
        XCTAssertEqual(store.planner.tasks.first?.steps, [first, last])
    }
}
