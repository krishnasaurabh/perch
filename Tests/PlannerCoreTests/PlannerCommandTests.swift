import Foundation
import XCTest
@testable import PlannerCore

final class PlannerCommandTests: XCTestCase {
    final class Clock: PlannerClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }
    var root: URL!
    var file: PlannerFile!
    var clock: Clock!
    var pipeline: PlannerCommandPipeline!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = PlannerFile(url: root.appendingPathComponent("planner.json"))
        clock = Clock()
        pipeline = PlannerCommandPipeline(file: file, clock: clock)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult
    func add(_ title: String = "Synthetic task") throws -> UUID {
        try pipeline.execute(.addTasks([title], day: nil, literal: true, agentID: nil), origin: .user).value.tasks[0].id
    }

    func testResultIsExactCommittedSnapshot() throws {
        let id = try add()
        let result = try pipeline.execute(.rename(id, "Changed"), origin: .user)
        XCTAssertEqual(result.before.tasks[0].title, "Synthetic task")
        XCTAssertEqual(result.state, try file.load())
        XCTAssertEqual(result.value.tasks[0].title, "Changed")
    }

    func testFailedBatchLeavesNoPartialEditOrUndo() throws {
        try file.save(Planner())
        let bytes = try Data(contentsOf: file.url)
        XCTAssertThrowsError(
            try pipeline.perform(origin: .user) { commands in
                let id = try commands.addTasks(["One"]).first!.id
                try commands.rename(id, on: .day(commands.today), to: " ")
            })
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertFalse(pipeline.canUndo)
    }

    func testInvalidEditCannotLeakProjectCreation() throws {
        let id = try add()
        let before = try file.load()
        var edit = TaskEdit(); edit.project = "Transient"; edit.minutes = -1
        XCTAssertThrowsError(try pipeline.execute(.update(id, edit), origin: .user))
        XCTAssertEqual(try file.load(), before)
    }

    func testReadSessionCannotMutateOrCreateStorage() throws {
        XCTAssertThrowsError(try pipeline.inspect { commands in try commands.addTasks(["No"]) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.lockURL.path))
    }

    func testSnapshotCopyCannotWriteBack() throws {
        try add()
        try pipeline.inspect { commands in
            var copy = commands.planner
            copy.tasks.removeAll()
        }
        XCTAssertEqual(try file.load().tasks.count, 1)
    }

    func testBackgroundWorkPreservesUndoAndRedo() throws {
        let id = try add()
        try pipeline.execute(.rename(id, "New title"), origin: .user)
        try pipeline.undo()
        XCTAssertTrue(pipeline.canRedo)
        try pipeline.execute(.reminderLinks([id: "synthetic-link"]), origin: .background)
        try pipeline.execute(.lifecycle(.dayChanged), origin: .background)
        XCTAssertTrue(pipeline.canRedo)
        try pipeline.redo()
        let task = try file.load().tasks[0]
        XCTAssertEqual(task.title, "New title")
        XCTAssertEqual(task.reminderLink, "synthetic-link")
    }

    func testTimerCreditSurvivesCompletionUndoAndRedo() throws {
        let id = try add()
        try pipeline.execute(.startTimer(id, minutes: 5), origin: .user)
        clock.now += 12.5
        try pipeline.execute(.complete(id), origin: .user)
        try pipeline.undo()
        var saved = try file.load()
        XCTAssertFalse(saved.tasks[0].done)
        XCTAssertEqual(saved.tasks[0].focusedSeconds, 12.5)
        XCTAssertNil(saved.focus)
        try pipeline.redo()
        saved = try file.load()
        XCTAssertTrue(saved.tasks[0].done)
        XCTAssertEqual(saved.tasks[0].focusedSeconds, 12.5)
        XCTAssertEqual(saved.focusSegments.reduce(0) { $0 + $1.seconds }, 12.5)
    }

    func testPastTaskEditsFailButExplicitOverdueCompletionWorks() throws {
        let id = try add()
        clock.now += 86_400
        let before = try file.load()
        var changes = TaskChanges(); changes.notes = .set("No")
        for action: PlannerAction in [
            .rename(id, "No"), .delete(id), .editTask(id, changes), .reorder(id, before: nil), .startStopwatch(id),
            .snooze(id, minutes: 5),
        ] {
            XCTAssertThrowsError(try pipeline.execute(action, origin: .user))
            XCTAssertEqual(try file.load(), before)
        }
        let result = try pipeline.execute(.completeOverdue([id]), origin: .user)
        XCTAssertTrue(result.value.tasks[0].done)
        XCTAssertEqual(result.value.tasks[0].day, before.tasks[0].day)
        try pipeline.undo()
        XCTAssertFalse(try file.load().tasks[0].done)
    }

    func testTypedReminderAndDurationUseSameRulesAsParsedEdit() throws {
        let id = try add()
        var changes = TaskChanges(); changes.minutes = .set(-1)
        XCTAssertThrowsError(try pipeline.execute(.editTask(id, changes), origin: .user))
        changes = TaskChanges(); changes.remindAt = .set(clock.now.addingTimeInterval(-60))
        XCTAssertThrowsError(try pipeline.execute(.editTask(id, changes), origin: .user))
        changes.remindAt = .set(clock.now.addingTimeInterval(3600))
        let result = try pipeline.execute(.editTask(id, changes), origin: .user)
        XCTAssertEqual(result.state.tasks[0].remindAt, clock.now.addingTimeInterval(3600))
    }

    func testMissingIDsAndCrossDayReorderFailWithoutWrite() throws {
        let id = try add()
        let next = try pipeline.execute(
            .addTasks(["Later"], day: .day(DayKey(clock.now).adding(days: 1)), literal: true, agentID: nil),
            origin: .user
        ).value.tasks[0].id
        let before = try file.load()
        for action: PlannerAction in [.complete(UUID()), .reorder(id, before: next), .startTimer(UUID(), minutes: 5)] {
            XCTAssertThrowsError(try pipeline.execute(action, origin: .user))
            XCTAssertEqual(try file.load(), before)
        }
    }

    func testLifecycleMaterializesRepeatsAndCarriesWithoutAView() throws {
        let id = try add()
        var edit = TaskEdit(); edit.repeatRule = "daily"
        try pipeline.execute(.update(id, edit), origin: .user)
        var preferences = try file.load().preferences; preferences.carryMode = .auto
        try pipeline.execute(.preferences(preferences), origin: .user)
        clock.now += 86_400
        let result = try pipeline.execute(.lifecycle(.dayChanged), origin: .background)
        let today = DayKey(clock.now)
        XCTAssertEqual(result.state.tasks.filter { $0.day == today }.count, 1)
        XCTAssertEqual(result.state.tasks.first { $0.id == id }?.day, today.adding(days: -1))
        XCTAssertEqual(result.state, try pipeline.execute(.lifecycle(.dayChanged), origin: .background).state)
    }

    func testOpeningHistoryDoesNotMaterializeRepeat() throws {
        let id = try add()
        var edit = TaskEdit(); edit.repeatRule = "daily"
        try pipeline.execute(.update(id, edit), origin: .user)
        clock.now += 3 * 86_400
        let before = try file.load()
        let result = try pipeline.execute(.lifecycle(.openDay(DayKey(clock.now).adding(days: -1))), origin: .background)
        XCTAssertEqual(result.state, before)
    }

    func testFailedPersistenceRetainsHistory() throws {
        let id = try add()
        try pipeline.execute(.rename(id, "New"), origin: .user)
        let good = try Data(contentsOf: file.url)
        try Data("invalid".utf8).write(to: file.url)
        XCTAssertThrowsError(try pipeline.undo())
        XCTAssertTrue(pipeline.canUndo)
        try good.write(to: file.url)
        try pipeline.undo()
        XCTAssertEqual(try file.load().tasks[0].title, "Synthetic task")
    }

    func testConcurrentPipelinesDoNotLoseCommands() throws {
        let queue = DispatchQueue(label: "command-test", attributes: .concurrent)
        let group = DispatchGroup()
        let failures = LockedFailures()
        let path = file.url
        for index in 0..<12 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let writer = PlannerCommandPipeline(file: PlannerFile(url: path))
                    try writer.execute(
                        .addTasks(["Task \(index)"], day: nil, literal: true, agentID: nil), origin: .background)
                } catch { failures.append(String(describing: error)) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(failures.values, [])
        XCTAssertEqual(try file.load().tasks.count, 12)
    }
    func testDeletingActiveTaskBanksTimeAndUndoRestoresCreditOnly() throws {
        let id = try add()
        try pipeline.execute(.startTimer(id, minutes: 5), origin: .user)
        clock.now += 10.5
        try pipeline.execute(.delete(id), origin: .user)
        XCTAssertEqual(try file.load().focusSegments.reduce(0) { $0 + $1.seconds }, 10.5)
        try pipeline.undo()
        XCTAssertEqual(try file.load().tasks[0].focusedSeconds, 10.5)
        XCTAssertNil(try file.load().focus)
    }

}

private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
}
