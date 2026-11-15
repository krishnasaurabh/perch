import Foundation
import XCTest
@testable import PerchApp
@testable import PlannerCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class SettingsDataBackupStatusTests: XCTestCase {
    func testBackupStatusReturnsDuringContentionAndRefreshesAfterRelease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PlannerFile(
            url: directory.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        try file.save(Planner())
        var planner = try file.load()
        planner.tasks.append(PlanTask(title: "Keep this task", day: "2026-11-15"))
        try file.save(planner)
        let original = try Data(contentsOf: file.url)
        let backups = try file.backupURLs()
        let latest = try XCTUnwrap(backups.first)
        let backupData = try Data(contentsOf: latest)
        let backupDate = try XCTUnwrap(
            latest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        let descriptor = open(file.url.appendingPathExtension("lock").path, O_RDWR)
        guard descriptor >= 0 else { return XCTFail("Could not open the planner lock.") }
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(descriptor, LOCK_UN) }

        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let status = SettingsDataBackupStatus(file: file)
            XCTAssertTrue(status.unavailable)
            XCTAssertFalse(status.canRestore)
            XCTAssertNil(status.lastBackup)
            returned.signal()
        }
        // Keep the writer lock held until after the reader's deadline. A waiting
        // regression fails instead of hanging the test process indefinitely.
        let result = returned.wait(timeout: .now() + 0.5)
        XCTAssertEqual(result, .success, "Backup status must not wait for the planner writer.")
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        if result == .timedOut {
            XCTAssertEqual(returned.wait(timeout: .now() + 2), .success)
        }

        let refreshed = SettingsDataBackupStatus(file: file)
        XCTAssertFalse(refreshed.unavailable)
        XCTAssertTrue(refreshed.canRestore)
        XCTAssertEqual(refreshed.lastBackup, backupDate)
        XCTAssertEqual(SettingsDataBackupStatus.policy, "Before changes, 5 copies")
        XCTAssertEqual(try Data(contentsOf: file.url), original)
        XCTAssertEqual(try file.backupURLs(), backups)
        XCTAssertEqual(try Data(contentsOf: latest), backupData)
    }
}
