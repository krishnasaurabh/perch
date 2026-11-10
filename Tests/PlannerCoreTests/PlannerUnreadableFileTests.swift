import Foundation
import XCTest
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import PlannerCore

/// An unreadable file is a storage failure, not an empty planner. Nothing may be written,
/// replaced, or reported as missing while the bytes on disk are still intact.
final class PlannerUnreadableFileTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!
    private var raw: Data!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-unreadable-\(UUID().uuidString)", isDirectory: true)
        file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
        raw = Data(#"""
        {"version":1,"tasks":[{"id":"55555555-5555-5555-5555-555555555555","title":"Synthetic unreadable task","day":"2026-11-09","createdAt":"2026-11-09T12:00:00Z"}]}
        """#.utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Mode 000 blocks reads for ordinary users. Root bypasses the mode check, so the same
    /// production path is exercised with the equivalent POSIX permission error instead of
    /// weakening or skipping the assertion.
    private func unreadableFile() -> PlannerFile {
        if geteuid() != 0 { return file }
        var io = PlannerFile.IO()
        let target: URL = file.url
        io.read = { url in
            if url.standardizedFileURL == target.standardizedFileURL {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                              userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
            }
            return try Data(contentsOf: url)
        }
        return PlannerFile(url: file.url, io: io)
    }

    private func removeReadPermission() throws {
        if geteuid() != 0 {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.url.path)
            XCTAssertFalse(FileManager.default.isReadableFile(atPath: file.url.path),
                           "mode 000 should block reads for a non-root user")
        }
    }

    private func restoreReadPermission() throws {
        if geteuid() != 0 {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        }
    }

    func testRemovedReadPermissionGivesTypedUnreadableErrorAndKeepsData() throws {
        try raw.write(to: file.url)
        let beforeMtime = try XCTUnwrap(file.modificationDate)
        try removeReadPermission()
        defer { try? restoreReadPermission() }

        let unreadable = unreadableFile()
        let operations: [(String, () throws -> Void)] = [
            ("load", { _ = try unreadable.load() }),
            ("save", { try unreadable.save(Planner()) }),
            ("mutate", { _ = try unreadable.mutate { $0.tasks.removeAll() } }),
        ]
        for (name, operation) in operations {
            XCTAssertThrowsError(try operation(), name) { error in
                guard case let PlannerDataError.unreadable(url, reason) = error else {
                    return XCTFail("\(name) gave \(type(of: error)), expected a typed unreadable-data error")
                }
                XCTAssertEqual(url, self.file.url)
                XCTAssertFalse(reason.isEmpty)
                XCTAssertFalse(error is PlannerRecoveryError, "\(name) must not be treated as recoverable data")
                XCTAssertTrue(error.localizedDescription.contains("The original was not changed"))
            }
        }

        try restoreReadPermission()
        XCTAssertEqual(try Data(contentsOf: file.url), raw)
        XCTAssertEqual(file.modificationDate, beforeMtime)
        XCTAssertTrue(try file.backupURLs().isEmpty, "A failed operation must not create a backup")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["planner.json", "planner.json.lock"])
        XCTAssertEqual(try file.load().tasks.map(\.title), ["Synthetic unreadable task"])
    }

    func testUnreadableCurrentFileIsNeverReplacedByBackupRestore() throws {
        var first = Planner()
        first.preferences.defaultFocusMinutes = 20
        try file.save(first)
        var second = first
        second.preferences.defaultFocusMinutes = 45
        second.tasks = [PlanTask(title: "Synthetic current task", day: "2026-11-09", createdAt: Fixture.now)]
        try file.save(second)
        XCTAssertFalse(try file.backupURLs().isEmpty)

        let before = try Data(contentsOf: file.url)
        let beforeMtime = try XCTUnwrap(file.modificationDate)
        try removeReadPermission()
        defer { try? restoreReadPermission() }

        XCTAssertThrowsError(try unreadableFile().restoreLatestBackup()) { error in
            guard case PlannerDataError.unreadable = error else {
                return XCTFail("Restore over an unreadable current file gave \(type(of: error))")
            }
        }
        XCTAssertThrowsError(try unreadableFile().load())

        try restoreReadPermission()
        XCTAssertEqual(try Data(contentsOf: file.url), before)
        XCTAssertEqual(file.modificationDate, beforeMtime)
        XCTAssertEqual(try file.load().tasks.map(\.title), ["Synthetic current task"])
    }
}
