import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class DiskSchemaTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func file(_ adapter: any PlannerPreferencesAdapter = MemoryPlannerPreferences()) -> PlannerFile {
        PlannerFile(url: directory.appendingPathComponent("planner.json"), preferences: adapter)
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func legacy(_ file: PlannerFile) throws -> Data {
        let data = Data(PlannerMigrationTests.legacyDocument.utf8)
        try data.write(to: file.url)
        return data
    }

    func testEveryPreferenceIsClassifiedExactlyOnce() throws {
        var defaults = Preferences()
        defaults.showOnDisplay = "Synthetic display"
        let all = Set(try object(JSONEncoder().encode(defaults)).keys)
        let device = Set(try object(JSONEncoder().encode(DevicePreferences(defaults))).keys)
        let shared = Set(try object(JSONEncoder().encode(SharedPlannerPreferences(defaults))).keys)
        XCTAssertEqual(device.union(shared), all)
        XCTAssertTrue(device.intersection(shared).isEmpty)
        XCTAssertEqual(
            try JSONDecoder().decode(DevicePreferences.self, from: Data("{}".utf8)), DevicePreferences(Preferences()))
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)), Preferences())
    }

    func testFullLegacyFixtureMigratesToUserDefaultsAndKeepsAnExactPermanentBackup() throws {
        let suite = "perch.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = UserDefaultsPlannerPreferences(defaults: defaults)
        let file = file(adapter)
        let raw = try legacy(file)
        let before = try file.load()
        XCTAssertNil(try adapter.load(), "Read-only inspection must not migrate preferences")
        try file.save(before)
        XCTAssertEqual(try adapter.load(), DevicePreferences(before.preferences))
        XCTAssertEqual(try file.load(), before)
        let disk = try object(Data(contentsOf: file.url))
        XCTAssertEqual(disk["version"] as? Int, 2)
        XCTAssertEqual(
            Set((disk["preferences"] as? [String: Any] ?? [:]).keys),
            ["resetHour", "carryMode", "defaultFocusMinutes", "includeWeekendsInStreak"])
        let backups = try FileManager.default.contentsOfDirectory(
            at: file.migrationDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), raw)
        let bytes = try Data(contentsOf: file.url)
        let modified = file.modificationDate
        for _ in 0..<4 { try file.save(file.load()) }
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertEqual(file.modificationDate, modified)
        for n in 0..<8 {
            try file.mutate { $0.notes.append(QuickNote(day: "2026-11-09", text: "Note \(n)")) }
        }
        XCTAssertEqual(try file.backupURLs().count, PlannerFile.backupLimit)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), raw)
    }

    func testExistingDeviceValuesWinAndAreNotReimported() throws {
        var chosen = Preferences()
        chosen.showOnDisplay = "Chosen display"; chosen.catchCopies = false
        let adapter = MemoryPlannerPreferences(DevicePreferences(chosen))
        let file = file(adapter)
        _ = try legacy(file)
        let loaded = try file.load()
        XCTAssertEqual(loaded.preferences.showOnDisplay, "Chosen display")
        XCTAssertFalse(loaded.preferences.catchCopies)
        XCTAssertEqual(loaded.preferences.defaultFocusMinutes, 50, "Shared policy stays in the document")
        try file.save(loaded)
        var changed = chosen; changed.showOnDisplay = nil; changed.welcomeCompleted = true
        adapter.save(DevicePreferences(changed))
        XCTAssertNil(try file.load().preferences.showOnDisplay)
        try file.mutate { $0.notes.append(QuickNote(day: "2026-11-09", text: "Later")) }
        XCTAssertEqual(adapter.load(), DevicePreferences(changed))
    }

    func testCopyingDataToAnotherDeviceDoesNotCopyDevicePreferences() throws {
        let source = file()
        _ = try legacy(source)
        try source.save(source.load())
        let other = PlannerFile(
            url: directory.appendingPathComponent("other.json"), preferences: MemoryPlannerPreferences())
        try Data(contentsOf: source.url).write(to: other.url)
        let loaded = try other.load()
        XCTAssertEqual(loaded.tasks, try source.load().tasks)
        XCTAssertEqual(loaded.preferences.defaultFocusMinutes, 50)
        XCTAssertNil(loaded.preferences.showOnDisplay)
        XCTAssertFalse(loaded.preferences.remindersSync)
        XCTAssertFalse(loaded.preferences.catchCopies)
        let exported = directory.appendingPathComponent("export.json")
        try source.export(to: exported)
        let portable = try object(Data(contentsOf: exported))
        XCTAssertEqual(portable["version"] as? Int, 1)
        XCTAssertNil((portable["preferences"] as? [String: Any])?["showOnDisplay"])
        XCTAssertEqual(
            try PlannerFile.decoder.decode(Planner.self, from: Data(contentsOf: exported)).tasks, loaded.tasks)
    }

    func testInterruptedMigrationRetriesWithoutDuplicateBackupsOrPreferenceLoss() throws {
        let adapter = MemoryPlannerPreferences()
        let url = directory.appendingPathComponent("planner.json")
        var fail = true
        var hit = false
        var io = PlannerFile.IO()
        io.write = { data, target in
            if target.standardizedFileURL == url.standardizedFileURL && fail {
                hit = true
                throw PlannerError("Synthetic replacement failure")
            }
            try data.write(to: target, options: .atomic)
        }
        let file = PlannerFile(url: url, io: io, preferences: adapter)
        let raw = try legacy(file)
        let loaded = try file.load()
        XCTAssertThrowsError(try file.save(loaded))
        XCTAssertTrue(hit)
        XCTAssertEqual(try Data(contentsOf: url), raw)
        XCTAssertNil(adapter.load(), "Failed replacement restores the old adapter state")
        let backups = try file.backupURLs()
        XCTAssertEqual(backups.count, 1)
        fail = false
        try file.save(file.load())
        XCTAssertEqual(try file.load(), loaded)
        XCTAssertEqual(try file.backupURLs(), backups)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.migrationDirectory.path).count, 1)
    }

    func testMigrationBackupFailurePreventsDataAndPreferenceChanges() throws {
        let adapter = MemoryPlannerPreferences()
        let url = directory.appendingPathComponent("planner.json")
        var hit = false
        var io = PlannerFile.IO()
        io.write = { data, target in
            if target.deletingLastPathComponent().lastPathComponent == "planner.json.migrations" {
                hit = true; throw PlannerError("Synthetic migration backup failure")
            }
            try data.write(to: target, options: .atomic)
        }
        let file = PlannerFile(url: url, io: io, preferences: adapter)
        let raw = try legacy(file)
        XCTAssertThrowsError(try file.save(file.load()))
        XCTAssertTrue(hit)
        XCTAssertEqual(try Data(contentsOf: url), raw)
        XCTAssertNil(adapter.load())
        XCTAssertTrue(try file.backupURLs().isEmpty)
    }

    private final class FailingPreferences: PlannerPreferencesAdapter {
        func load() -> DevicePreferences? { nil }
        func save(_ preferences: DevicePreferences?) throws { throw PlannerError("Synthetic preference failure") }
    }
    func testPreferenceFailureDoesNotReplaceLegacyData() throws {
        let file = file(FailingPreferences())
        let raw = try legacy(file)
        XCTAssertThrowsError(try file.save(file.load()))
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
    }

    func testExplicitOrderSurvivesMigrationAppendReorderAndRepeatedWrites() throws {
        let file = file()
        _ = try legacy(file)
        var json = try object(Data(contentsOf: file.url))
        json["taskOrder"] = ["44444444-4444-4444-4444-444444444444", "11111111-1111-1111-1111-111111111111"]
        try JSONSerialization.data(withJSONObject: json).write(to: file.url)
        let ids = try file.load().tasks.map(\.id)
        try file.save(file.load())
        try file.mutate { $0.tasks.append(PlanTask(title: "Appended", day: nil, createdAt: Fixture.now)) }
        XCTAssertEqual(Array(try file.load().tasks.map(\.id).prefix(2)), ids)
        let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { Fixture.now })
        try pipeline.execute(.reorder(ids[0], before: nil), origin: .user)
        let reordered = try file.load().tasks.map(\.id)
        let order = try object(Data(contentsOf: file.url))["taskOrder"] as? [String]
        XCTAssertEqual(order, reordered.map { $0.uuidString })
        try file.save(file.load())
        XCTAssertEqual(try file.load().tasks.map(\.id), reordered)
        _ = try pipeline.undo()
        XCTAssertEqual(Array(try file.load().tasks.map(\.id).prefix(2)), ids)
    }

    func testMissingOrderEntriesAppendWithoutResettingKnownOrder() throws {
        let file = file()
        _ = try legacy(file)
        var json = try object(Data(contentsOf: file.url))
        json["taskOrder"] = ["44444444-4444-4444-4444-444444444444"]
        try JSONSerialization.data(withJSONObject: json).write(to: file.url)
        XCTAssertEqual(try file.load().tasks.map(\.title), ["Inbox idea", "Review report"])
    }

    func testFractionalUpdatedAtIsStampedOnlyOnChangedTasksAndSurvivesUndo() throws {
        let file = file()
        var p = Planner()
        p.tasks = [
            PlanTask(title: "Edit", day: nil, createdAt: Fixture.now),
            PlanTask(title: "Untouched", day: nil, createdAt: Fixture.now),
        ]
        try file.save(p)
        var time = Fixture.now.addingTimeInterval(10.123456789)
        let pipeline = PlannerCommandPipeline(file: file, clock: ClosurePlannerClock { time })
        let change = try pipeline.execute(.rename(p.tasks[0].id, "Changed"), origin: .user)
        XCTAssertEqual(change.value.tasks.first?.updatedAt, time)
        XCTAssertEqual(try file.load().tasks[0].updatedAt, time)
        XCTAssertEqual(try file.load().tasks[1].updatedAt, Fixture.now)
        let bytes = try Data(contentsOf: file.url)
        time += 10
        _ = try pipeline.execute(.rename(p.tasks[0].id, "Changed"), origin: .user)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().tasks[0].title, "Edit")
        XCTAssertEqual(try file.load().tasks[0].updatedAt, time)
        _ = try pipeline.redo()
        XCTAssertEqual(try file.load().tasks[0].title, "Changed")
        time += 5
        _ = try pipeline.execute(.delete(p.tasks[0].id), origin: .user)
        time += 1
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().tasks[0].title, "Changed")
        XCTAssertEqual(try file.load().tasks[0].updatedAt, time)
    }

    func testMalformedExplicitOrderCannotSilentlyBecomeArrayOrder() throws {
        let file = file()
        for invalid in [
            NSNull(), ["not-a-uuid"], ["11111111-1111-1111-1111-111111111111", "11111111-1111-1111-1111-111111111111"],
        ] as [Any] {
            var json = try object(Data(PlannerMigrationTests.legacyDocument.utf8))
            json["taskOrder"] = invalid
            let raw = try JSONSerialization.data(withJSONObject: json)
            try raw.write(to: file.url)
            XCTAssertThrowsError(try file.load())
            XCTAssertThrowsError(try file.save(Planner()))
            XCTAssertEqual(try Data(contentsOf: file.url), raw)
        }
    }

    func testRestoreAndSamePathExportKeepCurrentDeviceChoices() throws {
        let adapter = MemoryPlannerPreferences()
        let file = file(adapter)
        var planner = Planner()
        planner.preferences.catchCopies = true
        try file.save(planner)
        planner.notes = [QuickNote(day: "2026-11-09", text: "Later revision")]
        try file.save(planner)
        var choice = planner.preferences
        choice.showOnDisplay = "Current display"
        adapter.save(DevicePreferences(choice))
        let restored = try file.restoreLatestBackup()
        XCTAssertEqual(restored.preferences.showOnDisplay, "Current display")
        XCTAssertTrue(restored.preferences.catchCopies)
        try file.export(to: file.url)
        XCTAssertEqual(try file.load().preferences.showOnDisplay, "Current display")
        XCTAssertTrue(try file.load().preferences.catchCopies)
    }

    func testLegacyCompletionFocusAndCalendarFactsAreReconciledWithoutInventedDates() throws {
        let file = file()
        var p = Planner()
        let a = PlanTask(
            title: "Timestamp", day: nil, completedAt: Fixture.now, createdAt: Fixture.now, focusedSeconds: 90)
        let b = PlanTask(title: "Old completion", day: nil, done: true, createdAt: Fixture.now, focusedSeconds: 120)
        p.tasks = [a, b]
        p.focusSegments = [
            FocusSegment(taskID: a.id, start: Fixture.now, end: Fixture.now + 100),
            FocusSegment(taskID: b.id, start: Fixture.now + 100, end: Fixture.now + 130),
        ]
        p.completedCalendarEventDays = ["synthetic-event": "2026-11-09"]
        try PlannerFile.encoder.encode(p).write(to: file.url)
        let loaded = try file.load()
        XCTAssertTrue(loaded.tasks[0].done)
        XCTAssertEqual(loaded.tasks[0].focusedSeconds, 100)
        XCTAssertEqual(loaded.tasks[1].focusedSeconds, 120)
        XCTAssertEqual(loaded.tasks[1].unloggedFocusedSeconds, 90)
        XCTAssertNil(loaded.tasks[1].completedAt)
        XCTAssertTrue(loaded.completedCalendarEventIDs.contains("synthetic-event"))
        XCTAssertEqual(loaded.focusSegments, p.focusSegments)
        try file.save(loaded)
        XCTAssertEqual(try file.load(), loaded)
    }

    func testLegacyFocusLogAliasKeepsDistinctIntervalsAndDoesNotDuplicateExactMatches() throws {
        let file = file()
        let raw = Data(
            #"""
            {"version":1,"focusSegments":[{"start":"2026-11-09T12:00:00Z","end":"2026-11-09T12:01:00Z"}],
            "focusLog":[{"start":"2026-11-09T12:00:00Z","end":"2026-11-09T12:01:00Z","isSynced":false},
            {"start":"2026-11-09T13:00:00Z","end":"2026-11-09T13:02:00Z"}]}
            """#.utf8)
        try raw.write(to: file.url)
        XCTAssertEqual(try file.load().focusSegments.count, 2)
        XCTAssertFalse(try file.load().focusSegments[0].isSynced)
        XCTAssertEqual(try file.load().focusSegments.reduce(0) { $0 + $1.seconds }, 180)
    }
}
