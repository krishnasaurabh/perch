import Foundation
@testable import PlannerCore
import PerchMCP
import XCTest

final class CommandEntryTests: XCTestCase {
    func testMCPAndTypedEntryRejectSamePastDayMutations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = PlanTask(title: "Historical fixture", day: DayKey(now).adding(days: -1), createdAt: now)
        var planner = Planner(); planner.tasks = [old]
        let file = PlannerFile(url: root.appendingPathComponent("planner.json"))
        try file.save(planner)
        let tools = AgentTools(file: file, now: { now })
        let commands = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { now })
        for (tool, args, action): (String, JSON, PlannerAction) in [
            ("rename_task", ["task": .string(old.id.uuidString), "title": "No"], .rename(old.id, "No")),
            ("delete_task", ["task": .string(old.id.uuidString)], .delete(old.id)),
            ("complete_task", ["task": .string(old.id.uuidString)], .complete(old.id)),
            ("start_timer", ["task": .string(old.id.uuidString)], .startTimer(old.id, minutes: nil)),
        ] {
            XCTAssertThrowsError(try tools.call(tool, args))
            XCTAssertThrowsError(try commands.execute(action, origin: .user))
            XCTAssertEqual(try file.load(), planner)
        }
    }

    func testShortIDCollisionIsAnErrorNotFirstMatch() throws {
        let day = DayKey(Date())
        var planner = Planner()
        planner.tasks = [
            PlanTask(id: UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000001")!, title: "One", day: day),
            PlanTask(id: UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000002")!, title: "Two", day: day),
        ]
        XCTAssertThrowsError(try TaskReferenceResolver.resolve("abcdef00", in: planner, on: .day(day)))
        XCTAssertEqual(
            try TaskReferenceResolver.resolve(planner.tasks[1].id.uuidString, in: planner, on: .day(day)),
            planner.tasks[1].id)
    }
}
