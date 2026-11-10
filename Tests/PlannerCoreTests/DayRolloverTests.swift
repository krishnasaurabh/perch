import XCTest
@testable import PlannerCore

final class DayRolloverTests: XCTestCase {
    let cal = Fixture.calendar

    func testResetBoundaryAndDefaultMidnight() {
        let before = Fixture.date("2026-11-10 03:59")
        XCTAssertEqual(DayKey(before, calendar: cal), "2026-11-10")
        XCTAssertEqual(DayKey(before, resetHour: 4, calendar: cal), "2026-11-09")
        XCTAssertEqual(DayKey(Fixture.date("2026-11-10 04:00"), resetHour: 4, calendar: cal), "2026-11-10")
    }

    func testRolloverUsesLocalCalendarAcrossDST() {
        for (date, expected) in [("2026-03-08 03:30", "2026-03-07"), ("2026-11-01 03:30", "2026-10-31")] {
            XCTAssertEqual(DayKey(Fixture.date(date), resetHour: 4, calendar: cal).raw, expected)
        }
        XCTAssertEqual(DayKey(Fixture.date("2026-03-08 03:00"), resetHour: 2, calendar: cal), "2026-03-08")
    }

    func testRelativeDaysCaptureAndEngineShareLogicalToday() throws {
        let now = Fixture.date("2026-11-10 02:00")
        var p = Planner(); p.preferences.resetHour = 4
        var e = PlannerEngine(planner: p, now: { now }, calendar: cal)
        XCTAssertEqual(e.today, "2026-11-09")
        XCTAssertEqual(try DayRef.parse("tomorrow", now: now, resetHour: 4, calendar: cal), .day("2026-11-10"))
        XCTAssertEqual(try DayRef.parse("yesterday", now: now, resetHour: 4, calendar: cal), .day("2026-11-08"))
        let capture = TaskCapture(now: now, resetHour: 4, calendar: cal)
        XCTAssertEqual(capture.parse("work today").day, "2026-11-09")
        XCTAssertEqual(capture.parse("work tomorrow").day, "2026-11-10")
        XCTAssertEqual(capture.parse("work due today").deadline, "2026-11-09")
        let t = try e.addTasks(["work"]).first!
        XCTAssertEqual(t.day, "2026-11-09")
        XCTAssertTrue(e.overdue().isEmpty)
        XCTAssertNoThrow(try e.writeNotepad(on: "2026-11-09", text: "still today"))
        XCTAssertNoThrow(try e.startTimer(task: t.id.uuidString, minutes: 5))
        XCTAssertNoThrow(try e.complete(t.id.uuidString))
        XCTAssertEqual(e.insights().today.completed, 1)
        XCTAssertThrowsError(try e.addTasks(["old"], on: .day("2026-11-08")))
    }

    func testRemindersBeforeResetBelongToPreviousLogicalDay() throws {
        let now = Fixture.date("2026-11-10 01:30")
        var p = Planner(); p.preferences.resetHour = 4
        var e = PlannerEngine(planner: p, now: { now }, calendar: cal)
        let t = try e.addTasks(["check in 20 minutes"]).first!
        XCTAssertEqual(t.day, "2026-11-09")
        XCTAssertEqual(Fixture.hm(t.remindAt), "2026-11-10 01:50")
        XCTAssertEqual(Fixture.hm(try e.parseReminder("3am", on: e.today)), "2026-11-10 03:00")
        var edit = TaskEdit(); edit.remindAt = "3am"
        XCTAssertEqual(try e.update(t.id.uuidString, on: .day(e.today), edit).day, "2026-11-09")
        XCTAssertEqual(try e.snooze(t.id.uuidString, minutes: 5).day, "2026-11-09")
        let capture = TaskCapture(now: now, resetHour: 4, calendar: cal)
        XCTAssertEqual(Fixture.hm(capture.parse("check today at 3am").remindAt), "2026-11-10 03:00")
        XCTAssertEqual(capture.parse("check at 3am").day, "2026-11-09")
        XCTAssertEqual(capture.parse("check at 9am").day, "2026-11-10")
    }

    func testResetHourClampsAndDecodesOldPreferences() throws {
        var p = Preferences(); p.resetHour = -4
        XCTAssertEqual(p.resetHour, 0)
        p.resetHour = 27
        XCTAssertEqual(p.resetHour, 23)
        XCTAssertEqual(try PlannerFile.decoder.decode(Preferences.self, from: Data("{}".utf8)).resetHour, 0)
        XCTAssertEqual(
            try PlannerFile.decoder.decode(Preferences.self, from: Data(#"{"resetHour":30}"#.utf8)).resetHour, 23)
    }

    func testAgentRelativeDatesUseSavedPreferences() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = PlannerFile(url: dir.appendingPathComponent("planner.json"))
        try file.mutate { $0.preferences.resetHour = 4 }
        let tools = AgentTools(file: file, now: { Fixture.date("2026-11-10 02:00") }, calendar: cal)
        _ = try tools.call("add_tasks", ["titles": ["work"], "date": "today"])
        _ = try tools.call("add_tasks", ["titles": ["later"], "date": "tomorrow"])
        _ = try tools.call("write_notepad", ["text": "notes", "date": "today"])
        let p = try file.load()
        XCTAssertEqual(p.tasks.map(\.day), ["2026-11-09", "2026-11-10"])
        XCTAssertEqual(p.notes.first?.day, "2026-11-09")
        XCTAssertTrue(try tools.call("list_tasks", [:]).contains("Today, 2026-11-09"))
    }
}
