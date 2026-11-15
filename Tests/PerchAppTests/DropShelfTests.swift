import AppKit
import Foundation
import PlannerCore
import PerchUI
import XCTest
@testable import PerchApp

@MainActor
private final class ShelfPasteboard: PasteboardAccess {
    var changeCount = 0
    var declaredTypes: [String] = []
    var fileURLs: [URL] = []
    var imageData: Data?
    var plainText: String?
    func replace(with value: PasteboardValue) { changeCount += 1 }
}

final class DropShelfTests: XCTestCase {
    @MainActor
    func testKeptClipsMigrateAndPersistWithoutStartingCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let old = vault.appendingPathComponent("Kept notes.txt")
        try Data("Kept notes".utf8).write(to: old)
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        let shelf = ClipsService(store: store, pasteboard: ShelfPasteboard(), monitoring: false)
        XCTAssertEqual(shelf.clips.count, 1)
        XCTAssertEqual(shelf.clips.first?.content, .file(old))
        let id = try XCTUnwrap(shelf.clips.first?.id)
        shelf.togglePin(id)
        let restarted = ClipsService(store: store, pasteboard: ShelfPasteboard(), monitoring: false)
        XCTAssertEqual(restarted.clips.map(\.id), [id])
        XCTAssertTrue(try XCTUnwrap(restarted.clips.first).pinned)
        XCTAssertEqual(restarted.folderWatch, .off)
        restarted.clearShelf()
        XCTAssertTrue(restarted.clips.isEmpty)
        restarted.undoLetGo()
        XCTAssertEqual(restarted.clips.map(\.id), [id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    @MainActor
    func testDragOutOffersTheOriginalFileAndTypedLink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        let shelf = ClipsService(store: store, pasteboard: ShelfPasteboard(), monitoring: false)
        let file = root.appendingPathComponent("Original.txt")
        try Data("Original contents".utf8).write(to: file)
        shelf.add(.file(file), source: "dropped")
        let clip = try XCTUnwrap(shelf.clips.first)
        XCTAssertNotEqual(shelf.clipURL(clip), file, "A temporary source has a durable kept copy")
        let original: URL? = await withCheckedContinuation { continuation in
            _ = shelf.dragProvider(for: clip).loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
        XCTAssertEqual(original?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
        shelf.add(.text("https://example.com/design-board"), source: "dropped")
        let link = try XCTUnwrap(shelf.clips.first)
        let dragged: URL? = await withCheckedContinuation { continuation in
            _ = shelf.dragProvider(for: link).loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
        XCTAssertEqual(dragged?.absoluteString, "https://example.com/design-board")
        XCTAssertEqual(try Data(contentsOf: file), Data("Original contents".utf8))
    }

    @MainActor
    func testMalformedShelfCannotBeOverwrittenByADrop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let saved = ClipShelfFile(vault: vault).url
        let original = Data("not valid shelf data".utf8)
        try original.write(to: saved)
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        let shelf = ClipsService(store: store, pasteboard: ShelfPasteboard(), monitoring: false)
        XCTAssertNotNil(store.lastError)
        shelf.add(.text("Must not overwrite recovery data"), source: "dropped")
        shelf.clearShelf()
        XCTAssertEqual(try Data(contentsOf: saved), original)
        XCTAssertTrue(shelf.clips.isEmpty)
    }
}
