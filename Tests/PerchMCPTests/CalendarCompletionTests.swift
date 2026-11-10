import PlannerTestSupport
import XCTest
@testable import PlannerCore
import PerchMCP

final class CalendarCompletionTests: XCTestCase {
    func testOldPlannerDefaultsToNoCompletedEvents() throws {
        let legacy = #"""
            {"version":1,"tasks":[
              {"id":"11111111-1111-1111-1111-111111111111","title":"Old task","day":"2026-11-09","createdAt":"2026-11-09T22:00:00Z"},
              {"id":"22222222-2222-2222-2222-222222222222","title":"Inbox task","createdAt":"2026-11-09T22:00:00Z"}
            ],"preferences":{"defaultFocusMinutes":50}}
            """#
        let planner = try PlannerFile.decoder.decode(Planner.self, from: Data(legacy.utf8))
        XCTAssertTrue(planner.completedCalendarEventIDs.isEmpty)
        XCTAssertTrue(planner.completedCalendarEventDays.isEmpty)
        XCTAssertEqual(planner.tasks.count, 2)
        XCTAssertEqual(planner.preferences.defaultFocusMinutes, 50)
    }

    func testCompletionIsIdempotentAndDoesNotChangeTasksOrFocus() throws {
        var time = Fixture.now
        var engine = PlannerEngine(planner: Planner(), now: { time }, calendar: Fixture.calendar)
        let task = try XCTUnwrap(engine.addTasks(["Keep this task"], on: .day(engine.today)).first)
        try engine.startTimer(task: task.id.uuidString, minutes: 25)
        let tasks = engine.planner.tasks
        let focus = engine.planner.focus

        try engine.setCalendarEventCompleted("series-1/occurrence-1", completed: true)
        time += 86_400
        try engine.setCalendarEventCompleted("series-1/occurrence-1", completed: true)

        XCTAssertEqual(engine.planner.completedCalendarEventIDs, ["series-1/occurrence-1"])
        XCTAssertEqual(engine.planner.completedCalendarEventDays["series-1/occurrence-1"], "2026-11-09")
        XCTAssertEqual(engine.planner.tasks, tasks)
        XCTAssertEqual(engine.planner.focus, focus)
    }

    func testReopeningOnlyRemovesTheSelectedOccurrence() throws {
        var engine = PlannerEngine(planner: Planner(), now: { Fixture.now }, calendar: Fixture.calendar)
        for id in ["series-1/occurrence-1", "series-1/occurrence-2", "series-2/occurrence-1"] {
            try engine.setCalendarEventCompleted(id, completed: true)
        }
        try engine.setCalendarEventCompleted("series-1/occurrence-1", completed: false)
        try engine.setCalendarEventCompleted("series-1/occurrence-1", completed: false)
        XCTAssertEqual(engine.planner.completedCalendarEventIDs, ["series-1/occurrence-2", "series-2/occurrence-1"])
        XCTAssertNil(engine.planner.completedCalendarEventDays["series-1/occurrence-1"])
        XCTAssertEqual(engine.insights().allTimeCompletedCalendarEvents, 2)
    }

    func testInvalidIDDoesNotChangePlannerAndValidIDIsNotNormalized() throws {
        var engine = PlannerEngine(planner: Planner(), now: { Fixture.now }, calendar: Fixture.calendar)
        let before = engine.planner
        for invalid in ["", " \n\t"] {
            XCTAssertThrowsError(try engine.setCalendarEventCompleted(invalid, completed: true))
        }
        XCTAssertEqual(engine.planner, before)
        try engine.setCalendarEventCompleted(" EventKit-ID ", completed: true)
        XCTAssertTrue(engine.planner.completedCalendarEventIDs.contains(" EventKit-ID "))
    }

    func testLockedWritesReloadAndPreserveUnrelatedChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = PlannerFile(url: dir.appendingPathComponent("planner.json"))
        let otherProcess = PlannerFile(url: file.url)
        try file.mutate { planner in
            var engine = PlannerEngine(planner: planner, now: { Fixture.now }, calendar: Fixture.calendar)
            try engine.setCalendarEventCompleted("event-1", completed: true)
            planner = engine.planner
        }
        try otherProcess.mutate { $0.tasks.append(PlanTask(title: "External task", day: "2026-11-09")) }
        try file.mutate { planner in
            var engine = PlannerEngine(planner: planner, now: { Fixture.now }, calendar: Fixture.calendar)
            try engine.setCalendarEventCompleted("event-2", completed: true)
            planner = engine.planner
        }
        let loaded = try otherProcess.load()
        XCTAssertEqual(loaded.completedCalendarEventIDs, ["event-1", "event-2"])
        XCTAssertEqual(loaded.completedCalendarEventDays, ["event-1": "2026-11-09", "event-2": "2026-11-09"])
        XCTAssertEqual(loaded.tasks.map(\.title), ["External task"])
        XCTAssertEqual(try PlannerFile.decoder.decode(Planner.self, from: PlannerFile.encoder.encode(loaded)), loaded)
    }

    func testInsightsCountEventsSeparatelyFromTaskMetricsAcrossRollover() throws {
        var time = Fixture.date("2026-11-09 03:30")
        var planner = Planner()
        planner.preferences.resetHour = 4
        var engine = PlannerEngine(planner: planner, now: { time }, calendar: Fixture.calendar)
        try engine.setCalendarEventCompleted("yesterday", completed: true)
        time = Fixture.date("2026-11-09 04:30")
        try engine.setCalendarEventCompleted("today", completed: true)
        let task = try XCTUnwrap(engine.addTasks(["Task"], on: .day(engine.today)).first)
        _ = try engine.complete(task.id.uuidString)
        let insights = engine.insights()
        XCTAssertEqual(insights.today.completedCalendarEvents, 1)
        XCTAssertEqual(insights.lastSeven.first { $0.day == "2026-11-08" }?.completedCalendarEvents, 1)
        XCTAssertEqual(insights.allTimeCompletedCalendarEvents, 2)
        XCTAssertEqual(insights.today.planned, 1)
        XCTAssertEqual(insights.today.completed, 1)
        XCTAssertEqual(insights.allTimeCompleted, 1)
        try engine.setCalendarEventCompleted("today", completed: false)
        XCTAssertEqual(engine.insights().today.completedCalendarEvents, 0)
        XCTAssertEqual(engine.insights().allTimeCompletedCalendarEvents, 1)
    }

    func testMCPInsightsReportPersistedCalendarCompletions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = PlannerFile(url: dir.appendingPathComponent("planner.json"))
        var engine = PlannerEngine(planner: Planner(), now: { Fixture.now }, calendar: Fixture.calendar)
        try engine.setCalendarEventCompleted("event", completed: true)
        try file.save(engine.planner)
        let server = MCPServer(
            tools: AgentTools(file: file, now: { Fixture.now }, calendar: Fixture.calendar), version: "test")
        let response = try XCTUnwrap(
            server.handle([
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "get_insights", "arguments": [:]],
            ]))
        let text = try XCTUnwrap(response["result"]?["content"]?.array?.first?["text"]?.string)
        XCTAssertEqual(response["result"]?["isError"]?.bool, false)
        XCTAssertTrue(text.contains("Today: 0/0 tasks done"), text)
        XCTAssertTrue(text.contains("Calendar events completed in Perch: 1 today, 1 all time."), text)
    }

    func testDuplicateSavedIDsCountOnceAndSurviveAnotherRoundTrip() throws {
        let json =
            #"{"completedCalendarEventIDs":["event","event"],"completedCalendarEventDays":{"event":"2026-11-09"}}"#
        let planner = try PlannerFile.decoder.decode(Planner.self, from: Data(json.utf8))
        let reloaded = try PlannerFile.decoder.decode(Planner.self, from: PlannerFile.encoder.encode(planner))
        let engine = PlannerEngine(planner: reloaded, now: { Fixture.now }, calendar: Fixture.calendar)
        XCTAssertEqual(engine.insights().today.completedCalendarEvents, 1)
        XCTAssertEqual(engine.insights().allTimeCompletedCalendarEvents, 1)
    }

    func testUndatedImportedIDsCountAllTimeWithoutInventingADay() {
        var planner = Planner()
        planner.completedCalendarEventIDs = ["imported"]
        planner.completedCalendarEventDays = ["orphan": "2026-11-09"]
        let engine = PlannerEngine(planner: planner, now: { Fixture.now }, calendar: Fixture.calendar)
        XCTAssertEqual(engine.insights().allTimeCompletedCalendarEvents, 1)
        XCTAssertEqual(engine.insights().today.completedCalendarEvents, 0)
    }
}
