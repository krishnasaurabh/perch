import Foundation
import XCTest
@testable import PlannerCore

/// Recovery contract for mixed documents: valid records survive in their original order,
/// rejected records are quarantined with their raw JSON bytes intact, the failure is typed,
/// and the file on disk is never rewritten.
final class PlannerRecoveryMixedRecordTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-mixed-\(UUID().uuidString)", isDirectory: true)
        file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func task(_ suffix: Int, title: String, extra: String = "") -> String {
        #"{"id":"00000000-0000-0000-0000-00000000000\#(suffix)","title":"\#(title)","createdAt":"2026-11-09T12:00:00Z"\#(extra)}"#
    }

    func testMixedRecordsAcrossEveryCollectionKeepValidOrderAndQuarantineExactBytes() throws {
        let unknownEnum = task(2, title: "Unknown priority", extra: #","priority":"future-priority""#)
        let malformedSteps = task(4, title: "Malformed steps", extra: #","steps":42"#)
        let badProject = ##"{"id":"not-a-uuid","name":"Rejected project","colorHex":"#123456"}"##
        let badNote = #"{"day":"2026-02-30","text":"Impossible day"}"#
        let raw = Data("""
        {
          "tasks": [\(task(1, title: "Keep one")), \(unknownEnum), \(task(3, title: "Keep two")), \(malformedSteps), \(task(5, title: "Keep three"))],
          "projects": [\(badProject), {"id":"00000000-0000-0000-0000-000000000010","name":"Keep project","colorHex":"#8E8CF5"}],
          "notes": [\(badNote), {"day":"2026-11-09","text":"Keep note"}]
        }
        """.utf8)
        try raw.write(to: file.url)
        let beforeMtime = file.modificationDate

        let recovery: PlannerRecoveryError
        do {
            let planner = try file.load()
            return XCTFail("A document with rejected records must not load silently: \(planner.tasks.count) task(s)")
        } catch let error as PlannerRecoveryError {
            recovery = error
        }

        XCTAssertEqual(recovery.recoveredPlanner.tasks.map(\.title), ["Keep one", "Keep two", "Keep three"])
        XCTAssertEqual(recovery.recoveredPlanner.projects.map(\.name), ["Keep project"])
        XCTAssertEqual(recovery.recoveredPlanner.notes.map(\.text), ["Keep note"])
        XCTAssertEqual(recovery.keptCount, 5)
        XCTAssertEqual(recovery.quarantinedCount, 4)
        XCTAssertEqual(recovery.quarantinedFieldCount, 0)
        XCTAssertEqual(recovery.issues.map(\.path), ["tasks[1].priority", "tasks[3].steps", "projects[0].id", "notes[0].day"])
        XCTAssertFalse(recovery.issues.contains { $0.reason.isEmpty })

        // The original file is untouched, and the recovery copy is a byte-exact duplicate.
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
        XCTAssertEqual(file.modificationDate, beforeMtime)
        XCTAssertEqual(try Data(contentsOf: recovery.originalURL), raw)

        // Every rejected record is present verbatim in the quarantine, not re-serialized.
        let quarantine = try String(contentsOf: recovery.quarantineURL, encoding: .utf8)
        for rejected in [unknownEnum, malformedSteps, badProject, badNote] {
            XCTAssertTrue(quarantine.contains(rejected), "Quarantine lost the raw bytes of \(rejected)")
        }

        // The draft is a reduced valid-record view, so it cannot stand in for the original.
        let draft = try String(contentsOf: recovery.recoveredURL, encoding: .utf8)
        XCTAssertFalse(draft.contains("future-priority"))
        XCTAssertFalse(draft.contains("Rejected project"))
        XCTAssertFalse(draft.contains("Impossible day"))
        XCTAssertEqual(try PlannerFile.decoder.decode(Planner.self, from: Data(contentsOf: recovery.recoveredURL)),
                       recovery.recoveredPlanner)
    }

    func testQuarantineKeepsRawSpellingsThatAnyReencodeWouldChange() throws {
        // Unknown keys, a padded exponent and a \u escape all survive only if the raw bytes
        // are copied rather than decoded and written back.
        let rejected = #"{"id":"00000000-0000-0000-0000-000000000002","title":"Rejected","createdAt":"2026-11-09T12:00:00Z","priority":"future-priority","unknown":{"snowman":"\u2603","ratio":1.000e+03,"flag":true}}"#
        let raw = Data("{\"tasks\":[\(task(1, title: "Keep")),\(rejected)]}".utf8)
        try raw.write(to: file.url)

        let recovery: PlannerRecoveryError
        do {
            _ = try file.load()
            return XCTFail("An unknown enum value must be reported, not defaulted")
        } catch let error as PlannerRecoveryError {
            recovery = error
        }

        XCTAssertEqual(recovery.recoveredPlanner.tasks.map(\.title), ["Keep"])
        XCTAssertEqual(recovery.issues.map(\.path), ["tasks[1].priority"])
        XCTAssertEqual(recovery.keptCount, 1)
        XCTAssertEqual(recovery.quarantinedCount, 1)

        let quarantine = try String(contentsOf: recovery.quarantineURL, encoding: .utf8)
        XCTAssertEqual(quarantine, String(decoding: raw, as: UTF8.self))
        for spelling in [rejected, #"1.000e+03"#, #"\u2603"#, #""unknown""#, "future-priority"] {
            XCTAssertTrue(quarantine.contains(spelling), "Quarantine normalized away \(spelling)")
        }
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
    }
}
