import Foundation
import XCTest
@testable import PlannerCore

final class PlannerRecoveryContractTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func loadError(file sourceFile: StaticString = #filePath, line: UInt = #line) throws -> Error {
        var caught: Error?
        XCTAssertThrowsError(try file.load(), file: sourceFile, line: line) { caught = $0 }
        return try XCTUnwrap(caught, file: sourceFile, line: line)
    }

    func testRecoveryReportsKeptRecordsRejectedRecordsAndRejectedFieldsSeparately() throws {
        let raw = Data(
            #"""
            {"tasks":[
                {"id":"00000000-0000-0000-0000-000000000001","title":"Synthetic task","createdAt":"2026-11-09T12:00:00Z"},
                {"id":"00000000-0000-0000-0000-000000000002","title":"Synthetic task","createdAt":"2026-11-09T12:00:00Z","priority":"future"},
                null],
             "notes":[{"day":"2026-11-09","text":"Synthetic note"},false],
             "completedCalendarEventDays":{"event":"2026-11-09","invalid":"not-a-day"},
             "projects":null,"preferences":{"carryMode":"future"}}
            """#.utf8)
        try raw.write(to: file.url)
        do {
            let error = try loadError()
            guard let recovery = error as? PlannerRecoveryError else { return XCTFail("Expected record recovery") }
            XCTAssertEqual(recovery.issues.count, 6)
            XCTAssertEqual(recovery.keptCount, 3)
            XCTAssertEqual(recovery.quarantinedCount, 4)
            XCTAssertEqual(recovery.quarantinedFieldCount, 2)
            XCTAssertEqual(recovery.quarantineURL, recovery.originalURL)
            XCTAssertEqual(try Data(contentsOf: recovery.quarantineURL), raw)
            XCTAssertTrue(recovery.localizedDescription.contains("Kept 3 valid record(s)"))
            XCTAssertTrue(
                recovery.localizedDescription.contains("Quarantined 4 invalid record(s) and 2 invalid field(s)"))
            XCTAssertTrue(recovery.localizedDescription.contains(recovery.originalURL.path))
            XCTAssertTrue(recovery.localizedDescription.contains("original planner is unchanged"))
        }
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
    }

    func testCountsIncludeEveryCollectionAndCountNestedFailureOnce() throws {
        let raw = Data(
            #"""
            {"tasks":[
                {"id":"00000000-0000-0000-0000-000000000001","title":"Synthetic task","createdAt":"2026-11-09T12:00:00Z"},
                {"id":"00000000-0000-0000-0000-000000000002","title":"Synthetic task","createdAt":"2026-11-09T12:00:00Z","steps":[{},{}]}],
             "projects":[{"id":"00000000-0000-0000-0000-000000000001","name":"Synthetic project","colorHex":"#123456"},false],
             "notes":[{"day":"2026-11-09","text":"Synthetic note"},false],
             "focusSegments":[{"start":"2026-11-09T12:00:00Z","end":"2026-11-09T12:01:00Z"},{}],
             "dismissedOverdue":["00000000-0000-0000-0000-000000000001",false],
             "repeatOccurrences":[{"seriesID":"00000000-0000-0000-0000-000000000001","day":"2026-11-09"},{}],
             "completedCalendarEventIDs":["event","event",false],
             "completedCalendarEventDays":{"event":"2026-11-09","invalid":"not-a-day"}}
            """#.utf8)
        try raw.write(to: file.url)
        var quarantineURL: URL?
        for _ in 0..<3 {
            do {
                let error = try loadError()
                guard let recovery = error as? PlannerRecoveryError else { return XCTFail("Expected record recovery") }
                XCTAssertEqual(recovery.keptCount, [1, 1, 1, 1, 1, 1, 2, 1].reduce(0, +))
                XCTAssertEqual(recovery.quarantinedCount, 8)
                XCTAssertEqual(recovery.quarantinedFieldCount, 0)
                XCTAssertEqual(recovery.issues.count, 8)
                XCTAssertEqual(recovery.recoveredPlanner.completedCalendarEventIDs, ["event"])
                XCTAssertEqual(try Data(contentsOf: recovery.quarantineURL), raw)
                if let previous = quarantineURL { XCTAssertEqual(previous, recovery.quarantineURL) }
                quarantineURL = recovery.quarantineURL
            }
        }
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
    }

    func testWholeFieldCorruptionHasNoInventedRecordCounts() throws {
        let raw = Data(#"{"tasks":null,"projects":42,"preferences":{"carryMode":"future"}}"#.utf8)
        try raw.write(to: file.url)
        do {
            let error = try loadError()
            guard let recovery = error as? PlannerRecoveryError else { return XCTFail("Expected field recovery") }
            XCTAssertEqual(recovery.keptCount, 0)
            XCTAssertEqual(recovery.quarantinedCount, 0)
            XCTAssertEqual(recovery.quarantinedFieldCount, 3)
            XCTAssertEqual(recovery.issues.count, 3)
            XCTAssertEqual(try Data(contentsOf: recovery.quarantineURL), raw)
        }
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
    }

    func testRejectedSaveExposesTypedCorruptionWithoutInventedQuarantine() throws {
        let raw = Data(#"{"tasks":[{}]}"#.utf8)
        try raw.write(to: file.url)
        XCTAssertThrowsError(try file.save(Planner())) { error in
            guard case let PlannerDataError.corrupt(url, quarantineURL, _) = error else {
                return XCTFail("Expected a typed corrupt-data error, got \(error)")
            }
            XCTAssertEqual(url, self.file.url)
            XCTAssertNil(quarantineURL, "Saving does not create or claim a recovery copy")
        }
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
    }

    func testUnreadableFileHasDistinctTypedFailureAndNoWrite() throws {
        let raw = Data(#"{"tasks":[]}"#.utf8)
        try raw.write(to: file.url)
        var io = PlannerFile.IO()
        var writes = 0
        io.read = { url in
            if url.standardizedFileURL == self.file.url.standardizedFileURL {
                throw CocoaError(.fileReadNoPermission)
            }
            return try Data(contentsOf: url)
        }
        io.write = { _, _ in writes += 1 }
        let unreadable = PlannerFile(url: file.url, io: io)
        for operation in [{ _ = try unreadable.load() }, { try unreadable.save(Planner()) }] {
            XCTAssertThrowsError(try operation()) { error in
                guard case let PlannerDataError.unreadable(url, reason) = error else {
                    return XCTFail("Expected a typed unreadable-data error, got \(error)")
                }
                XCTAssertEqual(url, self.file.url)
                XCTAssertFalse(reason.isEmpty)
                XCTAssertTrue(error.localizedDescription.contains("The original was not changed"))
            }
        }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
    }

    func testRecoveryPathsStayStableThroughASymlinkedDataDirectory() throws {
        let real = directory.appendingPathComponent("real", isDirectory: true)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let aliasedFile = PlannerFile(url: alias.appendingPathComponent("planner.json"))
        let raw = Data(#"{"tasks":[{}]}"#.utf8)
        try raw.write(to: aliasedFile.url)
        var firstError: PlannerRecoveryError?
        XCTAssertThrowsError(try aliasedFile.load()) { firstError = $0 as? PlannerRecoveryError }
        let first = try XCTUnwrap(firstError)
        for _ in 0..<3 {
            var nextError: PlannerRecoveryError?
            XCTAssertThrowsError(try aliasedFile.load()) { nextError = $0 as? PlannerRecoveryError }
            let next = try XCTUnwrap(nextError)
            XCTAssertEqual(next.quarantineURL, first.quarantineURL)
            XCTAssertEqual(next.recoveredURL, first.recoveredURL)
            XCTAssertEqual(next.issuesURL, first.issuesURL)
            XCTAssertEqual(next.localizedDescription, first.localizedDescription)
            XCTAssertEqual(try Data(contentsOf: next.quarantineURL), raw)
        }
        XCTAssertEqual(try Data(contentsOf: aliasedFile.url), raw)
    }

    func testTruncatedJSONHasDistinctTypedFailureAndVerifiedQuarantine() throws {
        let raw = Data(#"{"tasks":["#.utf8)
        try raw.write(to: file.url)
        do {
            let error = try loadError()
            guard case let PlannerDataError.corrupt(url, quarantineURL, _) = error else {
                return XCTFail("Expected a typed corrupt-data error, got \(error)")
            }
            XCTAssertEqual(url, self.file.url)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantineURL)), raw)
            XCTAssertFalse(error is PlannerRecoveryError)
            XCTAssertTrue(error.localizedDescription.contains("original is unchanged"))
        }
        let copies = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), raw)
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
    }
}
