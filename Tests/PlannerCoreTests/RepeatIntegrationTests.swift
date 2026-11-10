import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class RepeatIntegrationTests: XCTestCase {
    private func withoutAnchors(_ p: Planner) throws -> Planner {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: PlannerFile.encoder.encode(p)) as? [String: Any])
        var tasks = try XCTUnwrap(object["tasks"] as? [[String: Any]])
        for i in tasks.indices { tasks[i].removeValue(forKey: "repeatAnchor") }
        object["tasks"] = tasks
        return try PlannerFile.decoder.decode(Planner.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testEditingLegacyHistoryDoesNotReactivateIt() throws {
        var p = Planner()
        p.tasks = [
            PlanTask(title: "Review queue", day: "2026-11-09", done: true, repeatRule: .daily),
            PlanTask(title: "Review queue", day: "2026-11-10", repeatRule: .daily),
        ]
        var e = PlannerEngine(planner: try withoutAnchors(p), now: { Fixture.now }, calendar: Fixture.calendar)
        var edit = TaskEdit(); edit.notes = "Historical note"
        _ = try e.update(p.tasks[0].id.uuidString, on: .day("2026-11-09"), edit)
        XCTAssertEqual(e.applyRepeats(on: "2026-11-11").count, 1)
    }

    func testCompleteOverduePreservesLegacyActiveSchedule() throws {
        var p = Planner(); p.tasks = [PlanTask(title: "Review queue", day: "2026-11-09", repeatRule: .weekly)]
        var e = PlannerEngine(
            planner: try withoutAnchors(p), now: { Fixture.date("2026-11-10 15:00") }, calendar: Fixture.calendar)
        XCTAssertEqual(e.completeOverdue([p.tasks[0].id]).count, 1)
        let saved = try PlannerFile.decoder.decode(Planner.self, from: PlannerFile.encoder.encode(e.planner))
        e = PlannerEngine(planner: saved, now: { Fixture.date("2026-11-10 15:00") }, calendar: Fixture.calendar)
        XCTAssertEqual(e.applyRepeats(on: "2026-11-16").count, 1)
    }

    func testLegacyCompletedHistoryDoesNotCreateAdditionalLiveSeries() throws {
        var p = Planner()
        p.tasks = [
            PlanTask(
                title: "Review queue", day: "2026-11-09", done: true, completedAt: Fixture.now, repeatRule: .daily),
            PlanTask(title: "Review queue", day: "2026-11-10", repeatRule: .daily),
        ]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: PlannerFile.encoder.encode(p)) as? [String: Any])
        var tasks = try XCTUnwrap(object["tasks"] as? [[String: Any]])
        for i in tasks.indices {
            tasks[i].removeValue(forKey: "repeatAnchor"); tasks[i].removeValue(forKey: "repeatedFrom")
        }
        object["tasks"] = tasks
        let legacy = try PlannerFile.decoder.decode(Planner.self, from: JSONSerialization.data(withJSONObject: object))
        var e = PlannerEngine(planner: legacy, now: { Fixture.now }, calendar: Fixture.calendar)
        XCTAssertEqual(e.applyRepeats(on: "2026-11-11").count, 1)
        XCTAssertTrue(e.planner.tasks[0].done)
        XCTAssertEqual(e.planner.tasks[0].id, p.tasks[0].id)
    }

    func testIndependentLegacyIdenticalTitleSeriesStayIndependent() throws {
        var p = Planner()
        p.tasks = (0..<2).map { _ in PlanTask(title: "Review queue", day: "2026-11-09", repeatRule: .daily) }
        var e = PlannerEngine(planner: p, now: { Fixture.now }, calendar: Fixture.calendar)
        XCTAssertEqual(e.applyRepeats(on: "2026-11-10").count, 2)
    }

    func testCarriedScheduledRepeatKeepsCadence() throws {
        let root = PlanTask(title: "Review queue", day: "2026-11-09", repeatRule: TaskRepeat(unit: .day, interval: 3))
        var p = Planner(); p.tasks = [root]
        var e = PlannerEngine(planner: p, now: { Fixture.date("2026-11-10 15:00") }, calendar: Fixture.calendar)
        let copy = try XCTUnwrap(e.carryForward([root.id], to: "2026-11-10").first)
        _ = try e.complete(copy.id.uuidString)
        _ = e.applyRepeats(on: "2026-11-12")
        XCTAssertEqual(e.planner.tasks.compactMap(\.day).filter { $0 > "2026-11-10" }, ["2026-11-12"])
    }

    func testCompletionRelativeCarryStillUsesCompletionDate() throws {
        let root = PlanTask(
            title: "Review queue", day: "2026-11-09",
            repeatRule: TaskRepeat(unit: .day, interval: 3, fromCompletion: true))
        var p = Planner(); p.tasks = [root]
        var e = PlannerEngine(planner: p, now: { Fixture.date("2026-11-10 15:00") }, calendar: Fixture.calendar)
        let copy = try XCTUnwrap(e.carryForward([root.id], to: "2026-11-10").first)
        _ = try e.complete(copy.id.uuidString)
        XCTAssertEqual(e.planner.tasks.compactMap(\.day).filter { $0 > "2026-11-10" }, ["2026-11-13"])
    }

    func testDeletingMonthlyRootPreservesAnchorAcrossReload() throws {
        var e = PlannerEngine(planner: Planner(), now: { Fixture.date("2026-01-31 15:00") }, calendar: Fixture.calendar)
        let root = try XCTUnwrap(e.addTasks(["Review queue every month"]).first)
        XCTAssertEqual(e.applyRepeats(on: "2026-02-28").count, 1)
        _ = try e.delete(root.id.uuidString, on: .day("2026-01-31"))
        let saved = try PlannerFile.decoder.decode(Planner.self, from: PlannerFile.encoder.encode(e.planner))
        e = PlannerEngine(planner: saved, now: { Fixture.date("2026-02-28 15:00") }, calendar: Fixture.calendar)
        XCTAssertEqual(e.applyRepeats(on: "2026-03-31").count, 1)
        XCTAssertTrue(e.applyRepeats(on: "2026-03-28").isEmpty)
    }

    func testLegacyLinkedMonthlyRootDeletedBeforeNextView() throws {
        let root = PlanTask(title: "Review queue", day: "2026-01-31", repeatRule: .monthly)
        let copy = PlanTask(title: "Review queue", day: "2026-02-28", repeatRule: .monthly, repeatedFrom: root.id)
        var p = Planner(); p.tasks = [root, copy]
        var e = PlannerEngine(planner: p, now: { Fixture.date("2026-01-31 15:00") }, calendar: Fixture.calendar)
        _ = try e.delete(root.id.uuidString, on: .day("2026-01-31"))
        XCTAssertEqual(e.applyRepeats(on: "2026-03-31").count, 1)
        XCTAssertTrue(e.applyRepeats(on: "2026-03-28").isEmpty)
    }

    func testRetiredCopyCannotStopNewRootGeneration() throws {
        var e = PlannerEngine(planner: Planner(), now: { Fixture.now }, calendar: Fixture.calendar)
        let root = try XCTUnwrap(e.addTasks(["Review queue every day"]).first)
        let copy = try XCTUnwrap(e.applyRepeats(on: "2026-11-10").first)
        var edit = TaskEdit(); edit.repeatRule = "weekly"
        _ = try e.update(root.id.uuidString, on: .day("2026-11-09"), edit)
        XCTAssertNil(e.planner.tasks.first { $0.id == copy.id }?.repeatRule)
        edit.repeatRule = "daily"
        _ = try e.update(copy.id.uuidString, on: .day("2026-11-10"), edit)
        XCTAssertEqual(e.planner.tasks.first { $0.id == root.id }?.repeatRule, .weekly)
        let saved = try PlannerFile.decoder.decode(Planner.self, from: PlannerFile.encoder.encode(e.planner))
        e = PlannerEngine(planner: saved, now: { Fixture.now }, calendar: Fixture.calendar)
        XCTAssertEqual(e.applyRepeats(on: "2026-11-16").count, 2)
    }

    func testEndingInactiveLegacyCopyDoesNotStopActiveRoot() throws {
        let root = PlanTask(title: "Review queue", day: "2026-11-09", repeatRule: .weekly)
        let copy = PlanTask(title: "Review queue", day: "2026-11-10", repeatedFrom: root.id)
        var p = Planner(); p.tasks = [root, copy]
        var e = PlannerEngine(planner: p, now: { Fixture.now }, calendar: Fixture.calendar)
        try e.endRepeat(of: copy.id)
        XCTAssertEqual(e.planner.tasks[0].repeatRule, .weekly)
    }

    func testMovingMonthlyRootDoesNotReanchorSchedule() throws {
        var e = PlannerEngine(planner: Planner(), now: { Fixture.date("2026-01-31 15:00") }, calendar: Fixture.calendar)
        let root = try XCTUnwrap(e.addTasks(["Review queue every month"]).first)
        _ = try e.move(root.id.uuidString, from: .day("2026-01-31"), to: .day("2026-02-02"))
        XCTAssertEqual(e.applyRepeats(on: "2026-02-28").count, 1)
        XCTAssertTrue(e.applyRepeats(on: "2026-03-02").isEmpty)
    }

    func testOffPhaseBiweeklyCarryKeepsScheduledWeek() throws {
        let rule = TaskRepeat(unit: .week, interval: 2, weekdays: [2, 4])
        let root = PlanTask(title: "Review queue", day: "2026-11-09", repeatRule: rule)
        var p = Planner(); p.tasks = [root]
        var e = PlannerEngine(planner: p, now: { Fixture.date("2026-11-16 15:00") }, calendar: Fixture.calendar)
        let copy = try XCTUnwrap(e.carryForward([root.id], to: "2026-11-16").first)
        _ = try e.complete(copy.id.uuidString)
        XCTAssertEqual(e.planner.tasks.compactMap(\.day).filter { $0 > "2026-11-16" }, ["2026-11-23"])
    }
}
