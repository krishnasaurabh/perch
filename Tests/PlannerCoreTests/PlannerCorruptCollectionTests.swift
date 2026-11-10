import Foundation
import XCTest
@testable import PlannerCore

/// A collection that is present but corrupt is a storage error. It must never be reinterpreted
/// as an empty collection, a migration default, or a reduced planner that then gets saved.
final class PlannerCorruptCollectionTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-corrupt-collection-\(UUID().uuidString)", isDirectory: true)
        file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Each document holds one persisted collection with the wrong JSON shape.
    private let corruptCollections: [(key: String, json: String)] = [
        ("tasks", #"{"tasks":{}}"#),
        ("tasks", #"{"tasks":42}"#),
        ("projects", #"{"projects":"none"}"#),
        ("notes", #"{"notes":{}}"#),
        ("focusSegments", #"{"focusSegments":false}"#),
        ("dismissedOverdue", #"{"dismissedOverdue":{}}"#),
        ("repeatOccurrences", #"{"repeatOccurrences":"none"}"#),
        ("completedCalendarEventDays", #"{"completedCalendarEventDays":[]}"#),
        ("preferences", #"{"preferences":"none"}"#),
        ("focus", #"{"focus":"none"}"#),
    ]

    func testPresentCorruptCollectionIsReportedAsAFieldNotAnEmptyDefault() throws {
        for fixture in corruptCollections {
            let raw = Data(fixture.json.utf8)
            try raw.write(to: file.url)
            let beforeMtime = file.modificationDate

            do {
                let planner = try file.load()
                XCTFail(
                    "\(fixture.json) loaded silently: \(planner.tasks.count) task(s), \(planner.projects.count) project(s)"
                )
                continue
            } catch let recovery as PlannerRecoveryError {
                XCTAssertEqual(recovery.keptCount, 0, fixture.json)
                XCTAssertEqual(recovery.quarantinedCount, 0, fixture.json)
                XCTAssertEqual(recovery.quarantinedFieldCount, 1, fixture.json)
                XCTAssertEqual(recovery.issues.count, 1, fixture.json)
                let issue = try XCTUnwrap(recovery.issues.first)
                XCTAssertEqual(issue.path, fixture.key, fixture.json)
                XCTAssertFalse(issue.reason.isEmpty, fixture.json)
                XCTAssertEqual(try Data(contentsOf: recovery.quarantineURL), raw, fixture.json)
            } catch {
                XCTFail("\(fixture.json) gave \(type(of: error)), expected a typed field recovery")
            }

            XCTAssertEqual(try Data(contentsOf: file.url), raw, fixture.json)
            XCTAssertEqual(file.modificationDate, beforeMtime, "\(fixture.json) was rewritten while failing to load")
        }
    }

    func testCorruptCollectionIsNotOverwrittenBySaveMutateOrExport() throws {
        let raw = Data(#"{"tasks":{}}"#.utf8)
        try raw.write(to: file.url)

        XCTAssertThrowsError(try file.save(Planner())) { error in
            guard case PlannerDataError.corrupt = error else {
                return XCTFail("Save gave \(type(of: error)), expected a typed corrupt-data error")
            }
        }
        var mutationRan = false
        XCTAssertThrowsError(
            try file.mutate {
                $0.notes.removeAll(); mutationRan = true
            }
        ) { error in
            // Mutate reloads first, so a corrupt collection surfaces as a record/field recovery
            // draft. Either typed error is acceptable as long as nothing is written.
            XCTAssertTrue(
                error is PlannerRecoveryError || error is PlannerDataError,
                "Mutate gave \(type(of: error)), expected a typed storage error")
            XCTAssertFalse(error is PlannerSchemaError)
        }
        XCTAssertFalse(mutationRan)
        let exported = directory.appendingPathComponent("export.json")
        XCTAssertThrowsError(try file.export(to: exported))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
        XCTAssertTrue(try file.backupURLs().isEmpty)
    }

    func testCorruptNestedCollectionQuarantinesOnlyItsRecord() throws {
        let raw = Data(
            #"""
            {"tasks":[
              {"id":"99999999-9999-9999-9999-999999999999","title":"Synthetic kept task","createdAt":"2026-11-09T12:00:00Z"},
              {"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","title":"Synthetic unreadable steps","createdAt":"2026-11-09T12:00:00Z","steps":{}}
            ]}
            """#.utf8)
        try raw.write(to: file.url)

        do {
            _ = try file.load()
            XCTFail("A nested corrupt collection must not load silently")
        } catch let recovery as PlannerRecoveryError {
            XCTAssertEqual(recovery.recoveredPlanner.tasks.map(\.title), ["Synthetic kept task"])
            XCTAssertEqual(recovery.keptCount, 1)
            XCTAssertEqual(recovery.quarantinedCount, 1)
            XCTAssertEqual(recovery.quarantinedFieldCount, 0)
            XCTAssertEqual(recovery.issues.first?.path, "tasks[1].steps")
        }
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
    }
}
