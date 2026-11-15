import Foundation
import PlannerTestSupport
import XCTest
@testable import PlannerCore

final class PlannerDataMaintenanceTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!
    private var pipeline: PlannerCommandPipeline!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        pipeline = PlannerCommandPipeline(
            file: file, clock: ClosurePlannerClock { Fixture.now }, calendar: Fixture.calendar)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func finished(_ title: String, on day: String) -> PlanTask {
        PlanTask(
            title: title, day: DayKey(day), done: true, completedAt: Fixture.date("\(day) 12:00"),
            createdAt: Fixture.date("\(day) 09:00"))
    }

    // MARK: Retention

    func testRetentionPrunesOnlyFinishedTasksStrictlyBeforeCutoff() throws {
        var planner = Planner()
        // Today is 2026-11-09; a thirty-day cutoff is 2026-10-10.
        planner.tasks = [
            finished("Old finished", on: "2026-10-09"),
            finished("Boundary finished", on: "2026-10-10"),
            PlanTask(title: "Old open", day: DayKey("2026-10-01"), createdAt: Fixture.date("2026-10-01 09:00")),
            finished("Recent finished", on: "2026-11-08"),
        ]
        try file.save(planner)
        try pipeline.updatePreference(.finishedTaskRetention(.thirtyDays), origin: .user)
        let titles = try file.load().tasks.map(\.title)
        XCTAssertEqual(titles, ["Boundary finished", "Old open", "Recent finished"])
        XCTAssertEqual(try file.load().preferences.finishedTaskRetention, .thirtyDays)

        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().tasks.map(\.title), planner.tasks.map(\.title))
        XCTAssertEqual(try file.load().preferences.finishedTaskRetention, .never)
    }

    func testNeverRetentionKeepsEverythingAndDayLifecyclePrunes() throws {
        var planner = Planner()
        planner.tasks = [finished("Ancient", on: "2026-01-02")]
        try file.save(planner)
        try pipeline.execute(.lifecycle(.dayChanged), origin: .background)
        XCTAssertEqual(try file.load().tasks.count, 1)

        planner = try file.load()
        planner.preferences.finishedTaskRetention = .ninetyDays
        try file.save(planner)
        try pipeline.execute(.lifecycle(.dayChanged), origin: .background)
        XCTAssertTrue(try file.load().tasks.isEmpty)
        try pipeline.execute(.lifecycle(.launch), origin: .background)
        XCTAssertTrue(try file.load().tasks.isEmpty)
    }

    func testRetentionKeepsFocusedTaskRepeatSurvivorAndCarrySources() throws {
        var planner = Planner()
        planner.preferences.finishedTaskRetention = .thirtyDays
        var focused = finished("Focused", on: "2026-09-01")
        focused.focusedSeconds = 60
        let rule = TaskRepeat.daily
        var lone = finished("Only member", on: "2026-09-01")
        lone.repeatRule = rule
        let source = PlanTask(
            title: "Carried source", day: DayKey("2026-09-01"), done: true,
            completedAt: Fixture.date("2026-09-01 12:00"), createdAt: Fixture.date("2026-09-01 09:00"))
        var copy = finished("Carried copy", on: "2026-09-02")
        copy.carriedTaskID = source.id
        planner.tasks = [focused, lone, source, copy]
        planner.focus = FocusSession(taskID: focused.id, limit: nil, now: Fixture.now)
        try file.save(planner)
        try pipeline.execute(.lifecycle(.dayChanged), origin: .background)
        let titles = Set(try file.load().tasks.map(\.title))
        XCTAssertTrue(titles.contains("Focused"))
        XCTAssertTrue(titles.contains("Only member"))
        XCTAssertTrue(titles.contains("Carried copy"))
        XCTAssertFalse(titles.contains("Carried source"))
    }

    // MARK: Erase

    func testEraseClearsContentResetsPreferencesAndIsUndoable() throws {
        let task = try pipeline.execute(
            .addTasks(["Write plan #work"], day: nil, literal: false, agentID: nil), origin: .user
        )
        .value.tasks[0]
        try pipeline.execute(.parkThought("Later idea"), origin: .user)
        try pipeline.execute(.writeNotepad(DayKey("2026-11-09"), "Note", mode: "append"), origin: .user)
        try pipeline.execute(.calendarCompletion("event-1", true), origin: .user)
        try pipeline.updatePreference(.defaultFocusMinutes(25), origin: .user)
        try pipeline.execute(.startTimer(task.id, minutes: 10), origin: .user)
        let before = try file.load()
        XCTAssertNotNil(before.focus)

        try pipeline.execute(.eraseLocalPlanner, origin: .user)
        let erased = try file.load()
        XCTAssertTrue(erased.tasks.isEmpty)
        XCTAssertTrue(erased.projects.isEmpty)
        XCTAssertTrue(erased.notes.isEmpty)
        XCTAssertTrue(erased.parkedThoughts.isEmpty)
        XCTAssertTrue(erased.focusSegments.isEmpty)
        XCTAssertNil(erased.focus)
        XCTAssertTrue(erased.completedCalendarEventIDs.isEmpty)
        XCTAssertTrue(erased.completedCalendarEventDays.isEmpty)
        XCTAssertEqual(erased.preferences, Preferences())
        XCTAssertFalse(try file.backupURLs().isEmpty, "Recovery backups are kept; erase is not secure deletion.")

        _ = try pipeline.undo()
        let restored = try file.load()
        XCTAssertEqual(restored.tasks.map(\.id), before.tasks.map(\.id))
        XCTAssertEqual(restored.parkedThoughts, before.parkedThoughts)
        XCTAssertEqual(restored.notes, before.notes)
        XCTAssertEqual(restored.projects, before.projects)
        XCTAssertEqual(restored.completedCalendarEventIDs, before.completedCalendarEventIDs)
        XCTAssertEqual(restored.preferences.defaultFocusMinutes, 25)
        XCTAssertNil(restored.focus, "A stopped timer is never resurrected by Undo.")
    }

    func testEraseUndoDoesNotOverwriteLaterEdits() throws {
        try pipeline.execute(.parkThought("Old"), origin: .user)
        try pipeline.execute(.eraseLocalPlanner, origin: .user)
        let later = try pipeline.execute(.parkThought("Newer"), origin: .background).value.thoughts[0]
        _ = try pipeline.undo()
        let thoughts = try file.load().parkedThoughts.map(\.text)
        XCTAssertTrue(thoughts.contains("Old"))
        XCTAssertTrue(thoughts.contains(later.text))
    }

    // MARK: Import

    private func exportData(_ planner: Planner) throws -> Data {
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).json")
        let source = PlannerFile(url: url, preferences: MemoryPlannerPreferences())
        try source.save(planner)
        return try Data(contentsOf: url)
    }

    func testImportAddsTasksWithFreshIdentitiesAndMappedRelationships() throws {
        let existing = try pipeline.execute(.addTasks(["Mine"], day: nil, literal: true, agentID: nil), origin: .user)
            .value.tasks[0]
        try pipeline.updatePreference(.defaultFocusMinutes(30), origin: .user)

        var source = Planner()
        let project = TaskProject(name: "Garden")
        source.projects = [project]
        var template = PlanTask(title: "Water plants", day: DayKey("2026-11-09"), createdAt: Fixture.now)
        template.repeatRule = .daily
        template.projectID = project.id
        var colliding = PlanTask(title: "Collides", day: DayKey("2026-11-09"), createdAt: Fixture.now)
        colliding.id = existing.id
        var occurrence = PlanTask(title: "Water plants", day: DayKey("2026-11-10"), createdAt: Fixture.now)
        occurrence.repeatRule = template.repeatRule
        occurrence.repeatedFrom = template.id
        source.tasks = [template, colliding, occurrence]
        source.repeatOccurrences = [RepeatOccurrence(seriesID: template.id, day: DayKey("2026-11-10"))]
        source.parkedThoughts = [ParkedThought(text: "Not imported")]
        source.preferences.defaultFocusMinutes = 90

        let added = try pipeline.perform(origin: .user) { try $0.importTasks(from: try self.exportData(source)) }
            .value
        XCTAssertEqual(added.count, 3)
        let planner = try file.load()
        XCTAssertEqual(planner.tasks.count, 4)
        XCTAssertEqual(planner.tasks.first { $0.id == existing.id }?.title, "Mine")
        XCTAssertEqual(Set(planner.tasks.map(\.id)).count, 4)
        let importedTemplate = try XCTUnwrap(added.first { $0.repeatedFrom == nil && $0.repeatRule != nil })
        XCTAssertNotEqual(importedTemplate.id, template.id)
        XCTAssertEqual(added.first { $0.repeatedFrom != nil }?.repeatedFrom, importedTemplate.id)
        XCTAssertEqual(planner.projects.first { $0.id == importedTemplate.projectID }?.name, "Garden")
        XCTAssertTrue(
            planner.repeatOccurrences.contains(
                RepeatOccurrence(seriesID: importedTemplate.id, day: DayKey("2026-11-10"))))
        XCTAssertTrue(planner.parkedThoughts.isEmpty)
        XCTAssertEqual(planner.preferences.defaultFocusMinutes, 30)

        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().tasks.map(\.id), [existing.id])
    }

    func testImportRejectsInvalidSourcesWithoutChangingPlanner() throws {
        try pipeline.execute(.addTasks(["Mine"], day: nil, literal: true, agentID: nil), origin: .user)
        let before = try Data(contentsOf: file.url)
        XCTAssertThrowsError(
            try pipeline.perform(origin: .user) { try $0.importTasks(from: Data("{oops".utf8)) })
        XCTAssertThrowsError(
            try pipeline.perform(origin: .user) { try $0.importTasks(from: try self.exportData(Planner())) })
        let newer = Data(#"{"version": 999, "tasks": []}"#.utf8)
        XCTAssertThrowsError(try pipeline.perform(origin: .user) { try $0.importTasks(from: newer) }) {
            XCTAssertTrue($0 is PlannerSchemaError)
        }
        var invalid = Planner()
        var bad = PlanTask(title: "Too long", day: DayKey("2026-11-09"), createdAt: Fixture.now)
        bad.minutes = 9999
        invalid.tasks = [PlanTask(title: "Fine", day: nil, createdAt: Fixture.now), bad]
        let invalidData = try PlannerFile.encoder.encode(PlannerDiskDocument(invalid))
        XCTAssertThrowsError(try pipeline.perform(origin: .user) { try $0.importTasks(from: invalidData) })
        XCTAssertEqual(try Data(contentsOf: file.url), before)
    }

    func testReadOnlySessionCannotImport() throws {
        let data = try exportData(
            {
                var p = Planner()
                p.tasks = [PlanTask(title: "One", day: nil, createdAt: Fixture.now)]
                return p
            }())
        XCTAssertThrowsError(try pipeline.inspect { try $0.importTasks(from: data) })
    }

    // MARK: Restore

    func testPublicRestoreReplacesWithLatestBackupAndUndoRestoresReplacedContent() throws {
        try pipeline.execute(.parkThought("First"), origin: .user)
        try pipeline.execute(.parkThought("Second"), origin: .user)
        let restored = try pipeline.restoreLatestBackup()
        XCTAssertEqual(restored.parkedThoughts.map(\.text), ["First"])
        XCTAssertEqual(try file.load().parkedThoughts.map(\.text), ["First"])
        XCTAssertTrue(pipeline.canUndo)
        _ = try pipeline.undo()
        XCTAssertEqual(try file.load().parkedThoughts.map(\.text), ["First", "Second"])
    }

    func testPublicRestoreWithoutBackupThrowsAndKeepsCurrent() throws {
        try pipeline.execute(.parkThought("Only"), origin: .user)
        let before = try Data(contentsOf: file.url)
        XCTAssertThrowsError(try pipeline.restoreLatestBackup())
        XCTAssertEqual(try Data(contentsOf: file.url), before)
    }

    func testPublicRestoreFromCorruptCurrentPreservesItAndRecordsNoUndo() throws {
        try pipeline.execute(.parkThought("Good"), origin: .background)
        try pipeline.execute(.parkThought("Better"), origin: .background)
        let corrupt = Data("{interrupted".utf8)
        try corrupt.write(to: file.url)
        let restored = try pipeline.restoreLatestBackup()
        XCTAssertEqual(restored.parkedThoughts.map(\.text), ["Good"])
        XCTAssertFalse(pipeline.canUndo)
    }
}
