import Foundation
@testable import PlannerCore
import PlannerTestSupport
import PerchMCP
import XCTest

final class TaskReferenceTests: XCTestCase {
    var engine = PlannerEngine(planner: Planner(), now: { Fixture.now }, calendar: Fixture.calendar)
    func testAmbiguousTitle() throws {
        _ = try engine.addTasks(["email alice", "email bob"])
        XCTAssertThrowsError(
            try engine.complete(try TaskReferenceResolver.resolve("email", in: engine.planner, on: .day(engine.today)))
        ) { e in
            XCTAssertTrue("\(e)".contains("Multiple tasks match"))
        }
        XCTAssertNoThrow(
            try engine.complete(
                try TaskReferenceResolver.resolve("email bob", in: engine.planner, on: .day(engine.today))))
    }

    func testShortIdLookup() throws {
        let t = try engine.addTasks(["a"]).first!
        let short = String(t.id.uuidString.prefix(8)).lowercased()
        XCTAssertEqual(
            try engine.complete(try TaskReferenceResolver.resolve(short, in: engine.planner, on: .day(engine.today)))
                .id, t.id)
    }

}
