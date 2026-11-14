import CoreTransferable
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import PerchApp

final class TaskDragItemTests: XCTestCase {
    func testIdentitiesRoundTripWithoutTaskContent() throws {
        let id = UUID()
        let task = TaskDragItem(taskID: id)
        let thought = ParkedThoughtDragItem(thoughtID: id)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let taskData = try encoder.encode(task), thoughtData = try encoder.encode(thought)
        XCTAssertEqual(try decoder.decode(TaskDragItem.self, from: taskData), task)
        XCTAssertEqual(try decoder.decode(ParkedThoughtDragItem.self, from: thoughtData), thought)
        XCTAssertThrowsError(try decoder.decode(TaskDragItem.self, from: thoughtData))
        XCTAssertThrowsError(try decoder.decode(ParkedThoughtDragItem.self, from: taskData))
        XCTAssertThrowsError(try decoder.decode(TaskDragItem.self, from: Data("{\"taskID\":\"invalid\"}".utf8)))
        XCTAssertNotEqual(UTType.perchTask, UTType.perchParkedThought)
        XCTAssertTrue(UTType.perchTask.conforms(to: .data))
        XCTAssertTrue(UTType.perchParkedThought.conforms(to: .data))
    }
}
