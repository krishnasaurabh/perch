import Foundation
import PlannerCore
import XCTest
@testable import PerchUI

final class DropShelfStorageTests: XCTestCase {
    func testKeptPackagesAndFoldersMigrateAsSingleStableItems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let source = root.appendingPathComponent("Incoming")
        let vault = root.appendingPathComponent("Clips")
        let bytes = Data("Synthetic package contents".utf8)
        var kept: [URL] = []
        for name in ["Project.pages", "Reference folder"] {
            let directory = source.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: directory.appendingPathComponent("Contents.txt"))
            kept.append(try ClipVault.keepCopy(of: directory, in: vault))
        }
        let storage = ClipShelfFile(vault: vault)
        let migrated = try storage.load()
        XCTAssertEqual(
            Set(migrated.map(\.content)), Set(kept.map { .file(URL(fileURLWithPath: $0.path, isDirectory: true)) }))
        XCTAssertEqual(migrated.count, 2, "Each package or folder is one item, not its descendants")
        XCTAssertEqual(try storage.load(), migrated, "Reload preserves every item and its identity")
        ClipVault.sweep(vault, olderThan: .distantFuture, keeping: storage.retainedPaths(migrated))
        for directory in kept {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Contents.txt")), bytes)
        }
        try storage.save([])
        XCTAssertTrue(try storage.load().isEmpty, "Clearing must not resurrect migrated packages")
    }

    func testKeptFilesNamedLikeShelfMetadataDoNotCollideWithTheIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let legacy = vault.appendingPathComponent("shelf.json")
        let namedLikeIndex = vault.appendingPathComponent("Clips.json")
        let bytes = Data(#"{"version":1,"items":[]}"#.utf8)
        try bytes.write(to: legacy)
        try bytes.write(to: namedLikeIndex)
        let storage = ClipShelfFile(vault: vault)
        let migrated = try storage.load()
        XCTAssertEqual(Set(migrated.map(\.content)), [.file(legacy), .file(namedLikeIndex)])
        try storage.save(migrated)
        XCTAssertNotEqual(storage.url, legacy)
        XCTAssertNotEqual(storage.url, namedLikeIndex)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        XCTAssertEqual(try Data(contentsOf: namedLikeIndex), bytes)
        XCTAssertEqual(try storage.load(), migrated)
    }
    func testHiddenKeptFilesMigrateBeforeRetentionRuns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let hidden = vault.appendingPathComponent(".env")
        let bytes = Data("Synthetic hidden reference".utf8)
        try bytes.write(to: hidden)
        let storage = ClipShelfFile(vault: vault)
        let items = try storage.load()
        XCTAssertEqual(items.map(\.content), [.file(hidden)])
        ClipVault.sweep(vault, olderThan: .distantFuture, keeping: storage.retainedPaths(items))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hidden.path))
    }

    func testMigrationThroughASymlinkKeepsConfiguredPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("RealClips")
        let alias = root.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("Kept through an alias".utf8).write(to: real.appendingPathComponent("Notes.txt"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let storage = ClipShelfFile(vault: alias)
        let items = try storage.load()
        XCTAssertEqual(items.map(\.content), [.file(alias.appendingPathComponent("Notes.txt"))])
        XCTAssertEqual(try storage.load(), items)
    }

    func testKeptFilesMigrateOnceWithoutRetentionDeletingThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let original = vault.appendingPathComponent("Notes.txt")
        try Data("Kept notes".utf8).write(to: original)
        let storage = ClipShelfFile(vault: vault)
        let migrated = try storage.load()
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated[0].content, .file(original))
        XCTAssertEqual(try storage.load(), migrated, "Migration persists stable identities")
        XCTAssertEqual(try Data(contentsOf: original), Data("Kept notes".utf8))
        ClipVault.sweep(vault, olderThan: .distantFuture, keeping: storage.retainedPaths(migrated))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try storage.load(), migrated)
    }

    func testFileURLImageAndTextRoundTripAndClearDoesNotReimportOldFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ClipShelfFile(vault: root.appendingPathComponent("Clips"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let values = [
            ClipShelfFile.Item(content: .file(root.appendingPathComponent("original.pdf")), date: date, pinned: true),
            ClipShelfFile.Item(content: .text("https://example.com/notes"), date: date),
            ClipShelfFile.Item(content: .image(Data([1, 2, 3])), date: date),
            ClipShelfFile.Item(content: .text("A parked reference"), date: date),
        ]
        try storage.save(values)
        XCTAssertEqual(try storage.load(), values)
        try Data("Orphan".utf8).write(to: storage.vault.appendingPathComponent("orphan.txt"))
        try storage.save([])
        XCTAssertTrue(try storage.load().isEmpty, "An existing manifest, including empty, is authoritative")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.vault.appendingPathComponent("orphan.txt").path))
    }

    func testLinksAndColonTextKeepTheirDistinctRepresentationsAcrossReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ClipShelfFile(vault: root.appendingPathComponent("Clips"))
        let link = URL(string: "https://example.com/design-board")!
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            ClipShelfFile.Item(content: .text("Note: buy milk"), date: date),
            ClipShelfFile.Item(content: .text("TODO: fix login"), date: date),
            ClipShelfFile.Item(content: .text(link.absoluteString), date: date),
            ClipShelfFile.Item(content: .link(link), date: date),
            ClipShelfFile.Item(content: .link(URL(string: "mailto:hello@example.com")!), date: date),
        ]
        try storage.save(items)
        XCTAssertEqual(try storage.load(), items)
    }

    func testVersionOneTextDocumentsDecodeWithoutGuessingLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ClipShelfFile(vault: root.appendingPathComponent("Clips"))
        try FileManager.default.createDirectory(
            at: storage.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document =
            #"{"version":1,"items":[{"id":"CC680BD3-4F74-4634-81E3-75D2B48AC37A","content":{"text":{"_0":"Note: buy milk"}},"date":0,"pinned":false}]}"#
        try Data(document.utf8).write(to: storage.url)
        let items = try storage.load()
        XCTAssertEqual(items.map(\.content), [.text("Note: buy milk")])
        try storage.save(items)
        XCTAssertEqual(try storage.load(), items)
    }

    func testMalformedManifestIsNotReplacedWithAnEmptyShelf() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = ClipShelfFile(vault: root.appendingPathComponent("Clips"))
        let bytes = Data("not valid JSON".utf8)
        try FileManager.default.createDirectory(
            at: storage.url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
