import XCTest
@testable import PlannerCore

final class RepeatLineageTests: XCTestCase {
    var clock = Fixture.now
    lazy var engine = PlannerEngine(planner: Planner(), now: { [unowned self] in self.clock }, calendar: Fixture.calendar)

    func testLazyDailyRepeatMaterializesOnlyViewedDayAndSurvivesReload() throws {
        let root = try engine.addTasks(["standup every day at 6pm"]).first!
        let copies = engine.applyRepeats(on: "2026-11-12")
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(engine.planner.tasks.count, 2, "do not fill intervening days")
        XCTAssertEqual(copies.first?.repeatedFrom, root.id)
        XCTAssertEqual(Fixture.hm(copies.first?.remindAt), "2026-11-12 18:00")
        XCTAssertTrue(engine.applyRepeats(on: "2026-11-12").isEmpty)
        let p = try PlannerFile.decoder.decode(Planner.self, from: PlannerFile.encoder.encode(engine.planner))
        var reloaded = PlannerEngine(planner: p, now: { Fixture.now }, calendar: Fixture.calendar)
        XCTAssertTrue(reloaded.applyRepeats(on: "2026-11-12").isEmpty)
        _ = try reloaded.delete(copies[0].id.uuidString, on: .day("2026-11-12"))
        XCTAssertTrue(reloaded.applyRepeats(on: "2026-11-12").isEmpty, "deleting an occurrence must not resurrect it")
        XCTAssertTrue(reloaded.applyRepeats(on: "2026-11-08").isEmpty)
    }

    func testIndependentIdenticalTitlesAndRenamedCopiesDeduplicateByLineage() throws {
        let roots = try engine.addTasks(["work every day", "work every day"])
        let copies = engine.applyRepeats(on: "2026-11-10")
        XCTAssertEqual(Set(copies.compactMap(\.repeatedFrom)), Set(roots.map(\.id)))
        _ = try engine.rename(copies[0].id.uuidString, on: .day("2026-11-10"), to: "different title")
        for root in roots { _ = try engine.complete(root.id.uuidString) }
        XCTAssertEqual(engine.tasks(on: .day("2026-11-10")).count, 2)
        _ = try engine.reopen(roots[0].id.uuidString)
        _ = try engine.complete(roots[0].id.uuidString)
        XCTAssertEqual(engine.tasks(on: .day("2026-11-10")).count, 2)
    }

    func testCompletionBeforeLazyViewDoesNotDuplicateAndResetsCopyProgress() throws {
        let root = try engine.addTasks(["work every day"]).first!
        engine.planner.tasks[0].steps = [Subtask(title: "step", done: true)]
        engine.planner.tasks[0].focusedSeconds = 30
        engine.planner.tasks[0].reminderLink = "external"
        _ = try engine.complete(root.id.uuidString)
        XCTAssertTrue(engine.applyRepeats(on: "2026-11-10").isEmpty)
        let copy = engine.tasks(on: .day("2026-11-10"))[0]
        XCTAssertEqual(copy.repeatedFrom, root.id)
        XCTAssertFalse(copy.done)
        XCTAssertNil(copy.completedAt); XCTAssertNil(copy.reminderLink)
        XCTAssertEqual(copy.focusedSeconds, 0)
        XCTAssertEqual(copy.carryCount, 0)
        XCTAssertFalse(copy.steps[0].done)
        XCTAssertNotEqual(copy.steps[0].id, root.steps.first?.id)
    }

    func testCadenceMatchesWeekdaysIntervalsAndOriginalMonthAnchor() {
        let cases: [(TaskRepeat, DayKey, DayKey, Bool)] = [
            (.weekdaysRule, "2026-11-09", "2026-11-14", false),
            (.weekdaysRule, "2026-11-09", "2026-11-16", true),
            (TaskRepeat(unit: .day, interval: 3), "2026-11-09", "2026-11-12", true),
            (TaskRepeat(unit: .day, interval: 3), "2026-11-09", "2026-11-13", false),
            (TaskRepeat(unit: .week, interval: 2, weekdays: [2, 4]), "2026-11-09", "2026-11-18", false),
            (TaskRepeat(unit: .week, interval: 2, weekdays: [2, 4]), "2026-11-09", "2026-11-25", true),
            (.monthly, "2026-01-31", "2026-02-28", true),
            (.monthly, "2026-01-31", "2026-03-31", true),
            (.monthly, "2026-01-31", "2026-03-28", false),
        ]
        for (rule, start, day, expected) in cases {
            var p = Planner(); p.tasks = [PlanTask(title: "repeat", day: start, repeatRule: rule)]
            var e = PlannerEngine(planner: p, now: { Fixture.now }, calendar: Fixture.calendar)
            XCTAssertEqual(!e.applyRepeats(on: day).isEmpty, expected, "\(rule) from \(start) on \(day)")
        }
    }

    func testCompletionRelativeRepeatWaitsForCompletion() throws {
        let root = try engine.addTasks(["water every! 3 days"]).first!
        XCTAssertTrue(engine.applyRepeats(on: "2026-11-12").isEmpty)
        _ = try engine.complete(root.id.uuidString)
        XCTAssertEqual(engine.tasks(on: .day("2026-11-12")).count, 1)
        XCTAssertTrue(engine.applyRepeats(on: "2026-11-15").isEmpty)
    }

    func testEndRepeatOnAnyCopyStopsWholeSeriesButKeepsPlannedTasks() throws {
        let root = try engine.addTasks(["work every day"]).first!
        let copy = engine.applyRepeats(on: "2026-11-10")[0]
        try engine.endRepeat(of: copy.id)
        XCTAssertTrue(engine.planner.tasks.allSatisfy { $0.repeatRule == nil })
        XCTAssertTrue(engine.applyRepeats(on: "2026-11-11").isEmpty)
        _ = try engine.complete(root.id.uuidString)
        XCTAssertEqual(engine.planner.tasks.count, 2)
        XCTAssertNoThrow(try engine.endRepeat(of: root.id))
        XCTAssertThrowsError(try engine.endRepeat(of: UUID()))
    }

    func testUpdateRepeatNoneStopsSeriesAndReenableStartsAtEditedTask() throws {
        let root = try engine.addTasks(["work every day"]).first!
        _ = engine.applyRepeats(on: "2026-11-10")
        var edit = TaskEdit(); edit.repeatRule = "none"
        _ = try engine.update(root.id.uuidString, on: .day(engine.today), edit)
        XCTAssertTrue(engine.applyRepeats(on: "2026-11-11").isEmpty)
        XCTAssertTrue(engine.planner.tasks.allSatisfy { $0.repeatRule == nil })
    }

    func testCarryIncrementsCountPreservesAgentAndDoesNotDuplicate() {
        let root = PlanTask(title: "work", day: "2026-11-07", agentID: "claude-code")
        engine.planner.tasks = [root]
        let copy = engine.carryForward([root.id, root.id], to: "2026-11-08")
        XCTAssertEqual(copy.count, 1)
        XCTAssertEqual(copy.first?.carryCount, 1)
        XCTAssertEqual(copy.first?.agentID, "claude-code")
        XCTAssertTrue(engine.carryForward([root.id], to: "2026-11-08").isEmpty)
        let next = engine.carryForward([copy[0].id], to: "2026-11-09")
        XCTAssertEqual(next.first?.carryCount, 2)
    }

    func testRepeatsCarryAgentButNotCarryCountAndUseResetForReminder() {
        var p = Planner(); p.preferences.resetHour = 4
        let root = PlanTask(title: "work", day: "2026-11-09", remindAt: Fixture.date("2026-11-10 01:00"),
                            repeatRule: .daily, carryCount: 2, agentID: "cursor")
        p.tasks = [root]
        var e = PlannerEngine(planner: p, now: { Fixture.now }, calendar: Fixture.calendar)
        let copy = e.applyRepeats(on: "2026-11-10")[0]
        XCTAssertEqual(Fixture.hm(copy.remindAt), "2026-11-11 01:00")
        XCTAssertEqual(copy.agentID, "cursor")
        XCTAssertEqual(copy.carryCount, 0)
    }

    func testMonthlyCompletionAndLazyViewShareOriginalAnchor() throws {
        clock = Fixture.date("2026-01-31 15:00")
        let root = try engine.addTasks(["review every month"]).first!
        _ = try engine.complete(root.id.uuidString)
        let feb = engine.tasks(on: .day("2026-02-28"))[0]
        clock = Fixture.date("2026-02-28 15:00")
        _ = try engine.complete(feb.id.uuidString)
        XCTAssertTrue(engine.tasks(on: .day("2026-03-28")).isEmpty)
        XCTAssertEqual(engine.tasks(on: .day("2026-03-31")).count, 1)
        XCTAssertTrue(engine.applyRepeats(on: "2026-03-31").isEmpty)
    }

    func testEditingRepeatCadenceReanchorsAtEditedOccurrence() throws {
        _ = try engine.addTasks(["work every day"])
        let copy = engine.applyRepeats(on: "2026-11-10")[0]
        var edit = TaskEdit(); edit.repeatRule = "weekly"
        _ = try engine.update(copy.id.uuidString, on: .day("2026-11-10"), edit)
        XCTAssertTrue(engine.applyRepeats(on: "2026-11-11").isEmpty)
        XCTAssertEqual(engine.applyRepeats(on: "2026-11-17").count, 1)
    }

    func testCarryDoesNotDuplicateAlreadyMaterializedRepeat() {
        engine.planner.tasks = [PlanTask(title: "work", day: "2026-11-08", repeatRule: .daily)]
        let root = engine.planner.tasks[0]
        _ = engine.applyRepeats(on: "2026-11-09")
        XCTAssertTrue(engine.carryForward([root.id], to: "2026-11-09").isEmpty)
        XCTAssertEqual(engine.tasks(on: .day("2026-11-09")).count, 1)
        XCTAssertTrue(engine.overdue().isEmpty)
    }

    func testMCPClientNameIsSessionScopedAndNotAnArgument() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = PlannerFile(url: dir.appendingPathComponent("planner.json"))
        let tools = AgentTools(file: file, now: { Fixture.now }, calendar: Fixture.calendar)
        let server = MCPServer(tools: tools, version: "test")
        _ = server.handle(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "claude-code", "version": "1"]]])
        _ = server.handle(["id": 2, "method": "tools/call", "params": ["name": "add_tasks", "arguments": ["titles": ["agent task"], "agentID": "forged"]]])
        _ = try tools.call("add_tasks", ["titles": ["direct task"]])
        let other = MCPServer(tools: tools, version: "test")
        _ = other.handle(["id": 3, "method": "tools/call", "params": ["name": "add_tasks", "arguments": ["titles": ["other task"]]]])
        XCTAssertEqual(try file.load().tasks.map(\.agentID), ["claude-code", nil, nil])
    }

    func testMCPListMaterializesRepeatsAndPersistsIdempotently() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = PlannerFile(url: dir.appendingPathComponent("planner.json"))
        let tools = AgentTools(file: file, now: { Fixture.now }, calendar: Fixture.calendar)
        _ = try tools.call("add_tasks", ["titles": ["standup every day"]])
        for _ in 0..<2 {
            XCTAssertTrue(try tools.call("list_tasks", ["date": "2026-11-12"]).contains("Standup"))
        }
        XCTAssertEqual(try file.load().tasks.count, 2)
    }
}
