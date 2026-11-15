import Foundation
import PlannerCore
import XCTest
@testable import PerchUI

final class DropShelfStorageTests: XCTestCase {
    func testKeptFilesMigrateOnceWithoutRetentionDeletingThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("Notes.txt")
        try Data("Kept notes".utf8).write(to: original)
        let storage = ClipShelfFile(vault: root)
        let migrated = try storage.load()
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated[0].content, .file(original))
        XCTAssertEqual(try storage.load(), migrated, "Migration persists stable identities")
        XCTAssertEqual(try Data(contentsOf: original), Data("Kept notes".utf8))
        ClipVault.sweep(root, olderThan: .distantFuture, keeping: storage.retainedPaths(migrated))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try storage.load(), migrated)
    }

    func testFileURLImageAndTextRoundTripAndClearDoesNotReimportOldFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ClipShelfFile(vault: root)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let values = [
            ClipShelfFile.Item(content: .file(root.appendingPathComponent("original.pdf")), date: date, pinned: true),
            ClipShelfFile.Item(content: .text("https://example.com/notes"), date: date),
            ClipShelfFile.Item(content: .image(Data([1, 2, 3])), date: date),
            ClipShelfFile.Item(content: .text("A parked reference"), date: date),
        ]
        try storage.save(values)
        XCTAssertEqual(try storage.load(), values)
        try Data("Orphan".utf8).write(to: root.appendingPathComponent("orphan.txt"))
        try storage.save([])
        XCTAssertTrue(try storage.load().isEmpty, "An existing manifest, including empty, is authoritative")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("orphan.txt").path))
    }

    func testMalformedManifestIsNotReplacedWithAnEmptyShelf() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = ClipShelfFile(vault: root)
        let bytes = Data("not valid JSON".utf8)
        try bytes.write(to: storage.url)
        XCTAssertThrowsError(try storage.load())
        XCTAssertEqual(try Data(contentsOf: storage.url), bytes)
    }

    func testShelfVisibilityRequiresApproachAndLeavesOnlyAfterDragAndPointerEnd() {
        var session = DropShelfSession()
        session.update(dragging: false, pointerInside: true)
        XCTAssertFalse(session.visible, "Ordinary hover never opens the shelf")
        session.update(dragging: true, pointerInside: false)
        XCTAssertFalse(session.visible)
        session.update(dragging: true, pointerInside: true)
        XCTAssertTrue(session.visible)
        session.update(dragging: true, pointerInside: false)
        XCTAssertTrue(session.visible)
        session.update(dragging: false, pointerInside: true)
        XCTAssertTrue(session.visible, "A completed drop stays usable until the pointer leaves")
        session.update(dragging: false, pointerInside: false)
        XCTAssertFalse(session.visible)
        session.update(dragging: false, pointerInside: true)
        XCTAssertFalse(session.visible, "Hover cannot reopen it after the drag")
    }
}
