import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class ParkingScheduleRegressionTests: XCTestCase {
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

    func testLegacyAutosavesStaySeparateFromMigratedAndIndependentThoughts() throws {
        let raw = #"{"version":1,"notes":[{"day":"2026-11-09","text":"Original"}]}"#
        try Data(raw.utf8).write(to: file.url)
        let migrated = try XCTUnwrap(file.load().parkedThoughts.first)
        let independent = try pipeline.execute(.parkThought("Independent"), origin: .user).value.thoughts[0]
        let task = try pipeline.execute(.promoteThought(migrated.id, day: nil, agentID: nil), origin: .user).value
            .tasks[0]
        for text in ["Plan", "Plan the trip", "Plan the trip to the coast", ""] {
            try pipeline.execute(.writeNotepad("2026-11-09", text, mode: "replace"), origin: .user)
            let state = try file.load()
            XCTAssertEqual(state.parkedThoughts, [independent])
            XCTAssertEqual(state.tasks.map(\.id), [task.id])
            XCTAssertEqual(state.notes.first?.text, text)
        }
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().notes.first?.text, "Plan the trip to the coast")
        XCTAssertEqual(try file.load().parkedThoughts, [independent])
        _ = try pipeline.redo()
        XCTAssertEqual(try file.load().notes.first?.text, "")
        XCTAssertEqual(try file.load().parkedThoughts, [independent])
    }

    func testMixedPromotionUndoRetainsConflictedTransferButUndoesUnrelatedChanges() throws {
        let thought = try pipeline.execute(.parkThought("Idea"), origin: .user).value.thoughts[0]
        let pair = try pipeline.perform(origin: .user) { commands in
            let task = try commands.promoteThought(thought.id)
            _ = try commands.rename(task.id, on: .day(commands.today), to: "Refined idea")
            let unrelated = try commands.addTasks(["Unrelated"], literal: true)[0]
            return (task.id, unrelated.id)
        }.value
        try pipeline.execute(.rename(pair.0, "External edit"), origin: .background)
        _ = try pipeline.undo()
        XCTAssertTrue(try file.load().parkedThoughts.isEmpty)
        XCTAssertEqual(try file.load().tasks.map(\.id), [pair.0])
        XCTAssertEqual(try file.load().tasks.first?.title, "External edit")
        _ = try pipeline.redo()
        XCTAssertTrue(try file.load().parkedThoughts.isEmpty)
        XCTAssertEqual(Set(try file.load().tasks.map(\.id)), Set([pair.0, pair.1]))
    }

    func testMixedPromotionUndoRetainsTransferWithLaterFocusCredit() throws {
        let thought = try pipeline.execute(.parkThought("Idea"), origin: .user).value.thoughts[0]
        let task = try pipeline.perform(origin: .user) { commands in
            let task = try commands.promoteThought(thought.id)
            _ = try commands.addTasks(["Unrelated"], literal: true)
            return task
        }.value
        try pipeline.execute(.startTimer(task.id, minutes: 20), origin: .background)
        _ = try pipeline.undo()
        XCTAssertTrue(try file.load().parkedThoughts.isEmpty)
        XCTAssertEqual(try file.load().tasks.map(\.id), [task.id])
        XCTAssertEqual(try file.load().focus?.taskID, task.id)
        _ = try pipeline.redo()
        XCTAssertTrue(try file.load().parkedThoughts.isEmpty)
        XCTAssertEqual(try file.load().tasks.count, 2)
    }

    func testMixedPromotionUndoRedoPreservesTransferIdentityAndLaterThoughtEdits() throws {
        let thought = try pipeline.execute(.parkThought("Idea"), origin: .user).value.thoughts[0]
        let task = try pipeline.perform(origin: .user) { commands in
            let task = try commands.promoteThought(thought.id)
            _ = try commands.rename(task.id, on: .day(commands.today), to: "Refined idea")
            _ = try commands.parkThought("Other thought")
            _ = try commands.addTasks(["Other task"], literal: true)
            return task
        }.value
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().parkedThoughts, [thought])
        XCTAssertTrue(try file.load().tasks.isEmpty)
        _ = try pipeline.redo()
        XCTAssertEqual(try file.load().tasks.first?.id, task.id)
        XCTAssertEqual(try file.load().tasks.first?.title, "Refined idea")
        XCTAssertEqual(try file.load().parkedThoughts.map(\.text), ["Other thought"])
        _ = try pipeline.undo()
        try file.mutate { $0.parkedThoughts[0].text = "External thought edit" }
        _ = try pipeline.redo()
        XCTAssertEqual(
            Set(try file.load().parkedThoughts.map(\.text)), Set(["External thought edit", "Other thought"]))
        XCTAssertEqual(try file.load().tasks.map(\.title), ["Other task"])
    }

    func testMoveUndoDoesNotSeparateDayFromExternallyChangedStart() throws {
        let task = try pipeline.perform(origin: .user) { try $0.addTasks(["Write"], literal: true)[0] }.value
        try pipeline.execute(.setStart(task.id, Fixture.date("2026-11-09 17:00")), origin: .background)
        try pipeline.execute(.move(task.id, .day("2026-11-10")), origin: .user)
        try pipeline.execute(.setStart(task.id, Fixture.date("2026-11-10 18:00")), origin: .background)
        _ = try pipeline.undo()
        let result = try file.load().tasks[0]
        XCTAssertEqual(result.day, "2026-11-10")
        XCTAssertEqual(Fixture.hm(result.startAt), "2026-11-10 18:00")
        XCTAssertFalse(pipeline.canRedo)
    }

    func testStartRedoDoesNotSeparateStartFromExternallyMovedDay() throws {
        let task = try pipeline.perform(origin: .user) { try $0.addTasks(["Write"], literal: true)[0] }.value
        try pipeline.execute(.setStart(task.id, Fixture.date("2026-11-09 17:00")), origin: .user)
        _ = try pipeline.undo()
        try pipeline.execute(.move(task.id, .day("2026-11-10")), origin: .background)
        _ = try pipeline.redo()
        XCTAssertEqual(try file.load().tasks[0].day, "2026-11-10")
        XCTAssertNil(try file.load().tasks[0].startAt)
    }

    func testUncontestedScheduleUndoRedoPreservesUnrelatedEdits() throws {
        let task = try pipeline.perform(origin: .user) { try $0.addTasks(["Write"], literal: true)[0] }.value
        try pipeline.execute(.setStart(task.id, Fixture.date("2026-11-09 17:00")), origin: .background)
        try pipeline.execute(.move(task.id, .day("2026-11-10")), origin: .user)
        try pipeline.execute(.rename(task.id, "External title"), origin: .background)
        for _ in 0..<2 {
            _ = try pipeline.undo()
            XCTAssertEqual(try file.load().tasks[0].day, "2026-11-09")
            XCTAssertEqual(Fixture.hm(try file.load().tasks[0].startAt), "2026-11-09 17:00")
            _ = try pipeline.redo()
            XCTAssertEqual(try file.load().tasks[0].day, "2026-11-10")
            XCTAssertEqual(Fixture.hm(try file.load().tasks[0].startAt), "2026-11-10 17:00")
            XCTAssertEqual(try file.load().tasks[0].title, "External title")
        }
    }

    func testRecoveryRetainsParkingAndMigrationMarkerBesideCorruptTask() throws {
        var planner = Planner()
        planner.notes = [QuickNote(day: "2026-11-09", text: "Already promoted")]
        planner.parkedThoughts = [ParkedThought(text: "Keep this", createdAt: Fixture.now)]
        planner.tasks = [PlanTask(title: "Bad task", day: "2026-11-09")]
        try file.save(planner)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
        var tasks = try XCTUnwrap(root["tasks"] as? [[String: Any]])
        tasks[0]["title"] = 42
        root["tasks"] = tasks
        let bytes = try JSONSerialization.data(withJSONObject: root)
        try bytes.write(to: file.url)
        let recovery = try loadRecovery()
        XCTAssertEqual(recovery.recoveredPlanner.parkedThoughts, planner.parkedThoughts)
        XCTAssertTrue(recovery.recoveredPlanner.notepadMigrationComplete)
        XCTAssertEqual(recovery.keptCount, 2)
        XCTAssertEqual(recovery.quarantinedCount, 1)
        XCTAssertEqual(recovery.quarantinedFieldCount, 0)
        XCTAssertEqual(recovery.issues.map(\.path), ["tasks[0].title"])
        XCTAssertEqual(
            try PlannerFile.decodeDocument(Data(contentsOf: recovery.recoveredURL)).parkedThoughts,
            planner.parkedThoughts)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertEqual(try Data(contentsOf: recovery.originalURL), bytes)
    }

    func testRecoveryCountsMalformedThoughtsWithoutDroppingTheirNeighbors() throws {
        let good = ParkedThought(text: "Keep", createdAt: Fixture.now)
        let record = try JSONSerialization.jsonObject(with: PlannerFile.encoder.encode(good))
        let root: [String: Any] = [
            "version": 1,
            "parkedThoughts": [
                record, ["id": UUID().uuidString, "text": 42, "createdAt": "2026-11-09T18:00:00Z"], record,
            ],
            "notepadMigrationComplete": true,
        ]
        let bytes = try JSONSerialization.data(withJSONObject: root)
        try bytes.write(to: file.url)
        let recovery = try loadRecovery()
        XCTAssertEqual(recovery.recoveredPlanner.parkedThoughts, [good])
        XCTAssertEqual(recovery.keptCount, 1)
        XCTAssertEqual(recovery.quarantinedCount, 2)
        XCTAssertEqual(recovery.quarantinedFieldCount, 0)
        XCTAssertEqual(Set(recovery.issues.map(\.path)), Set(["parkedThoughts[1].text", "parkedThoughts[2].id"]))
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertEqual(try PlannerFile.decodeDocument(Data(contentsOf: recovery.recoveredURL)).parkedThoughts, [good])
    }

    func testRecoveryReportsInvalidParkingFieldsAndDoesNotResurrectNotes() throws {
        for parking in [NSNull(), "invalid"] as [Any] {
            let root: [String: Any] = [
                "version": 1, "parkedThoughts": parking, "notepadMigrationComplete": NSNull(),
                "notes": [["day": "2026-11-09", "text": "Already promoted"]],
            ]
            let bytes = try JSONSerialization.data(withJSONObject: root)
            try bytes.write(to: file.url)
            let recovery = try loadRecovery()
            XCTAssertTrue(recovery.recoveredPlanner.parkedThoughts.isEmpty)
            XCTAssertTrue(recovery.recoveredPlanner.notepadMigrationComplete)
            XCTAssertEqual(recovery.keptCount, 1)
            XCTAssertEqual(recovery.quarantinedCount, 0)
            XCTAssertEqual(recovery.quarantinedFieldCount, 2)
            XCTAssertEqual(Set(recovery.issues.map(\.path)), Set(["parkedThoughts", "notepadMigrationComplete"]))
            XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        }
    }

    func testRecoveryMigratesLegacyNotesExactlyOnce() throws {
        let bytes = Data(#"{"version":1,"tasks":[false],"notes":[{"day":"2026-11-09","text":"One\nTwo"}]}"#.utf8)
        try bytes.write(to: file.url)
        let recovery = try loadRecovery()
        XCTAssertEqual(recovery.recoveredPlanner.parkedThoughts.map(\.text), ["One", "Two"])
        let restored = try PlannerFile.decodeDocument(Data(contentsOf: recovery.recoveredURL))
        XCTAssertEqual(restored.parkedThoughts, recovery.recoveredPlanner.parkedThoughts)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }

    private func loadRecovery() throws -> PlannerRecoveryError {
        do {
            _ = try file.load()
            XCTFail("Expected recovery, not a silently reduced document")
        } catch let error as PlannerRecoveryError { return error }
        throw PlannerError("Expected a valid-record recovery draft.")
    }
}
