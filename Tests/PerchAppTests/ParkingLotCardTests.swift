import Foundation
import XCTest
@testable import PerchApp
@testable import PlannerCore

final class ParkingLotCardTests: XCTestCase {
    @MainActor func testEmptyAndPopulatedStatusCopy() async {
        XCTAssertEqual(ParkingLotEntry.summary(count: 0, hasTasks: true, blockActive: false), "Nothing parked yet")
        XCTAssertEqual(
            ParkingLotEntry.summary(count: 0, hasTasks: false, blockActive: false),
            "For anything that isn't a task yet")
        XCTAssertEqual(
            ParkingLotEntry.summary(count: 2, hasTasks: true, blockActive: true), "2 parked for after this block")
        XCTAssertEqual(ParkingLotEntry.summary(count: 1, hasTasks: true, blockActive: false), "1 parked")
        XCTAssertEqual(ParkingLotEntry.summary(count: 2, hasTasks: false, blockActive: false), "2 parked")
    }

    @MainActor func testReturnSavesLiteralThoughtAndClearsOnlyAfterSuccess() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = ParkingLotEntry()
        entry.draft = "  Think tomorrow at 9 for 20 min  "
        XCTAssertTrue(entry.save(in: store))
        XCTAssertEqual(entry.draft, "")
        XCTAssertEqual(store.planner.parkedThoughts.map(\.text), ["Think tomorrow at 9 for 20 min"])
        XCTAssertTrue(store.planner.tasks.isEmpty)
        XCTAssertEqual(try store.file.load().parkedThoughts, store.planner.parkedThoughts)
    }

    @MainActor func testEmptyAndFailedSubmissionKeepTheDraft() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = ParkingLotEntry()
        for draft in [" \n\t", String(repeating: "x", count: 20_001)] {
            entry.draft = draft
            XCTAssertFalse(entry.save(in: store))
            XCTAssertEqual(entry.draft, draft)
            XCTAssertTrue(store.planner.parkedThoughts.isEmpty)
        }
    }

    @MainActor func testPromotionUsesTodayAndLeavesOtherThoughtsAndDraftAlone() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = ParkingLotEntry()
        entry.draft = "First thought tomorrow at 9"
        XCTAssertTrue(entry.save(in: store))
        entry.draft = "Second thought"
        XCTAssertTrue(entry.save(in: store))
        let thoughts = store.planner.parkedThoughts
        entry.draft = "Still typing"
        XCTAssertTrue(entry.promote(thoughts[0].id, in: store))
        XCTAssertEqual(entry.draft, "Still typing")
        XCTAssertEqual(store.planner.parkedThoughts, [thoughts[1]])
        let task = try XCTUnwrap(store.planner.tasks.first)
        XCTAssertEqual(task.title, thoughts[0].text)
        XCTAssertEqual(task.day, store.today)
        XCTAssertEqual(task.parkedFrom, thoughts[0].id)
        XCTAssertNil(task.startAt)
        XCTAssertNil(task.remindAt)
        XCTAssertFalse(entry.promote(thoughts[0].id, in: store))
        XCTAssertEqual(store.planner.tasks.count, 1)
    }

    @MainActor private func makeStore() throws -> (PlannerStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        try file.save(Planner())
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        return (PlannerStore(file: file, now: { now }, watching: false), directory)
    }
}
