import Foundation
import XCTest
@testable import PlannerCore

final class PlannerDecodingTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func task(_ suffix: String, extra: String = "") -> String {
        #"{"id":"00000000-0000-0000-0000-00000000000"# + suffix
            + #"","title":"Synthetic task","createdAt":"2026-11-09T12:00:00Z""# + extra + "}"
    }

    private func recover(_ data: Data, using target: PlannerFile? = nil) throws -> PlannerRecoveryError {
        try data.write(to: file.url)
        do {
            _ = try (target ?? file).load()
            XCTFail("A damaged planner must not load silently")
        } catch let error as PlannerRecoveryError {
            return error
        }
        throw PlannerError("Expected a recoverable record error")
    }

    func testPresentMalformedCollectionNeverDefaultsToEmpty() throws {
        for json in [
            #"{"tasks":[{}]}"#, #"{"projects":42}"#, #"{"notes":null}"#,
            #"{"focusSegments":[{}]}"#, #"{"dismissedOverdue":[false]}"#,
            #"{"repeatOccurrences":[{}]}"#, #"{"completedCalendarEventDays":{"event":"2026-02-30"}}"#,
        ] {
            XCTAssertThrowsError(try PlannerFile.decoder.decode(Planner.self, from: Data(json.utf8)), json)
        }
    }

    func testNewerSchemaCannotLoadSaveOrRestoreOverCurrentFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
        try file.save(Planner())
        var another = Planner(); another.preferences.defaultFocusMinutes = 20
        try file.save(another)
        let future = Data(#"{"version":999,"tasks":[],"unknownData":{"keep":true}}"#.utf8)
        try future.write(to: file.url)
        XCTAssertThrowsError(try file.load())
        XCTAssertThrowsError(try file.save(Planner()))
        XCTAssertThrowsError(try file.restoreLatestBackup())
        XCTAssertEqual(try Data(contentsOf: file.url), future)
    }

    func testMissingLegacyFieldsStillDefault() throws {
        let p = try PlannerFile.decoder.decode(Planner.self, from: Data("{}".utf8))
        XCTAssertEqual(p, Planner())
        let task = try PlannerFile.decoder.decode(
            PlanTask.self,
            from: Data(
                #"{"id":"00000000-0000-0000-0000-000000000001","title":"Legacy fixture","createdAt":"2026-11-09T12:00:00Z"}"#
                    .utf8))
        XCTAssertEqual(task.priority, .none)
        XCTAssertTrue(task.steps.isEmpty)
        XCTAssertNil(task.day)
    }

    func testMixedTasksRetainNeighborsAndLosslessOriginalBytes() throws {
        let unknownEnum = task(
            "2", extra: #", "priority":"future-priority", "unknown":{"text":"\u2603","number":1.000e+03}"#)
        let raw = Data(
            (" {\n\"tasks\":[" + task("1") + "," + unknownEnum + ",null," + task("3")
                + "], \"unknown\": [true, 1e99] }\n").utf8)
        let error = try recover(raw)
        XCTAssertEqual(
            error.recoveredPlanner.tasks.map(\.id.uuidString),
            [
                "00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000003",
            ])
        XCTAssertEqual(error.issues.map(\.path), ["tasks[1].priority", "tasks[2]"])
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
        XCTAssertEqual(try Data(contentsOf: error.originalURL), raw)
        XCTAssertEqual(
            try PlannerFile.decoder.decode(Planner.self, from: Data(contentsOf: error.recoveredURL)),
            error.recoveredPlanner)
        XCTAssertEqual(
            try JSONDecoder().decode([PlannerRecoveryIssue].self, from: Data(contentsOf: error.issuesURL)), error.issues
        )
        XCTAssertTrue(error.localizedDescription.contains("read-only"))
        XCTAssertTrue(error.localizedDescription.contains("cannot be saved"))
        XCTAssertTrue(error.localizedDescription.contains("Do not replace the original"))
    }

    func testMalformedNestedRecordQuarantinesItsTaskWithoutDamagingNeighbors() throws {
        for extra in [
            #", "steps":[{}]"#,
            #", "repeatRule":{"unit":"year","interval":1,"weekdays":[],"weekdaysOnly":false,"fromCompletion":false}"#,
            #", "deadline":"2026-02-30""#, #", "day":42"#, #", "remindAt":"invalid""#,
        ] {
            let raw = Data(("{\"tasks\":[" + task("1") + "," + task("2", extra: extra) + "," + task("3") + "]}").utf8)
            let error: PlannerRecoveryError
            do { error = try recover(raw) } catch {
                XCTFail("Recovery failed for fixture field \(extra): \(error)"); continue
            }
            XCTAssertEqual(error.recoveredPlanner.tasks.count, 2, extra)
            XCTAssertEqual(error.issues.count, 1, extra)
            XCTAssertTrue(try XCTUnwrap(error.issues.first).path.hasPrefix("tasks[1]"), extra)
            XCTAssertEqual(try Data(contentsOf: error.originalURL), raw)
        }
    }

    func testEveryPersistedCollectionRetainsValidRecords() throws {
        let raw = Data(
            #"""
            {"projects":[{"id":"00000000-0000-0000-0000-000000000001","name":"Synthetic project","colorHex":"#123456"},false],
             "notes":[{"day":"2026-11-09","text":"Synthetic note"},{"day":"2026-02-30","text":"invalid day"}],
             "focusSegments":[{"start":"2026-11-09T12:00:00Z","end":"2026-11-09T12:01:00Z"},{}],
             "dismissedOverdue":["00000000-0000-0000-0000-000000000001","bad-id"],
             "repeatOccurrences":[{"seriesID":"00000000-0000-0000-0000-000000000001","day":"2026-11-09"},{}],
             "completedCalendarEventIDs":["event-1",false],
             "completedCalendarEventDays":{"event-1":"2026-11-09","event-2":"bad-day"}}
            """#.utf8)
        let error = try recover(raw)
        let p = error.recoveredPlanner
        XCTAssertEqual(p.projects.count, 1)
        XCTAssertEqual(p.notes.count, 1)
        XCTAssertEqual(p.focusSegments.count, 1)
        XCTAssertEqual(p.dismissedOverdue.count, 1)
        XCTAssertEqual(p.repeatOccurrences.count, 1)
        XCTAssertEqual(p.completedCalendarEventIDs, ["event-1"])
        XCTAssertEqual(p.completedCalendarEventDays, ["event-1": "2026-11-09"])
        XCTAssertEqual(error.issues.count, 7)
        XCTAssertEqual(try Data(contentsOf: error.originalURL), raw)
    }

    func testMalformedWholeFieldsBecomeExplicitRecoveryIssues() throws {
        let raw = Data(
            ("{\"tasks\":[" + task("1")
                + #"],"projects":42,"notes":null,"focus":{"state":"future"},"preferences":{"hiddenCalendarIDs":42}}"#)
                .utf8)
        let error = try recover(raw)
        XCTAssertEqual(error.recoveredPlanner.tasks.count, 1)
        XCTAssertEqual(error.issues.count, 4)
        XCTAssertEqual(try Data(contentsOf: error.originalURL), raw)
    }

    func testRecoveryNeverPromotesReducedDraftToCurrentOrBackup() throws {
        try file.save(Planner())
        var next = Planner(); next.preferences.defaultFocusMinutes = 20
        try file.save(next)
        let backups = try file.backupURLs()
        let backupBytes = try backups.map { try Data(contentsOf: $0) }
        let raw = Data(("{\"tasks\":[" + task("1") + ",{}]}").utf8)
        let recovery = try recover(raw)
        var bodyRan = false
        for _ in 0..<4 {
            XCTAssertThrowsError(try file.load())
            XCTAssertThrowsError(try file.save(recovery.recoveredPlanner))
            XCTAssertThrowsError(try file.mutate { _ in bodyRan = true })
            XCTAssertThrowsError(try file.export(to: directory.appendingPathComponent("export.json")))
        }
        XCTAssertFalse(bodyRan)
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
        XCTAssertEqual(try file.backupURLs(), backups)
        XCTAssertEqual(try backups.map { try Data(contentsOf: $0) }, backupBytes)
        let artifacts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertEqual(artifacts.count, 3, "one exact original, one draft, one issue index; no reload churn")
        XCTAssertEqual(try file.restoreLatestBackup(), Planner())
        XCTAssertEqual(try Data(contentsOf: recovery.originalURL), raw)
    }

    func testNewSchemaHasNoRecoverySideEffectsEvenWithMalformedRecords() throws {
        let raw = Data(#"{"version":2,"tasks":[{}]}"#.utf8)
        try raw.write(to: file.url)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertThrowsError(try file.load()) { XCTAssertTrue($0 is PlannerSchemaError) }
        XCTAssertThrowsError(try file.save(Planner())) { XCTAssertTrue($0 is PlannerSchemaError) }
        let after = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(after).subtracting(before), ["planner.json.lock"])
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
        var future = Planner(); future.version = 2
        let fresh = PlannerFile(url: directory.appendingPathComponent("fresh.json"))
        XCTAssertThrowsError(try fresh.save(future))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.url.path))
    }

    func testInvalidVersionCannotBeInferredFromRecords() throws {
        for version in ["null", "\"1\"", "false", "0", "-1", "1.5"] {
            let data = Data(("{\"version\":" + version + ",\"tasks\":[]}").utf8)
            try data.write(to: file.url)
            XCTAssertThrowsError(try file.load(), version)
            XCTAssertThrowsError(try file.save(Planner()), version)
            XCTAssertEqual(try Data(contentsOf: file.url), data)
        }
    }

    func testUnreadableDataIsNotTreatedAsMissingAndCannotSave() throws {
        let raw = Data(("{\"tasks\":[" + task("1") + "]}").utf8)
        try raw.write(to: file.url)
        var reads = 0
        var io = PlannerFile.IO()
        io.read = { url in
            if url == self.file.url { reads += 1; throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        }
        let unreadable = PlannerFile(url: file.url, io: io)
        XCTAssertThrowsError(try unreadable.load())
        XCTAssertThrowsError(try unreadable.save(Planner()))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
        XCTAssertTrue(try file.backupURLs().isEmpty)
    }

    func testTruncatedDocumentIsOnlyPreservedNotPartiallyParsed() throws {
        let raw = Data(("{\"tasks\":[" + task("1") + ",").utf8)
        try raw.write(to: file.url)
        XCTAssertThrowsError(try file.load()) { error in
            XCTAssertFalse(error is PlannerRecoveryError)
            XCTAssertTrue(error.localizedDescription.contains("original is unchanged"))
        }
        let copies = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), raw)
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
    }

    func testFailedOrTruncatedQuarantineNeverOffersReducedPlanner() throws {
        for truncated in [false, true] {
            let raw = Data(("{\"tasks\":[" + task("1") + ",{}]}").utf8)
            try raw.write(to: file.url)
            var io = PlannerFile.IO()
            io.copy = { _, destination in
                if truncated {
                    try Data(raw.prefix(3)).write(to: destination)
                } else {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
            }
            XCTAssertThrowsError(try PlannerFile(url: file.url, io: io).load()) { error in
                XCTAssertFalse(error is PlannerRecoveryError)
                XCTAssertTrue(error.localizedDescription.contains("Unable to preserve"))
            }
            XCTAssertEqual(try Data(contentsOf: file.url), raw)
        }
    }

    func testFailedDraftWriteKeepsVerifiedOriginalAndRejectsLoad() throws {
        let raw = Data(("{\"tasks\":[" + task("1") + ",{}]}").utf8)
        try raw.write(to: file.url)
        var io = PlannerFile.IO()
        io.write = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try PlannerFile(url: file.url, io: io).load()) { error in
            XCTAssertFalse(error is PlannerRecoveryError)
            XCTAssertTrue(error.localizedDescription.contains("draft could not be saved"))
        }
        let copies = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), raw)
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
    }

    func testNullTaskFieldsDoNotActLikeMissingFields() throws {
        for key in ["done", "priority", "notes", "steps", "focusedSeconds", "carryCount"] {
            let raw = Data(task("1", extra: ",\"\(key)\":null").utf8)
            XCTAssertThrowsError(try PlannerFile.decoder.decode(PlanTask.self, from: raw), key)
        }
    }

    func testPresentMalformedPreferencesAreNotMigrationDefaults() throws {
        for json in [
            #"{"carryMode":"future"}"#, #"{"carryMode":null}"#, #"{"hiddenCalendarIDs":null}"#,
            #"{"defaultFocusMinutes":"25"}"#, #"{"showOnDisplay":false}"#,
        ] {
            XCTAssertThrowsError(try PlannerFile.decoder.decode(Preferences.self, from: Data(json.utf8)), json)
        }
        XCTAssertEqual(try PlannerFile.decoder.decode(Preferences.self, from: Data("{}".utf8)), Preferences())
    }
}
