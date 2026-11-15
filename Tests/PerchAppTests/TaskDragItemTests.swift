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
        // XCTest is an unregistered command-line host, not the installed app.
        // Verify the declarations that LaunchServices consumes from Perch.app.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let plist = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        let declarations = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        for type in [UTType.perchTask, UTType.perchParkedThought] {
            let matches = declarations.filter { $0["UTTypeIdentifier"] as? String == type.identifier }
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches.first?["UTTypeConformsTo"] as? [String], [UTType.data.identifier])
        }
    }
}
