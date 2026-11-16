import Combine
import Foundation
@testable import PlannerCore
import XCTest
@testable import PerchApp

final class PreferenceReloadTests: XCTestCase {
    @MainActor
    func testExplicitReloadAppliesDeviceOnlyChangesWithoutPlannerWritesOrUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        try file.save(Planner())
        let store = PlannerStore(file: file, watching: false)
        let external = PlannerCommandPipeline(file: file)
        let revision = PlannerFileRevision(url: file.url)
        let bytes = try Data(contentsOf: file.url)
        for policy in [PhoneEditPolicy.bringBack, .ignore, .bringBack] {
            _ = try external.updatePreference(.phoneEdits(policy), origin: .background)
            XCTAssertEqual(PlannerFileRevision(url: file.url), revision)
            XCTAssertEqual(try Data(contentsOf: file.url), bytes)
            store.reloadFromDisk(external: true)
            XCTAssertEqual(store.prefs.phoneEdits, policy)
            XCTAssertFalse(store.canUndo)
            XCTAssertFalse(store.canRedo)
            XCTAssertNil(store.lastError)
        }
        XCTAssertEqual(PlannerFileRevision(url: file.url), revision)
    }

    @MainActor
    func testDefaultsNotificationRefreshesDeviceOnlyPolicyWithoutRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        try file.save(Planner())
        let store = PlannerStore(file: file)
        let revision = PlannerFileRevision(url: file.url)
        let external = PlannerCommandPipeline(file: file)
        for policy in [PhoneEditPolicy.bringBack, .ignore] {
            let refreshed = expectation(description: "Defaults notification publishes \(policy)")
            let token = store.$planner.first(where: { $0.preferences.phoneEdits == policy })
                .sink { _ in refreshed.fulfill() }
            _ = try external.updatePreference(.phoneEdits(policy), origin: .background)
            XCTAssertEqual(PlannerFileRevision(url: file.url), revision)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
            await fulfillment(of: [refreshed], timeout: 3)
            XCTAssertEqual(store.prefs.phoneEdits, policy)
            XCTAssertFalse(store.canUndo)
            withExtendedLifetime(token) {}
        }
    }

    @MainActor
    func testCoalescedForcedReloadReadsPreferencesWhenFileRevisionIsUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        try file.save(Planner())
        let store = PlannerStore(file: file, watching: false)
        let revision = PlannerFileRevision(url: file.url)
        let refreshed = expectation(description: "Forced request survives an already queued ordinary request")
        let token = store.$planner.first(where: { !$0.preferences.showCalendarMeetings })
            .sink { _ in refreshed.fulfill() }
        store.requestReload()
        _ = try PlannerCommandPipeline(file: file).updatePreference(.showCalendarMeetings(false), origin: .background)
        store.requestReload(force: true)
        store.requestReload()
        await fulfillment(of: [refreshed], timeout: 3)
        XCTAssertFalse(store.prefs.showCalendarMeetings)
        XCTAssertEqual(PlannerFileRevision(url: file.url), revision)
        XCTAssertFalse(store.canUndo)
        withExtendedLifetime(token) {}
    }
}
