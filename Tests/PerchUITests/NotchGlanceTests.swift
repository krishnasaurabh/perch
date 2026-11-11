@testable import PlannerCore
import XCTest
@testable import PerchUI

final class NotchGlanceTests: XCTestCase {
    private let today: DayKey = "2026-11-09"

    private func planner() -> Planner {
        var planner = Planner()
        planner.tasks = [
            PlanTask(title: "Synthetic private title", day: today),
            PlanTask(title: String(repeating: "Long synthetic title ", count: 100), day: today),
            PlanTask(title: "Completed", day: today, done: true),
            PlanTask(title: "Tomorrow", day: "2026-11-10"),
            PlanTask(title: "Overdue", day: "2026-11-08"),
            PlanTask(title: "Inbox", day: nil),
        ]
        return planner
    }

    func testDefaultAndLegacyPreferencesKeepGlanceOff() throws {
        XCTAssertFalse(Preferences().notchTaskCount)
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).notchTaskCount)
        XCTAssertFalse(try JSONDecoder().decode(DevicePreferences.self, from: Data("{}".utf8)).notchTaskCount)
        XCTAssertNil(NotchGlancePresentation(planner: planner(), today: today))
    }

    func testExplicitOptInCountsOnlyUnfinishedTodayAndNeverContainsTaskText() throws {
        var planner = planner()
        planner.preferences.notchTaskCount = true
        let glance = try XCTUnwrap(NotchGlancePresentation(planner: planner, today: today))
        XCTAssertEqual(glance.text, "2 tasks")
        XCTAssertEqual(glance.accessibilityLabel, "2 unfinished tasks today. Open Today")
        XCTAssertFalse(glance.text.contains("Synthetic"))
        XCTAssertFalse(glance.accessibilityLabel.contains("title"))
        planner.tasks[0].done = true
        XCTAssertEqual(NotchGlancePresentation(planner: planner, today: today)?.text, "1 task")
        planner.tasks[1].done = true
        XCTAssertNil(NotchGlancePresentation(planner: planner, today: today))
        XCTAssertNil(NotchGlancePresentation(planner: planner, today: "2026-11-11"))
    }

    func testTimerActivityAndExpandedWorkspaceTakePriority() {
        var planner = planner()
        planner.preferences.notchTaskCount = true
        XCTAssertNil(NotchGlancePresentation(planner: planner, today: today, expanded: true))
        XCTAssertNil(NotchGlancePresentation(planner: planner, today: today, activityVisible: true))
        for state in [FocusSession.State.running, .paused] {
            var focus = FocusSession(taskID: nil, limit: nil, now: Date(timeIntervalSince1970: 0))
            focus.state = state
            planner.focus = focus
            planner.preferences.notchTimerPlacement = .hidden
            XCTAssertNil(NotchGlancePresentation(planner: planner, today: today))
        }
        planner.focus?.state = .finished
        XCTAssertNotNil(NotchGlancePresentation(planner: planner, today: today))
        planner.preferences.notchTaskCount = false
        XCTAssertNil(NotchGlancePresentation(planner: planner, today: today))
    }

    func testLargeCountsAreBoundedWithoutHidingTheAccessibleCount() throws {
        var planner = Planner()
        planner.preferences.notchTaskCount = true
        planner.tasks = (0..<1000).map { _ in PlanTask(title: "Synthetic", day: today) }
        let glance = try XCTUnwrap(NotchGlancePresentation(planner: planner, today: today))
        XCTAssertEqual(glance.text, "999+ tasks")
        XCTAssertEqual(glance.accessibilityLabel, "1000 unfinished tasks today. Open Today")
    }

    func testPreferenceRoundTripsOnDeviceButDoesNotTravelInExport() throws {
        var preferences = Preferences()
        preferences.notchTaskCount = true
        let encoded = try JSONEncoder().encode(DevicePreferences(preferences))
        let decoded = try JSONDecoder().decode(DevicePreferences.self, from: encoded)
        var restored = Preferences()
        decoded.apply(to: &restored)
        XCTAssertTrue(restored.notchTaskCount)
        var planner = Planner()
        planner.preferences = preferences
        let exported = try PlannerFile.encoder.encode(PlannerExportDocument(planner: planner))
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("notchTaskCount"))
    }

    func testSharedFileDoesNotOptInAnotherDevice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("planner.json")
        let deviceA = PlannerFile(url: url, preferences: MemoryPlannerPreferences())
        let deviceB = PlannerFile(url: url, preferences: MemoryPlannerPreferences())
        var planner = planner()
        planner.preferences.notchTaskCount = true
        try deviceA.save(planner)
        XCTAssertTrue(try deviceA.load().preferences.notchTaskCount)
        XCTAssertFalse(try deviceB.load().preferences.notchTaskCount)
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("notchTaskCount"))
    }

    func testMalformedPresentPreferenceIsRejected() {
        for value in ["null", "1", "\"true\"", "{}"] {
            let data = Data("{\"notchTaskCount\":\(value)}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(Preferences.self, from: data))
            XCTAssertThrowsError(try JSONDecoder().decode(DevicePreferences.self, from: data))
        }
    }
}
