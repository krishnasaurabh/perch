import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class PlannerMigrationTests: XCTestCase {
    // Frozen version-1 shape, including populated tasks. An empty tasks array would hide
    // a failed nested PlanTask decode because legacy Planner decoding defaults that array.
    var versionOne: String { Self.legacyDocument }
    static let legacyDocument = #"""
        {
          "version": 1,
          "tasks": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "Review report", "day": "2026-11-09", "done": false,
              "createdAt": "2026-11-09T22:00:00Z", "remindAt": "2026-11-10T01:00:00Z",
              "deadline": "2026-11-13", "priority": "high",
              "projectID": "22222222-2222-2222-2222-222222222222", "notes": "Keep the original details",
              "repeatRule": {"unit":"day", "interval":1, "weekdays":[], "weekdaysOnly":false, "fromCompletion":false},
              "minutes": 25,
              "steps": [{"id":"33333333-3333-3333-3333-333333333333", "title":"Draft", "done":true}],
              "focusedSeconds": 90, "carriedFrom": "2026-11-08", "reminderLink": "reminder-123"
            },
            {
              "id": "44444444-4444-4444-4444-444444444444", "title": "Inbox idea", "done": false,
              "createdAt": "2026-11-09T22:00:00Z", "priority": "none", "notes": "", "steps": [], "focusedSeconds": 0
            }
          ],
          "projects": [{"id":"22222222-2222-2222-2222-222222222222", "name":"Work", "colorHex":"#8E8CF5"}],
          "notes": [{"day":"2026-11-09", "text":"Original scratchpad"}],
          "focusSegments": [{"taskID":"11111111-1111-1111-1111-111111111111", "start":"2026-11-09T22:00:00Z", "end":"2026-11-09T22:01:30Z"}],
          "focus": {"taskID":"11111111-1111-1111-1111-111111111111", "limit":1500, "state":"paused", "banked":90, "startedAt":"2026-11-09T22:00:00Z"},
          "dismissedOverdue": ["55555555-5555-5555-5555-555555555555"],
          "preferences": {
            "defaultFocusMinutes": 50, "focusCompletionSound": false, "notchTimerPlacement": "left",
            "workspaceTimerStyle":"digital", "notchOpenTrigger":"click", "notchOnMonitors":false,
            "showOnDisplay":"Studio", "remindersSync":true, "ringOnPhone":true, "sortWithAI":false,
            "includeWeekendsInStreak":false, "catchScreenshots":true, "catchCopies":true,
            "workspaceCardOrder":["focus","tasks"], "hiddenWorkspaceCards":["events"],
            "hiddenCalendarIDs":["personal"], "welcomeCompleted":true
          }
        }
        """#

    func testPopulatedCurrentFormatLoadsWithoutLosingAnyTaskOrPreference() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = PlannerFile(url: dir.appendingPathComponent("planner.json"))
        try Data(versionOne.utf8).write(to: file.url)
        let p = try file.load()
        XCTAssertEqual(p.version, 1)
        XCTAssertEqual(p.tasks.count, 2)
        let t = try XCTUnwrap(p.tasks.first)
        XCTAssertEqual(t.title, "Review report")
        XCTAssertEqual(t.day, "2026-11-09")
        XCTAssertEqual(t.repeatRule, .daily)
        XCTAssertEqual(t.focusedSeconds, 90)
        XCTAssertEqual(t.notes, "Keep the original details")
        XCTAssertEqual(t.reminderLink, "reminder-123")
        XCTAssertEqual(t.carriedFrom, "2026-11-08")
        XCTAssertEqual(t.priority, .high)
        XCTAssertEqual(t.steps.map(\.title), ["Draft"])
        XCTAssertTrue(t.steps[0].done)
        XCTAssertNil(t.repeatedFrom); XCTAssertNil(t.agentID)
        XCTAssertEqual(t.carryCount, 0)
        XCTAssertTrue(p.tasks[1].isInbox)
        XCTAssertTrue(p.repeatOccurrences.isEmpty)
        XCTAssertEqual(p.projects.first?.id, t.projectID)
        XCTAssertEqual(p.notes.first?.text, "Original scratchpad")
        XCTAssertEqual(p.focusLog.first?.seconds, 90)
        XCTAssertEqual(p.focus?.state, .paused)
        XCTAssertEqual(p.focus?.banked, 90)
        XCTAssertEqual(p.preferences.resetHour, 0)
        XCTAssertEqual(p.preferences.defaultFocusMinutes, 50)
        XCTAssertEqual(p.preferences.showOnDisplay, "Studio")
        XCTAssertEqual(p.preferences.workspaceCardOrder, ["focus", "tasks"])
        XCTAssertFalse(p.preferences.focusCompletionSound)
        XCTAssertEqual(p.preferences.workspaceTimerStyle, .digital)
        XCTAssertEqual(p.dismissedOverdue.count, 1)
        try file.save(p)
        XCTAssertEqual(try file.load(), p)
    }

    func testMigrationCanMaterializeLineageAndCheckpointThenReload() throws {
        let old = try PlannerFile.decoder.decode(Planner.self, from: Data(versionOne.utf8))
        var time = Fixture.now
        var e = PlannerEngine(planner: old, now: { time }, calendar: Fixture.calendar)
        let copy = try XCTUnwrap(e.applyRepeats(on: "2026-11-10").first)
        XCTAssertEqual(copy.repeatedFrom, old.tasks[0].id)
        XCTAssertEqual(copy.focusedSeconds, 0)
        try e.resumeTimer()
        time += 30
        XCTAssertTrue(e.checkpointFocus())
        e.planner.preferences.resetHour = 4
        let upgraded = try PlannerFile.decoder.decode(Planner.self, from: PlannerFile.encoder.encode(e.planner))
        XCTAssertEqual(upgraded, e.planner)
        XCTAssertEqual(upgraded.focusLog.reduce(0) { $0 + $1.seconds }, 120)
        XCTAssertEqual(upgraded.tasks.count, 3)
        XCTAssertEqual(upgraded.preferences.resetHour, 4)
    }

    func testISODatePersistenceRetainsFractionalPrecisionAndAcceptsOldDates() throws {
        for offset in [0.0, 0.000001, 0.123456789, 0.999999, 30.751234, -0.123456, 86400.125678] {
            var p = Planner()
            let date = Fixture.now.addingTimeInterval(offset)
            p.tasks = [PlanTask(title: "Precise", day: "2026-11-09", createdAt: date)]
            let data = try PlannerFile.encoder.encode(p)
            XCTAssertEqual(try PlannerFile.decoder.decode(Planner.self, from: data), p)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("2026-11-"))
        }
        let p = try PlannerFile.decoder.decode(Planner.self, from: Data(versionOne.utf8))
        XCTAssertEqual(p.tasks[0].createdAt, Fixture.date("2026-11-09 14:00"))
    }
}
