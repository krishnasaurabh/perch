import PlannerTestSupport
import Foundation
import XCTest
@testable import PlannerCore

/// Persistence is a cycle, not a one-shot. Reloading and saving repeatedly must be stable:
/// identical bytes when nothing changed, no lost records, and backups that stay bounded.
final class PlannerPersistenceCycleTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-cycles-\(UUID().uuidString)", isDirectory: true)
        file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let seedID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    private func seededPlanner() -> Planner {
        var p = Planner()
        p.tasks = [
            PlanTask(
                id: seedID, title: "Synthetic repeat template", day: "2026-11-05",
                createdAt: Fixture.date("2026-11-05 09:00"), remindAt: Fixture.date("2026-11-05 09:30"),
                priority: .high, notes: "Synthetic notes", repeatRule: .daily,
                steps: [Subtask(title: "Synthetic step", done: true)], focusedSeconds: 120,
                carryCount: 2, repeatAnchor: "2026-11-05"),
            PlanTask(
                title: "Synthetic inbox task", day: nil, createdAt: Fixture.date("2026-11-06 09:00"),
                deadline: "2026-11-20", priority: .low),
        ]
        p.projects = [
            TaskProject(
                id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
                name: "Synthetic project", colorHex: "#8E8CF5")
        ]
        p.notes = [QuickNote(day: "2026-11-09", text: "Synthetic note")]
        p.focusSegments = [
            FocusSegment(
                taskID: seedID, start: Fixture.date("2026-11-09 09:00"),
                end: Fixture.date("2026-11-09 09:05"))
        ]
        var focus = FocusSession(taskID: seedID, limit: 1500, now: Fixture.date("2026-11-09 09:00"))
        focus.state = .paused
        focus.resumedAt = nil
        focus.banked = 90
        p.focus = focus
        p.dismissedOverdue = [UUID(uuidString: "88888888-8888-8888-8888-888888888888")!]
        p.repeatOccurrences = [RepeatOccurrence(seriesID: seedID, day: "2026-11-06")]
        p.completedCalendarEventIDs = ["synthetic-event-1", "synthetic-event-2"]
        p.completedCalendarEventDays = ["synthetic-event-1": "2026-11-09", "synthetic-event-2": "2026-11-08"]
        p.preferences.carryMode = .auto
        p.preferences.defaultFocusMinutes = 40
        p.preferences.hiddenCalendarIDs = ["synthetic-calendar"]
        return p
    }

    private func recordCount(_ p: Planner) -> Int {
        p.tasks.count + p.projects.count + p.notes.count + p.focusSegments.count
            + p.dismissedOverdue.count + p.repeatOccurrences.count
            + p.completedCalendarEventIDs.count + p.completedCalendarEventDays.count
            + (p.focus == nil ? 0 : 1)
    }

    func testRepeatedLoadSaveCyclesAreByteStableAndNeverShrink() throws {
        let seeded = seededPlanner()
        try file.save(seeded)
        let firstBytes = try Data(contentsOf: file.url)
        let firstMtime = try XCTUnwrap(file.modificationDate)
        var counts: [Int] = []

        for cycle in 0..<8 {
            let loaded = try file.load()
            XCTAssertEqual(loaded, seeded, "cycle \(cycle) changed the document")
            try file.save(loaded)
            XCTAssertEqual(try Data(contentsOf: file.url), firstBytes, "cycle \(cycle) rewrote identical data")
            counts.append(recordCount(loaded))
        }

        XCTAssertEqual(counts, Array(repeating: recordCount(seeded), count: 8), "a cycle lost records")
        XCTAssertEqual(try file.load(), seeded)
        XCTAssertTrue(try file.backupURLs().isEmpty, "A no-op save must not consume a backup slot")
        XCTAssertEqual(file.modificationDate, firstMtime)
    }

    func testRepeatedMutationCyclesKeepEveryEarlierRecordAndBoundBackups() throws {
        let seeded = seededPlanner()
        try file.save(seeded)
        var expectedNotes = seeded.notes.count
        var expectedTasks = seeded.tasks.count

        for cycle in 0..<10 {
            try file.mutate { p in
                p.notes.append(QuickNote(day: "2026-11-09", text: "Synthetic cycle note \(cycle)"))
                p.tasks.append(
                    PlanTask(
                        title: "Synthetic cycle task \(cycle)", day: "2026-11-09",
                        createdAt: Fixture.now))
            }
            expectedNotes += 1
            expectedTasks += 1
            let loaded = try file.load()
            XCTAssertEqual(loaded.notes.count, expectedNotes, "cycle \(cycle) lost notes")
            XCTAssertEqual(loaded.tasks.count, expectedTasks, "cycle \(cycle) lost tasks")
            XCTAssertEqual(loaded.projects, seeded.projects)
            XCTAssertEqual(loaded.focusSegments, seeded.focusSegments)
            XCTAssertEqual(loaded.completedCalendarEventDays, seeded.completedCalendarEventDays)
            XCTAssertEqual(loaded.focus, seeded.focus)
            XCTAssertTrue(loaded.tasks.contains { $0.id == self.seedID })
            XCTAssertGreaterThanOrEqual(recordCount(loaded), recordCount(seeded) + cycle + 1)
        }

        let backups = try file.backupURLs()
        XCTAssertEqual(backups.count, PlannerFile.backupLimit, "Backups must stay bounded")
        for backup in backups {
            let data = try Data(contentsOf: backup)
            XCTAssertNoThrow(try PlannerFile.decodeDocument(data))
        }
        // Newest first: the previous revision is exactly one record pair smaller than the current one.
        let current = try file.load()
        let newest = try XCTUnwrap(backups.first)
        let previous = try PlannerFile.decodeDocument(Data(contentsOf: newest))
        XCTAssertEqual(previous.notes.count, current.notes.count - 1)
        XCTAssertEqual(previous.tasks.count, current.tasks.count - 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }
}
