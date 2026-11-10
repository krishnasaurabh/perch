import AppKit
import Foundation
import PlannerCore
import PerchUI
import XCTest
@testable import PerchApp

@MainActor
private final class ManualScheduler: AppScheduling {
    final class Token: AppScheduledAction {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    var time: TimeInterval = 0
    var jobs: [(TimeInterval, Token, @MainActor () -> Void)] = []
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any AppScheduledAction {
        let token = Token()
        jobs.append((time + delay, token, action))
        return token
    }
    func advance(_ seconds: TimeInterval) {
        time += seconds
        let due = jobs.filter { $0.0 <= time }
        jobs.removeAll { $0.0 <= time }
        for (_, token, action) in due where !token.cancelled { action() }
    }
}

final class PlannerStoreTests: XCTestCase {
    func testDebouncePersistsOnlyLatestDraftAndUndoRedo() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = PlannerFile(url: root.appendingPathComponent("planner.json"))
            let scheduler = ManualScheduler()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let store = PlannerStore(file: file, now: { now }, watching: false, scheduler: scheduler)
            let added = try XCTUnwrap(store.apply { try $0.addTasks(["Original"], on: .day($0.today)) })
            let id = added[0].id
            store.setText("First draft", for: .title(id))
            scheduler.advance(0.25)
            store.setText("Final draft", for: .title(id))
            scheduler.advance(0.25)
            XCTAssertEqual(try file.load().tasks[0].title, "Original")
            XCTAssertEqual(store.text(for: .title(id)), "Final draft")
            scheduler.advance(0.25)
            XCTAssertEqual(try file.load().tasks[0].title, "Final draft")
            XCTAssertNil(store.lastError)
            store.undo()
            XCTAssertEqual(try file.load().tasks[0].title, "Original")
            store.redo()
            XCTAssertEqual(try file.load().tasks[0].title, "Final draft")
        }
    }

    func testExternalEditRetainsConflictingDraftAndNeverOverwritesDisk() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = PlannerFile(url: root.appendingPathComponent("planner.json"))
            let scheduler = ManualScheduler()
            let store = PlannerStore(file: file, watching: false, scheduler: scheduler)
            let added = try XCTUnwrap(store.apply { try $0.addTasks(["Original"], on: .day($0.today)) })
            store.setText("Local draft", for: .title(added[0].id))
            try file.mutate { $0.tasks[0].title = "External edit" }
            scheduler.advance(1)
            XCTAssertNotNil(store.lastError)
            XCTAssertEqual(try file.load().tasks[0].title, "External edit")
            XCTAssertEqual(store.text(for: .title(added[0].id)), "Local draft")
            XCTAssertFalse(store.flushPendingText())
        }
    }

    func testInjectedClockControlsFocusWithoutWallClockSleep() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var now = Date(timeIntervalSince1970: 1_800_000_000)
            let store = PlannerStore(
                file: PlannerFile(url: root.appendingPathComponent("planner.json")), now: { now }, watching: false)
            let tasks = try XCTUnwrap(store.apply { try $0.addTasks(["Focus fixture"], on: .day($0.today)) })
            XCTAssertNotNil(store.apply { try $0.startTimer(task: tasks[0].id.uuidString, minutes: 5) })
            now.addTimeInterval(12.5)
            store.apply { try $0.pauseTimer() }
            XCTAssertEqual(store.planner.tasks[0].focusedSeconds, 12.5)
            XCTAssertEqual(try store.file.load().tasks[0].focusedSeconds, 12.5)
        }
    }

    func testClipsUseInjectedSchedulerClockAndPrivatePasteboard() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = PlannerFile(url: root.appendingPathComponent("planner.json"))
            let scheduler = ManualScheduler()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let store = PlannerStore(file: file, watching: false, scheduler: scheduler)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let clips = ClipsService(
                store: store, now: { now }, scheduler: scheduler, pasteboard: pasteboard, monitoring: false)
            XCTAssertEqual(clips.vault.deletingLastPathComponent().path, root.path)
            XCTAssertEqual(clips.folderWatch, .off)
            clips.add(.text("First clip"), source: "copied")
            clips.add(.text("Second clip"), source: "copied")
            clips.add(.text("Second clip"), source: "copied")
            XCTAssertEqual(clips.clips.count, 2)
            XCTAssertEqual(clips.clips[0].date, now)
            clips.copy(clips.clips[0])
            XCTAssertEqual(pasteboard.string(forType: .string), "Second clip")
            clips.letGo(clips.clips[0].id)
            XCTAssertEqual(clips.letGoBanner?.deadline, now.addingTimeInterval(5))
            scheduler.advance(4.9)
            XCTAssertNotNil(clips.letGoBanner)
            clips.undoLetGo()
            scheduler.advance(0.1)
            XCTAssertEqual(clips.clips.count, 2)
            XCTAssertNil(clips.letGoBanner)
            clips.sweep()
            scheduler.advance(5)
            XCTAssertNil(clips.letGoBanner)
            clips.undoLetGo()
            XCTAssertTrue(clips.clips.isEmpty)
        }
    }

    func testShortcutStoreUsesIsolatedDefaults() async throws {
        try await MainActor.run {
            let name = "PerchTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            XCTAssertEqual(ShortcutStore.load(defaults: defaults), .default)
            let changed = ShortcutKey(keyCode: 0, modifiers: [.command, .shift])
            ShortcutStore.save(changed, defaults: defaults, notify: false)
            XCTAssertEqual(ShortcutStore.load(defaults: defaults), changed)
            defaults.set(Data("invalid".utf8), forKey: ShortcutStore.defaultsKey)
            XCTAssertEqual(ShortcutStore.load(defaults: defaults), .default)
        }
    }
}
