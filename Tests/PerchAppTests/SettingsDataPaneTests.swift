import AppKit
import PlannerCore
import SwiftUI
import XCTest
@testable import PerchApp

@MainActor
final class SettingsDataPaneTests: XCTestCase {
    func testFinderUsesTheActualPlannerAndDoesNotChangeData() throws {
        let fixture = try DataPaneFixture()
        defer { fixture.close() }
        let before = try fixture.contents()
        var revealed: URL?
        var actions = SettingsDataActions()
        actions.reveal = { revealed = $0 }
        actions.showInFinder(store: fixture.store)
        XCTAssertEqual(revealed, fixture.store.file.url)
        XCTAssertEqual(try fixture.contents(), before)
    }

    func testExportUsesExistingPortableExportAndDoesNotChangePlanner() throws {
        let fixture = try DataPaneFixture()
        defer { fixture.close() }
        let before = try fixture.contents()
        let destination = fixture.directory.appendingPathComponent("export.json")
        var actions = SettingsDataActions()
        actions.chooseExport = { name in
            XCTAssertEqual(name, "Perch-\(fixture.store.today).json")
            return destination
        }
        actions.exportEverything(store: fixture.store, feedback: fixture.feedback)
        let exported = try PlannerFile.decodeDocument(Data(contentsOf: destination))
        XCTAssertEqual(exported.tasks, fixture.store.planner.tasks)
        XCTAssertEqual(try fixture.contents(), before)
        XCTAssertNil(fixture.store.lastError)
    }

    func testExportCancellationMakesNoFile() throws {
        let fixture = try DataPaneFixture()
        defer { fixture.close() }
        let before = try fixture.contents()
        var actions = SettingsDataActions()
        actions.chooseExport = { _ in nil }
        actions.exportEverything(store: fixture.store, feedback: fixture.feedback)
        XCTAssertEqual(try fixture.contents(), before)
    }

    func testImportAddsTasksAndReloadsWithoutReplacingSettings() throws {
        let fixture = try DataPaneFixture()
        defer { fixture.close() }
        let source = fixture.directory.appendingPathComponent("import.json")
        let imported = PlanTask(title: "Imported task", day: fixture.store.today)
        var document = Planner()
        document.tasks = [imported]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: source)
        var actions = SettingsDataActions()
        actions.chooseImport = { source }
        actions.importTasks(store: fixture.store)
        let reloaded = try fixture.store.file.load()
        XCTAssertEqual(Set(reloaded.tasks.map(\.title)), ["Keep this task", "Imported task"])
        XCTAssertEqual(reloaded.preferences.finishedTaskRetention, .never)
        XCTAssertNil(fixture.store.lastError)
    }

    func testImportCancellationAndInvalidInputPreservePlanner() throws {
        let fixture = try DataPaneFixture()
        defer { fixture.close() }
        let before = try fixture.contents()
        var actions = SettingsDataActions()
        actions.chooseImport = { nil }
        actions.importTasks(store: fixture.store)
        XCTAssertEqual(try fixture.contents(), before)
        let source = fixture.directory.appendingPathComponent("invalid.json")
        try Data("not a planner".utf8).write(to: source)
        actions.chooseImport = { source }
        actions.importTasks(store: fixture.store)
        XCTAssertEqual(try fixture.contents(), before)
        XCTAssertNotNil(fixture.store.lastError)
    }

    func testEachRetentionChoiceIsStoredAndReloaded() throws {
        let fixture = try DataPaneFixture()
        defer { fixture.close() }
        var confirmations: [SettingsDataConfirmation] = []
        var actions = SettingsDataActions()
        actions.confirm = {
            confirmations.append($0); return true
        }
        for value in [FinishedTaskRetention.thirtyDays, .ninetyDays, .never] {
            actions.setRetention(value, store: fixture.store)
            XCTAssertEqual(fixture.store.prefs.finishedTaskRetention, value)
            XCTAssertEqual(try fixture.store.file.load().preferences.finishedTaskRetention, value)
        }
        XCTAssertEqual(confirmations, [.retention(.thirtyDays), .retention(.ninetyDays)])
    }

    func testConfirmedRetentionPrunesImmediatelyAndUndoRestoresTasksAndPreference() throws {
        let fixture = try DataPaneFixture()
        defer { fixture.close() }
        let oldDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -100, to: Date()))
        var document = fixture.store.planner
        let finished = PlanTask(
            title: "Old finished task", day: fixture.store.dayKey(oldDate), done: true,
            completedAt: oldDate, createdAt: oldDate)
        document.tasks.append(finished)
        try fixture.store.file.save(document)
        let store = PlannerStore(file: fixture.store.file, watching: false)
        var actions = SettingsDataActions()
        actions.confirm = { _ in false }
        actions.setRetention(.thirtyDays, store: store)
        XCTAssertEqual(try store.file.load().tasks.map(\.id), document.tasks.map(\.id))
        XCTAssertEqual(try store.file.load().preferences.finishedTaskRetention, .never)
        actions.confirm = { _ in true }
        actions.setRetention(.thirtyDays, store: store)
        XCTAssertEqual(try store.file.load().tasks.map(\.title), ["Keep this task"])
        XCTAssertEqual(try store.file.load().preferences.finishedTaskRetention, .thirtyDays)
        store.undo()
        XCTAssertEqual(try store.file.load().tasks.map(\.id), document.tasks.map(\.id))
        XCTAssertEqual(try store.file.load().preferences.finishedTaskRetention, .never)
    }

    func testCancelledRetentionLeavesStoredPreferenceUnchanged() throws {
        let fixture = try DataPaneFixture()
        defer { fixture.close() }
        let before = try fixture.contents()
        var actions = SettingsDataActions()
        actions.confirm = {
            XCTAssertEqual($0, .retention(.thirtyDays)); return false
        }
        actions.setRetention(.thirtyDays, store: fixture.store)
        XCTAssertEqual(fixture.store.prefs.finishedTaskRetention, .never)
        XCTAssertEqual(try fixture.contents(), before)
    }

    func testEmptyParkingLotRequiresConfirmationPersistsAndUndoes() throws {
        let fixture = try DataPaneFixture()
        defer { fixture.close() }
        fixture.store.send(.parkThought("Keep this thought"))
        let before = try fixture.contents()
        var actions = SettingsDataActions()
        actions.confirm = {
            XCTAssertEqual($0, .emptyParkingLot); return false
        }
        actions.emptyParkingLot(store: fixture.store)
        XCTAssertEqual(try fixture.contents(), before)
        actions.confirm = { _ in true }
        actions.emptyParkingLot(store: fixture.store)
        XCTAssertTrue(try fixture.store.file.load().parkedThoughts.isEmpty)
        XCTAssertEqual(fixture.store.planner.tasks.count, 1)
        fixture.store.undo()
        XCTAssertEqual(try fixture.store.file.load().parkedThoughts.map(\.text), ["Keep this thought"])
    }

    func testEraseRequiresConfirmationPersistsAndUndoes() throws {
        let fixture = try DataPaneFixture()
        defer { fixture.close() }
        fixture.store.send(.parkThought("Keep this thought"))
        fixture.store.apply { try $0.updatePreference(.finishedTaskRetention(.ninetyDays)) }
        let before = try fixture.contents()
        var actions = SettingsDataActions()
        actions.confirm = {
            XCTAssertEqual($0, .eraseEverything); return false
        }
        actions.eraseEverything(store: fixture.store)
        XCTAssertEqual(try fixture.contents(), before)
        actions.confirm = { _ in true }
        actions.eraseEverything(store: fixture.store)
        let erased = try fixture.store.file.load()
        XCTAssertTrue(erased.tasks.isEmpty)
        XCTAssertTrue(erased.parkedThoughts.isEmpty)
        XCTAssertEqual(erased.preferences.finishedTaskRetention, .never)
        fixture.store.undo()
        let restored = try fixture.store.file.load()
        XCTAssertEqual(restored.tasks.map(\.title), ["Keep this task"])
        XCTAssertEqual(restored.parkedThoughts.map(\.text), ["Keep this thought"])
        XCTAssertEqual(restored.preferences.finishedTaskRetention, .ninetyDays)
    }

    func testRestoreRequiresConfirmationAndReloadsBackup() throws {
        let fixture = try DataPaneFixture()
        defer { fixture.close() }
        fixture.store.addTasks(["Later task"], literal: true)
        XCTAssertEqual(fixture.store.planner.tasks.count, 2)
        let before = try fixture.contents()
        var actions = SettingsDataActions()
        actions.confirm = {
            XCTAssertEqual($0, .restoreBackup); return false
        }
        actions.restoreBackup(store: fixture.store, feedback: fixture.feedback)
        XCTAssertEqual(try fixture.contents(), before)
        actions.confirm = { _ in true }
        actions.restoreBackup(store: fixture.store, feedback: fixture.feedback)
        XCTAssertEqual(fixture.store.planner.tasks.map(\.title), ["Keep this task"])
        XCTAssertEqual(try fixture.store.file.load().tasks, fixture.store.planner.tasks)
        XCTAssertNil(fixture.store.lastError)
        fixture.store.undo()
        XCTAssertEqual(try fixture.store.file.load().tasks.map(\.title), ["Keep this task", "Later task"])
    }

    func testMissingBackupReportsFailureWithoutReplacingCurrentData() throws {
        let fixture = try DataPaneFixture()
        defer { fixture.close() }
        try FileManager.default.removeItem(at: fixture.store.file.backupDirectory)
        let before = try fixture.contents()
        var actions = SettingsDataActions()
        actions.confirm = { _ in true }
        actions.restoreBackup(store: fixture.store, feedback: fixture.feedback)
        XCTAssertEqual(try fixture.contents(), before)
        let error = try XCTUnwrap(fixture.store.lastError)
        XCTAssertTrue(fixture.feedback.canRetry(error))
    }

    func testBackupSummaryUsesActualPolicyAndFileMetadata() throws {
        let fixture = try DataPaneFixture()
        defer { fixture.close() }
        fixture.store.addTasks(["Later task"], literal: true)
        let status = SettingsDataBackupStatus(file: fixture.store.file)
        XCTAssertTrue(status.canRestore)
        XCTAssertNotNil(status.lastBackup)
        XCTAssertEqual(SettingsDataBackupStatus.policy, "Before changes, 5 copies")
    }

    func testDestructiveDialogsDefaultToCancel() {
        for request in [
            SettingsDataConfirmation.restoreBackup, .emptyParkingLot, .eraseEverything,
            .retention(.thirtyDays), .retention(.ninetyDays),
        ] {
            let alert = SettingsDataActions.alert(for: request)
            XCTAssertEqual(alert.buttons.first?.title, "Cancel")
            XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\u{1b}")
            XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons.first?.cell)
            XCTAssertEqual(alert.buttons.last?.keyEquivalent, "")
            XCTAssertFalse(alert.informativeText.isEmpty)
        }
    }
}

@MainActor
private final class DataPaneFixture {
    let directory: URL
    let store: PlannerStore
    let feedback = SettingsFailureFeedback()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        store = PlannerStore(file: file, watching: false)
        store.addTasks(["Keep this task"], literal: true)
        // Ensure an actual pre-save revision exists for restore and missing-backup tests.
        store.send(.parkThought("Temporary thought"))
        store.send(.emptyParkingLot)
        XCTAssertNil(store.lastError)
    }

    func contents() throws -> Data { try Data(contentsOf: store.file.url) }
    func close() { try? FileManager.default.removeItem(at: directory) }
}
