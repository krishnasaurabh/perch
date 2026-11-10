import Foundation
import XCTest
@testable import PlannerCore

/// A document from a newer schema is not corrupt data and must never be rewritten,
/// quarantined, downgraded or replaced by a save or a restore.
final class PlannerSchemaFailClosedTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-schema-\(UUID().uuidString)", isDirectory: true)
        file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// FNV-1a over the exact bytes. Compared together with a full byte comparison, so a
    /// rewrite that preserves size but not content cannot pass.
    private func fingerprint(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    func testFutureSchemaFailsClosedWithoutChangingBytesMtimeOrBackups() throws {
        try file.save(Planner())
        var second = Planner()
        second.preferences.defaultFocusMinutes = 20
        try file.save(second)
        let backups = try file.backupURLs()
        XCTAssertFalse(backups.isEmpty)
        let backupFingerprints = try backups.map { fingerprint(try Data(contentsOf: $0)) }

        let future = Data(
            #"""
            {"version":999,"unknownCollection":[1,2,3],"tasks":[{"id":"44444444-4444-4444-4444-444444444444","title":"Future task","createdAt":"2026-11-09T12:00:00Z","futureKey":{"keep":true}}]}
            """#.utf8)
        try future.write(to: file.url)

        let beforeFingerprint = fingerprint(try Data(contentsOf: file.url))
        let beforeMtime = try XCTUnwrap(file.modificationDate)
        let beforeNames = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()

        XCTAssertThrowsError(try file.load()) { XCTAssertTrue($0 is PlannerSchemaError) }
        XCTAssertThrowsError(try file.save(Planner())) { XCTAssertTrue($0 is PlannerSchemaError) }
        var mutationRan = false
        XCTAssertThrowsError(try file.mutate { _ in mutationRan = true }) { XCTAssertTrue($0 is PlannerSchemaError) }
        XCTAssertFalse(mutationRan)
        XCTAssertThrowsError(try file.restoreLatestBackup()) { XCTAssertTrue($0 is PlannerSchemaError) }
        let exported = directory.appendingPathComponent("export.json")
        XCTAssertThrowsError(try file.export(to: exported)) { XCTAssertTrue($0 is PlannerSchemaError) }

        // Nothing about the current file changed: bytes, hash, mtime, or neighbours.
        XCTAssertEqual(try Data(contentsOf: file.url), future)
        XCTAssertEqual(fingerprint(try Data(contentsOf: file.url)), beforeFingerprint)
        XCTAssertEqual(file.modificationDate, beforeMtime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), beforeNames)
        XCTAssertEqual(try file.backupURLs(), backups)
        XCTAssertEqual(try backups.map { fingerprint(try Data(contentsOf: $0)) }, backupFingerprints)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.contains(".corrupt-") || $0.contains(".recovered") || $0.contains(".issues") })
    }

    func testEveryUnsupportedVersionFailsClosedWithItsOwnTypedError() throws {
        for version in [0, -1, 2, 999, 1_000_000] {
            let raw = Data("{\"version\":\(version),\"tasks\":[],\"preferences\":{}}".utf8)
            try raw.write(to: file.url)
            let beforeFingerprint = fingerprint(try Data(contentsOf: file.url))
            let beforeMtime = file.modificationDate

            XCTAssertThrowsError(try file.load(), "version \(version)") { error in
                guard let schema = error as? PlannerSchemaError else {
                    return XCTFail("version \(version) gave \(type(of: error)), not a typed schema error")
                }
                XCTAssertEqual(schema.version, version)
                XCTAssertTrue(schema.localizedDescription.contains("No data was rewritten"))
            }

            XCTAssertEqual(try Data(contentsOf: file.url), raw, "version \(version) was rewritten")
            XCTAssertEqual(fingerprint(try Data(contentsOf: file.url)), beforeFingerprint)
            XCTAssertEqual(file.modificationDate, beforeMtime)
        }
    }

    func testSaveOfAnotherSchemaVersionIsRejectedBeforeTouchingTheFile() throws {
        try file.save(Planner())
        let before = try Data(contentsOf: file.url)
        let beforeMtime = file.modificationDate
        var future = Planner()
        future.version = Planner.currentVersion + 1
        XCTAssertThrowsError(try file.save(future)) { XCTAssertTrue($0 is PlannerSchemaError) }
        XCTAssertEqual(try Data(contentsOf: file.url), before)
        XCTAssertEqual(file.modificationDate, beforeMtime)
        XCTAssertTrue(try file.backupURLs().isEmpty)
    }
}
