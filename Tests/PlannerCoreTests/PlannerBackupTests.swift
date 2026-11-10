import Foundation
import XCTest
@testable import PlannerCore

final class PlannerBackupTests: XCTestCase {
    private var directory: URL!
    private var file: PlannerFile!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = PlannerFile(url: directory.appendingPathComponent("planner.json"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func planner(_ revision: Int) -> Planner {
        var p = Planner()
        p.preferences.defaultFocusMinutes = revision
        return p
    }

    private var backupDirectory: URL { file.url.appendingPathExtension("backups") }

    private func snapshots() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func testBackupContainsPreviousBytesBeforeReplacement() throws {
        try file.save(planner(1))
        let original = try Data(contentsOf: file.url)
        try file.save(planner(2))
        let backups = try snapshots()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        XCTAssertEqual(try file.load(), planner(2))
    }

    func testCorruptCurrentCannotBeOverwrittenBySave() throws {
        try file.save(planner(1))
        try file.save(planner(2))
        let corrupt = Data("{interrupted".utf8)
        try corrupt.write(to: file.url)
        XCTAssertThrowsError(try file.save(planner(3)))
        XCTAssertEqual(try Data(contentsOf: file.url), corrupt)
    }

    func testBackupDirectoryFailurePreventsSave() throws {
        try file.save(planner(1))
        try Data("not a directory".utf8).write(to: backupDirectory)
        XCTAssertThrowsError(try file.save(planner(2)))
        XCTAssertEqual(try file.load(), planner(1))
    }

    func testRotationRetainsFiveMostRecentPreSaveRevisions() throws {
        for revision in 1...12 { try file.save(planner(revision)) }
        let backups = try file.backupURLs()
        XCTAssertEqual(backups.count, PlannerFile.backupLimit)
        let revisions = try backups.map { try PlannerFile.decoder.decode(Planner.self, from: Data(contentsOf: $0)).preferences.defaultFocusMinutes }
        XCTAssertEqual(revisions, [11, 10, 9, 8, 7])
        XCTAssertEqual(try snapshots(), backups)
    }

    func testUnchangedSaveAndThrowingMutationDoNotRotate() throws {
        try file.save(planner(1))
        XCTAssertTrue(try file.backupURLs().isEmpty)
        try file.save(planner(2))
        let before = try file.backupURLs()
        try file.save(planner(2))
        try file.mutate { _ in }
        XCTAssertThrowsError(try file.mutate { p in
            p = planner(3)
            throw PlannerError("Cancelled synthetic edit")
        })
        XCTAssertEqual(try file.backupURLs(), before)
        XCTAssertEqual(try file.load(), planner(2))
    }

    func testCorruptionDoesNotReplaceKnownGoodBackups() throws {
        try file.save(planner(1))
        try file.save(planner(2))
        let backup = try XCTUnwrap(file.backupURLs().first)
        let bytes = try Data(contentsOf: backup)
        for corrupt in ["{truncated", "{\"tasks\":[{\"title\":\"Missing identifier\"}]}",
                        "{\"focusSegments\":[{}]}", "{\"notes\":42}"] {
            try Data(corrupt.utf8).write(to: file.url)
            XCTAssertThrowsError(try file.load())
            XCTAssertThrowsError(try file.mutate { $0 = planner(3) })
            XCTAssertThrowsError(try file.save(planner(3)))
            XCTAssertEqual(try file.backupURLs(), [backup])
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
            XCTAssertEqual(try Data(contentsOf: file.url), Data(corrupt.utf8))
        }
    }

    func testRestorePreservesCorruptCurrentAndExactBackupBytes() throws {
        try file.save(planner(1))
        try file.save(planner(2))
        let backups = try file.backupURLs()
        let bytes = try Data(contentsOf: XCTUnwrap(backups.first))
        let corrupt = Data("{partial".utf8)
        try corrupt.write(to: file.url)
        XCTAssertEqual(try file.restoreLatestBackup(), planner(1))
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertEqual(try file.backupURLs(), backups)
        let recovery = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt-") }
        XCTAssertEqual(recovery.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recovery.first)), corrupt)
    }

    func testRestoreSkipsInvalidAndUnreadableBackups() throws {
        for revision in 1...4 { try file.save(planner(revision)) }
        let backups = try file.backupURLs()
        try Data("{invalid".utf8).write(to: backups[0])
        var io = PlannerFile.IO()
        io.read = { target in
            if target == backups[1] { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: target)
        }
        let isolated = PlannerFile(url: file.url, io: io)
        try Data("{corrupt".utf8).write(to: file.url)
        XCTAssertEqual(try isolated.restoreLatestBackup(), planner(1))
        XCTAssertEqual(try file.load(), planner(1))
    }

    func testRestoreWithNoValidBackupLeavesCurrentUntouched() throws {
        try file.save(planner(1))
        XCTAssertThrowsError(try file.restoreLatestBackup())
        try file.save(planner(2))
        for backup in try file.backupURLs() { try Data("[]".utf8).write(to: backup) }
        let original = try Data(contentsOf: file.url)
        XCTAssertThrowsError(try file.restoreLatestBackup())
        XCTAssertEqual(try Data(contentsOf: file.url), original)
    }

    func testRestoreMissingCurrentAndBackUpValidCurrentBeforeRestore() throws {
        try file.save(planner(1))
        try file.save(planner(2))
        XCTAssertEqual(try file.restoreLatestBackup(), planner(1))
        let newest = try XCTUnwrap(file.backupURLs().first)
        XCTAssertEqual(try PlannerFile.decoder.decode(Planner.self, from: Data(contentsOf: newest)), planner(2))
        try FileManager.default.removeItem(at: file.url)
        XCTAssertEqual(try file.restoreLatestBackup(), planner(2))
        XCTAssertEqual(try file.load(), planner(2))
    }

    func testBackupDiskFullAndPartialWriteFailClosed() throws {
        try file.save(planner(1))
        try file.save(planner(2))
        let before = try file.backupURLs()
        let original = try Data(contentsOf: file.url)
        var io = PlannerFile.IO()
        io.write = { data, target in
            if target.deletingLastPathComponent().path == self.backupDirectory.path {
                try Data(data.prefix(8)).write(to: target)
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: target, options: .atomic)
        }
        XCTAssertThrowsError(try PlannerFile(url: file.url, io: io).save(planner(3)))
        XCTAssertEqual(try Data(contentsOf: file.url), original)
        XCTAssertEqual(try file.backupURLs(), before)
    }

    func testBackupWriteThatSilentlyTruncatesIsRejected() throws {
        try file.save(planner(1))
        var io = PlannerFile.IO()
        io.write = { data, target in try Data(data.prefix(8)).write(to: target, options: .atomic) }
        XCTAssertThrowsError(try PlannerFile(url: file.url, io: io).save(planner(2)))
        XCTAssertEqual(try file.load(), planner(1))
        XCTAssertTrue(try file.backupURLs().isEmpty)
    }

    func testFailedAtomicReplacementRetainsCurrentAndDoesNotChurnHistory() throws {
        for revision in 1...6 { try file.save(planner(revision)) }
        let original = try Data(contentsOf: file.url)
        var io = PlannerFile.IO()
        io.write = { data, target in
            if target == self.file.url { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: target, options: .atomic)
        }
        let isolated = PlannerFile(url: file.url, io: io)
        XCTAssertThrowsError(try isolated.save(planner(7)))
        let beforeRetry = try file.backupURLs()
        for _ in 0..<8 { XCTAssertThrowsError(try isolated.save(planner(7))) }
        XCTAssertEqual(try file.backupURLs(), beforeRetry)
        XCTAssertEqual(try Data(contentsOf: file.url), original)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(beforeRetry.first)), original)
    }

    func testUnreadableCurrentFailsLoadSaveAndRestoreWithoutChangingBackups() throws {
        try file.save(planner(1))
        try file.save(planner(2))
        let backups = try file.backupURLs()
        let original = try Data(contentsOf: file.url)
        var io = PlannerFile.IO()
        io.read = { target in
            if target == self.file.url { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: target)
        }
        let isolated = PlannerFile(url: file.url, io: io)
        XCTAssertThrowsError(try isolated.load())
        XCTAssertThrowsError(try isolated.save(planner(3)))
        XCTAssertThrowsError(try isolated.restoreLatestBackup())
        XCTAssertEqual(try file.backupURLs(), backups)
        XCTAssertEqual(try Data(contentsOf: file.url), original)
    }

    func testRecoveryCopyFailureNeverClaimsSuccessOrRestores() throws {
        try file.save(planner(1))
        try file.save(planner(2))
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: file.url)
        var io = PlannerFile.IO()
        io.copy = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let isolated = PlannerFile(url: file.url, io: io)
        XCTAssertThrowsError(try isolated.load()) { error in
            let message = (error as? PlannerError)?.message ?? ""
            XCTAssertTrue(message.contains("Unable to preserve"))
            XCTAssertFalse(message.contains("copy is saved"))
        }
        XCTAssertThrowsError(try isolated.restoreLatestBackup())
        XCTAssertEqual(try Data(contentsOf: file.url), corrupt)
    }

    func testRetentionFailureStopsSaveAndKeepsVerifiedBackup() throws {
        for revision in 1...6 { try file.save(planner(revision)) }
        let original = try Data(contentsOf: file.url)
        var io = PlannerFile.IO()
        io.remove = { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertThrowsError(try PlannerFile(url: file.url, io: io).save(planner(7))) { error in
            XCTAssertTrue(((error as? PlannerError)?.message ?? "").contains("retention failed"))
        }
        XCTAssertEqual(try Data(contentsOf: file.url), original)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(file.backupURLs().first)), original)
        let blockedCount = try file.backupURLs().count
        XCTAssertThrowsError(try PlannerFile(url: file.url, io: io).save(planner(7)))
        XCTAssertEqual(try file.backupURLs().count, blockedCount)
        // Once permissions recover, retry prunes and commits without another duplicate.
        try file.save(planner(7))
        XCTAssertEqual(try file.backupURLs().count, PlannerFile.backupLimit)
        XCTAssertEqual(try file.load(), planner(7))
    }

    func testRotationIgnoresUnrelatedFiles() throws {
        try file.save(planner(1))
        try file.save(planner(2))
        let unrelated = backupDirectory.appendingPathComponent("keep.json")
        try Data("user export".utf8).write(to: unrelated)
        for revision in 3...12 { try file.save(planner(revision)) }
        XCTAssertEqual(try file.backupURLs().count, PlannerFile.backupLimit)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("user export".utf8))
    }

    func testLegacyUnknownFieldsAndNanosecondDatesSurviveBackupRestore() throws {
        let legacy = Data(#"{"tasks":[],"preferences":{"defaultFocusMinutes":25},"futureField":[1,2,3]}"#.utf8)
        try legacy.write(to: file.url)
        try file.save(planner(2))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(file.backupURLs().first)), legacy)
        XCTAssertEqual(try file.restoreLatestBackup().preferences.defaultFocusMinutes, 25)
        XCTAssertEqual(try Data(contentsOf: file.url), legacy)
        var p = planner(3)
        let timestamp = Date(timeIntervalSinceReferenceDate: 0.123456789)
        p.tasks = [PlanTask(title: "Fractional timestamp fixture", day: nil, createdAt: timestamp)]
        try file.save(p)
        try file.save(planner(4))
        let restored = try file.restoreLatestBackup()
        XCTAssertEqual(try XCTUnwrap(restored.tasks.first).createdAt.timeIntervalSinceReferenceDate,
                       timestamp.timeIntervalSinceReferenceDate, accuracy: 0.000000001)
    }

    func testFailedEncodeDoesNotRotateOrReplace() throws {
        try file.save(planner(1))
        try file.save(planner(2))
        let before = try file.backupURLs()
        var invalid = planner(3)
        invalid.tasks = [PlanTask(title: "Invalid numeric fixture", day: nil, focusedSeconds: .nan)]
        XCTAssertThrowsError(try file.save(invalid))
        XCTAssertEqual(try file.load(), planner(2))
        XCTAssertEqual(try file.backupURLs(), before)
    }

    func testLockOpenFailureDoesNotWrite() throws {
        try FileManager.default.createDirectory(at: file.lockURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try file.save(planner(1)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testExportOverCurrentUsesBackupSafeguards() throws {
        let legacy = Data(#"{"tasks":[],"futureField":true}"#.utf8)
        try legacy.write(to: file.url)
        try file.export(to: file.url)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(file.backupURLs().first)), legacy)
        XCTAssertEqual(try file.load(), Planner())
    }

    func testFailedRestoreWriteKeepsOriginalAndBackup() throws {
        try file.save(planner(1))
        try file.save(planner(2))
        let original = Data("{interrupted restore fixture".utf8)
        try original.write(to: file.url)
        let backups = try file.backupURLs()
        var io = PlannerFile.IO()
        io.write = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try PlannerFile(url: file.url, io: io).restoreLatestBackup())
        XCTAssertEqual(try Data(contentsOf: file.url), original)
        XCTAssertEqual(try file.backupURLs(), backups)
    }

    func testDirectSaveWaitsForMutationLock() throws {
        try file.save(planner(1))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let saved = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let failures = LockedFailures()
        let target = file!
        let replacement = planner(3)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                try target.mutate { p in
                    entered.signal()
                    guard release.wait(timeout: .now() + 10) == .success else { throw PlannerError("Lock fixture timed out") }
                    p.preferences.defaultFocusMinutes = 2
                }
            } catch { failures.add(error) }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave(); saved.signal() }
            do { try PlannerFile(url: target.url).save(replacement) }
            catch { failures.add(error) }
        }
        XCTAssertEqual(saved.wait(timeout: .now() + 0.1), .timedOut)
        release.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(failures.values.isEmpty)
        XCTAssertEqual(try file.load(), replacement)
        let revisions = try file.backupURLs().map { try PlannerFile.decoder.decode(Planner.self, from: Data(contentsOf: $0)).preferences.defaultFocusMinutes }
        XCTAssertEqual(revisions, [2, 1])
    }

    private final class LockedFailures: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ error: Error) { lock.lock(); defer { lock.unlock() }; storage.append(String(describing: error)) }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    func testConcurrentProcessesCreateCompleteOrderedBackups() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let cli = root.appendingPathComponent(".build/debug/perch-cli")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli.path))
        var processes: [Process] = []
        for index in 0..<8 {
            let process = Process()
            process.executableURL = cli
            process.arguments = ["add", "Backup concurrency fixture \(index)"]
            var env = ProcessInfo.processInfo.environment
            env["PERCH_DATA"] = file.url.path
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            processes.append(process)
        }
        for process in processes {
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        XCTAssertEqual(try file.load().tasks.count, 8)
        let counts = try file.backupURLs().map { try PlannerFile.decoder.decode(Planner.self, from: Data(contentsOf: $0)).tasks.count }
        XCTAssertEqual(counts, [7, 6, 5, 4, 3])
    }
}
