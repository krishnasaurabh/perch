import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class ParkingMigrationTests: XCTestCase {
    /// Frozen 1.2.0 disk shape: neither startAt nor parking fields existed.
    private let versionTwo = #"""
        {"version":2,"tasks":[{"id":"11111111-1111-4111-8111-111111111111","title":"Keep me",
        "day":"2026-11-09","done":false,"createdAt":"2026-11-09T17:00:00Z",
        "updatedAt":"2026-11-09T17:00:00Z","unloggedFocusedSeconds":12,"remindAt":"2026-11-09T18:00:00Z",
        "priority":"high","notes":"Task note","minutes":20,"steps":[],"focusedSeconds":12,"carryCount":2}],
        "taskOrder":["11111111-1111-4111-8111-111111111111"],"projects":[],
        "notes":[{"day":"2026-11-09","text":"Newer\n\n  Keep spaces  \nNewer"},
        {"day":"2026-11-06","text":"Oldest\r\nSecond\n \t"}],
        "focusHistory":[],"focusSegments":[],"focusRecentIndices":[],"dismissedOverdue":[],
        "repeatOccurrences":[],"completedCalendarEventIDs":[],"completedCalendarEventDays":{},"preferences":{}}
        """#

    func testOldFilesMigrateInDayAndLineOrderWithoutDroppingDuplicatesOrText() throws {
        let legacy = PlannerMigrationTests.legacyDocument
        for raw in [versionTwo, legacy] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = PlannerFile(
                url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
            try Data(raw.utf8).write(to: file.url)
            let first = try file.load()
            let again = try file.load()
            XCTAssertEqual(again, first, "Read-only migration identities must be stable")
            XCTAssertEqual(try Data(contentsOf: file.url), Data(raw.utf8), "Inspection never rewrites the source")
            XCTAssertTrue(first.tasks.allSatisfy { $0.startAt == nil })
            let expected =
                raw == versionTwo ? ["Oldest", "Second", "Newer", "  Keep spaces  ", "Newer"] : ["Original scratchpad"]
            XCTAssertEqual(first.parkedThoughts.map(\.text), expected)
            XCTAssertEqual(Set(first.parkedThoughts.map(\.id)).count, expected.count)
            XCTAssertTrue(first.notepadMigrationComplete)
            if raw == versionTwo {
                XCTAssertEqual(DayKey(first.parkedThoughts[0].createdAt), "2026-11-06")
                XCTAssertEqual(DayKey(first.parkedThoughts[2].createdAt), "2026-11-09")
            }
            try file.save(first)
            XCTAssertEqual(try file.load(), first, "1.2.0 data survives a new-format round trip")
            let encoded = try Data(contentsOf: file.url)
            try file.save(file.load())
            XCTAssertEqual(try Data(contentsOf: file.url), encoded)
            let exported = directory.appendingPathComponent("export.json")
            try file.export(to: exported)
            let portable = try PlannerFile.decodeDocument(Data(contentsOf: exported))
            XCTAssertEqual(portable.tasks, first.tasks)
            XCTAssertEqual(portable.parkedThoughts, first.parkedThoughts)
            XCTAssertEqual(portable.notes, first.notes)
            XCTAssertEqual(portable.focus, first.focus)
            XCTAssertEqual(portable.focusSegments, first.focusSegments)
            XCTAssertEqual(
                try PlannerFile.encoder.encode(SharedPlannerPreferences(portable.preferences)),
                try PlannerFile.encoder.encode(SharedPlannerPreferences(first.preferences)))
            let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { Fixture.now })
            try pipeline.execute(.emptyParkingLot, origin: .user)
            XCTAssertTrue(try file.load().parkedThoughts.isEmpty, "Retained notes must not repopulate an emptied lot")
            XCTAssertEqual(try file.load().notes, first.notes)
            _ = try pipeline.undo()
            XCTAssertEqual(try file.load().parkedThoughts, first.parkedThoughts)
        }
    }

    func testPromotedMigrationLineDoesNotReappearAndLegacyAPIStillReadsOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        try Data(versionTwo.utf8).write(to: file.url)
        let pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)
        let original = try file.load()
        try pipeline.execute(.promoteThought(original.parkedThoughts[0].id, day: nil, agentID: nil), origin: .user)
        XCTAssertEqual(try file.load().parkedThoughts.count, 4)
        XCTAssertEqual(try file.load().tasks.last?.title, "Oldest")
        let text = try pipeline.inspect { $0.read.notepad(on: "2026-11-09") }
        XCTAssertEqual(text, "Newer\n\n  Keep spaces  \nNewer")
        try pipeline.perform(origin: .user) {
            try $0.writeNotepad(on: "2026-11-09", text: "Still works", mode: "replace")
        }
        XCTAssertEqual(try pipeline.inspect { $0.read.notepad(on: "2026-11-09") }, "Still works")
        XCTAssertFalse(try file.load().parkedThoughts.contains { $0.id == original.parkedThoughts[0].id })
    }

    func testMalformedParkingAndStartFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        for fragment in ["\"parkedThoughts\":null", "\"parkedThoughts\":[false]", "\"notepadMigrationComplete\":null"] {
            let raw = versionTwo.replacingOccurrences(of: "\"version\":2", with: "\"version\":2," + fragment)
            try Data(raw.utf8).write(to: file.url)
            XCTAssertThrowsError(try file.load())
            XCTAssertThrowsError(try file.save(Planner()))
            XCTAssertEqual(try Data(contentsOf: file.url), Data(raw.utf8))
        }
        let raw = versionTwo.replacingOccurrences(of: "\"done\":false", with: "\"done\":false,\"startAt\":true")
        try Data(raw.utf8).write(to: file.url)
        XCTAssertThrowsError(try file.load())
        XCTAssertEqual(try Data(contentsOf: file.url), Data(raw.utf8))
    }
}
