import AppKit
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
    @MainActor
    func testPendingAgentDecisionDoesNotAnnounceTheSameDeletionAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PlannerStore(
            file: PlannerFile(url: root.appendingPathComponent("planner.json")), now: { now }, watching: false)
        let model = NotchModel()
        let strips = NotchStrips(store: store, model: model, now: { now })
        model.strips = strips
        let task = try XCTUnwrap(store.addTasks(["Call the bank"], on: .day(store.today), literal: true)?.first)
        for choice in [NotchStrips.Action.undo, .keep] {
            _ = try XCTUnwrap(store.apply { try $0.requestAgentDeletion(task.id, agentID: "claude-code", at: now) })
            strips.refresh()
            let request = try XCTUnwrap(strips.currentActivity)
            XCTAssertEqual(request.stripKind, .agentChange)
            XCTAssertTrue(strips.answer(choice, activity: request))
            XCTAssertNil(
                strips.currentActivity,
                "An answered approval must not produce a duplicate announcement or local Undo strip")
            XCTAssertTrue(try store.file.load().agentActions.pending.isEmpty)
            XCTAssertEqual(try store.file.load().tasks.contains { $0.id == task.id }, choice == .undo)
        }
        XCTAssertTrue(store.canUndo, "The approved agent deletion remains in ordinary Command-Z history")
    }

    @MainActor
    func testEqualSizedReminderHandoffKeepsItsMouseRegion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let day = PlannerEngine(planner: Planner(), now: { now }).today
        try file.mutate { planner in
            planner.tasks = [
                PlanTask(title: "Reminder one", day: day, remindAt: now.addingTimeInterval(-1)),
                PlanTask(title: "Reminder two", day: day, remindAt: now.addingTimeInterval(-1)),
            ]
        }
        let store = PlannerStore(file: file, now: { now }, watching: false)
        let model = NotchModel()
        model.screenID = 1
        let strips = NotchStrips(store: store, model: model, now: { now })
        model.strips = strips
        let geometry = NotchGeometry(
            screen: .init(
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 866), safeAreaTop: 34, auxiliaryLeftWidth: 620,
                auxiliaryRightWidth: 620, isBuiltIn: true))
        strips.setBounds(CGSize(width: 540, height: 120), geometry: geometry)
        let point = CGPoint(x: strips.bounds.midX, y: strips.bounds.midY)
        let first = try XCTUnwrap(strips.currentActivity)
        XCTAssertEqual(strips.contains(point, on: 1), true)
        XCTAssertTrue(strips.answer(.notToday, activity: first))
        XCTAssertNotEqual(strips.currentActivity?.id, first.id)
        XCTAssertNotNil(strips.currentActivity)
        XCTAssertEqual(strips.contains(point, on: 1), true, "Equal-size replacements have no size-change callback")
    }

    @MainActor
    func testDeletionOfferCannotUndoANewerPendingOrAutosavedTextEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PlannerStore(file: file, now: { now }, watching: false)
        let model = NotchModel()
        let strips = NotchStrips(store: store, model: model, now: { now })
        model.strips = strips
        let tasks = try XCTUnwrap(store.addTasks(["Deleted task", "Kept task"], on: .day(store.today), literal: true))
        for autosaved in [false, true] {
            store.apply { try $0.delete(tasks[0].id, on: .day($0.today)) }
            strips.refresh()
            let deletion = try XCTUnwrap(strips.currentActivity)
            store.setText("A newer title", for: .title(tasks[1].id))
            if autosaved { XCTAssertTrue(store.flushPendingText()) }
            XCTAssertFalse(strips.answer(.undo, activity: deletion))
            XCTAssertFalse(try file.load().tasks.contains { $0.id == tasks[0].id })
            XCTAssertEqual(try file.load().tasks.first?.title, "A newer title")
            XCTAssertNil(strips.currentActivity)
            store.undo()
            XCTAssertEqual(try file.load().tasks.first?.title, "Kept task")
            store.undo()
            XCTAssertTrue(try file.load().tasks.contains { $0.id == tasks[0].id })
        }
    }

}
