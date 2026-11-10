import Foundation
import XCTest
@testable import PlannerCore

/// Migration contract: keys that did not exist in older files fall back to their documented
/// defaults, while every key that is present keeps its persisted value.
final class PlannerLegacyDefaultsTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-legacy-\(UUID().uuidString)", isDirectory: true)
        file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A minimal version-1 document: no focus, no projects, no repeat or calendar bookkeeping,
    /// and none of the optional task keys added later.
    private let minimalVersionOne = #"""
        {
          "version": 1,
          "tasks": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "Synthetic legacy task",
              "day": "2026-11-09",
              "createdAt": "2026-11-09T22:00:00Z"
            },
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "title": "Synthetic legacy inbox task",
              "createdAt": "2026-11-09T22:00:00Z",
              "done": true,
              "priority": "high",
              "notes": "Persisted text stays"
            }
          ],
          "preferences": {"defaultFocusMinutes": 50}
        }
        """#

    func testMissingOptionalLegacyKeysLoadWithMigrationDefaults() throws {
        let raw = Data(minimalVersionOne.utf8)
        try raw.write(to: file.url)

        let p = try file.load()
        XCTAssertEqual(p.version, Planner.currentVersion)
        XCTAssertEqual(p.tasks.count, 2)
        XCTAssertEqual(p.projects, [])
        XCTAssertEqual(p.notes, [])
        XCTAssertEqual(p.focusSegments, [])
        XCTAssertNil(p.focus)
        XCTAssertEqual(p.dismissedOverdue, [])
        XCTAssertEqual(p.repeatOccurrences, [])
        XCTAssertEqual(p.completedCalendarEventIDs, [])
        XCTAssertEqual(p.completedCalendarEventDays, [:])

        // Absent preferences migrate; the present one is retained.
        XCTAssertEqual(p.preferences.defaultFocusMinutes, 50)
        XCTAssertEqual(p.preferences.resetHour, 0)
        XCTAssertEqual(p.preferences.carryMode, .ask)
        XCTAssertEqual(p.preferences.workspaceCardOrder, ["focus", "events", "notepad"])
        XCTAssertEqual(p.preferences.hiddenWorkspaceCards, ["notepad"])
        XCTAssertEqual(p.preferences.hiddenCalendarIDs, [])
        XCTAssertFalse(p.preferences.remindersSync)

        let first = p.tasks[0]
        XCTAssertEqual(first.day, "2026-11-09")
        XCTAssertEqual(first.createdAt, Fixture.date("2026-11-09 14:00"))
        XCTAssertFalse(first.done)
        XCTAssertEqual(first.priority, .none)
        XCTAssertEqual(first.notes, "")
        XCTAssertEqual(first.steps, [])
        XCTAssertEqual(first.focusedSeconds, 0)
        XCTAssertEqual(first.carryCount, 0)
        XCTAssertNil(first.completedAt)
        XCTAssertNil(first.remindAt)
        XCTAssertNil(first.deadline)
        XCTAssertNil(first.projectID)
        XCTAssertNil(first.repeatRule)
        XCTAssertNil(first.repeatAnchor)
        XCTAssertNil(first.repeatedFrom)
        XCTAssertNil(first.minutes)
        XCTAssertNil(first.carriedFrom)
        XCTAssertNil(first.reminderLink)
        XCTAssertNil(first.agentID)

        // Present values are not replaced by defaults.
        let second = p.tasks[1]
        XCTAssertTrue(second.done)
        XCTAssertEqual(second.priority, .high)
        XCTAssertEqual(second.notes, "Persisted text stays")
        XCTAssertTrue(second.isInbox)

        // Loading a legacy file must not rewrite it.
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
        XCTAssertTrue(try file.backupURLs().isEmpty)
    }

    func testLegacyDefaultsSurviveSaveAndReloadWithoutShrinking() throws {
        try Data(minimalVersionOne.utf8).write(to: file.url)
        let loaded = try file.load()
        try file.save(loaded)

        let saved = try Data(contentsOf: file.url)
        let text = String(decoding: saved, as: UTF8.self)
        XCTAssertFalse(text.contains("null"), "Nil legacy keys should be omitted, not written as null")

        let reloaded = try file.load()
        XCTAssertEqual(reloaded, loaded)
        XCTAssertEqual(reloaded.tasks.map(\.title), ["Synthetic legacy task", "Synthetic legacy inbox task"])
        XCTAssertEqual(reloaded.preferences.defaultFocusMinutes, 50)
    }

    func testDocumentWithoutVersionKeyLoadsAsTheCurrentSchema() throws {
        let raw = Data(#"{"tasks":[],"preferences":{}}"#.utf8)
        try raw.write(to: file.url)
        XCTAssertEqual(try file.load(), Planner())
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
    }

    func testLegacyRepeatRuleWithoutAnchorStillSchedulesFromItsStoredDay() throws {
        // repeatAnchor arrived after repeatRule. A legacy task has no anchor, so scheduling
        // must fall back to the stored day instead of refusing to repeat.
        let legacy = #"""
            {"version":1,"tasks":[{"id":"33333333-3333-3333-3333-333333333333","title":"Legacy daily","day":"2026-11-09","createdAt":"2026-11-09T22:00:00Z","repeatRule":{"unit":"day","interval":1,"weekdays":[],"weekdaysOnly":false,"fromCompletion":false}}]}
            """#
        try Data(legacy.utf8).write(to: file.url)
        let planner = try file.load()
        let template = try XCTUnwrap(planner.tasks.first)
        XCTAssertNil(template.repeatAnchor)
        XCTAssertEqual(template.repeatRule, .daily)

        var engine = PlannerEngine(planner: planner, now: { Fixture.now }, calendar: Fixture.calendar)
        XCTAssertEqual(engine.nextRepeatDay(for: template), "2026-11-10")
        let copies = engine.applyRepeats(on: "2026-11-10")
        XCTAssertEqual(copies.map(\.day), ["2026-11-10"])
        // The migration default is materialized from the stored day, not invented.
        XCTAssertEqual(copies.first?.repeatAnchor, "2026-11-09")
        XCTAssertEqual(engine.planner.tasks.filter { $0.repeatSeriesID == template.repeatSeriesID }.count, 2)
    }
}
