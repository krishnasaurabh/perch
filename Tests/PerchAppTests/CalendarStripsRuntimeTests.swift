import Combine
import EventKit
import Foundation
import PerchUI
@testable import PlannerCore
import XCTest
@testable import PerchApp

@MainActor
private final class StripsCalendar: CalendarAccess {
    var authorization: EKAuthorizationStatus = .fullAccess
    private let eventsStore = EKEventStore()
    lazy var calendar = EKCalendar(for: .event, eventStore: eventsStore)
    var allDay = false
    let start: Date
    init(start: Date) { self.start = start }
    func requestAccess() async throws {}
    func calendars() -> [EKCalendar] { [calendar] }
    func events(on day: Date, calendars: [EKCalendar]) -> [CalendarService.Event] {
        [
            .init(
                id: "synthetic-meeting", title: "Review", start: start, end: start.addingTimeInterval(3600),
                allDay: allDay, colorHex: "", location: nil, calendarTitle: "Synthetic")
        ]
    }
}

@MainActor
private final class StripsTime {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

final class CalendarStripsRuntimeTests: XCTestCase {
    @MainActor
    func testOffKeepsStartingNowAndItsHalfOpenBoundariesOnTheLiveCoordinator() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let time = StripsTime()
        let start = time.now.addingTimeInterval(480)
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        try file.mutate { $0.preferences.meetingHeadsUp = .off }
        let store = PlannerStore(file: file, now: { time.now }, watching: false)
        let source = StripsCalendar(start: start)
        let service = CalendarService(store: store, source: source)
        let model = NotchModel()
        let strips = NotchStrips(store: store, calendar: service, model: model, now: { time.now })
        model.strips = strips
        XCTAssertNil(strips.currentActivity, "Off suppresses only the advance phase")
        XCTAssertEqual(strips.nextWake, start, "Starting-now remains a separate phase")
        time.now = start.addingTimeInterval(-0.001)
        strips.refresh()
        XCTAssertNil(strips.currentActivity)
        XCTAssertEqual(strips.nextWake, start)
        time.now = start
        strips.refresh()
        let activity = try XCTUnwrap(strips.currentActivity)
        XCTAssertEqual(activity.stripKind, .headsUp)
        XCTAssertEqual(activity.title, "Review")
        XCTAssertEqual(activity.subtitle, "Starting now")
        XCTAssertEqual(activity.eventStart, start)
        let end = start.addingTimeInterval(NotchActivityTimeline.lateGrace)
        XCTAssertEqual(strips.nextWake, end)
        time.now = end.addingTimeInterval(-0.001)
        strips.refresh()
        XCTAssertEqual(strips.currentActivity?.id, activity.id, "Refresh preserves the mounted strip identity")
        XCTAssertEqual(strips.currentActivity?.subtitle, "Starting now")
        time.now = end
        strips.refresh()
        XCTAssertNil(strips.currentActivity, "The starting-now grace window is half-open")
        XCTAssertNil(strips.nextWake)
    }

    @MainActor
    func testStoredPreferencesRefreshTheLiveCoordinatorWithoutReminderTasks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let time = StripsTime()
        let start = time.now.addingTimeInterval(480)
        let store = PlannerStore(
            file: PlannerFile(
                url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences()),
            now: { time.now }, watching: false)
        let source = StripsCalendar(start: start)
        let service = CalendarService(store: store, source: source)
        let model = NotchModel()
        let strips = NotchStrips(store: store, calendar: service, model: model, now: { time.now })
        model.strips = strips
        XCTAssertTrue(store.planner.tasks.isEmpty)
        XCTAssertNil(strips.currentActivity, "Default five-minute heads-up has not started")
        XCTAssertEqual(strips.nextWake, start.addingTimeInterval(-300))
        let visible = expectation(description: "A stored ten-minute preference emits the heads-up")
        let first = model.$activity.compactMap { $0 }.first().sink { _ in visible.fulfill() }
        XCTAssertNotNil(store.apply { try $0.updatePreference(.meetingHeadsUp(.tenMinutes)) })
        await fulfillment(of: [visible], timeout: 2)
        let activity = try XCTUnwrap(strips.currentActivity)
        XCTAssertEqual(activity.title, "Review")
        XCTAssertEqual(activity.subtitle, "Starts in 8 min")
        XCTAssertEqual(strips.nextWake, start)
        let hidden = expectation(description: "Off withdraws the heads-up without recreating the coordinator")
        let second = model.$activity.first(where: { $0 == nil }).sink { _ in hidden.fulfill() }
        XCTAssertNotNil(store.apply { try $0.updatePreference(.meetingHeadsUp(.off)) })
        await fulfillment(of: [hidden], timeout: 2)
        XCTAssertNil(strips.currentActivity)
        XCTAssertEqual(strips.nextWake, start, "Starting-now remains a separate phase")
        time.now = start
        strips.refresh()
        XCTAssertEqual(strips.currentActivity?.subtitle, "Starting now")
        let suppressed = expectation(description: "Hiding meetings withdraws Starting now too")
        let third = model.$activity.first(where: { $0 == nil }).sink { _ in suppressed.fulfill() }
        XCTAssertNotNil(store.apply { try $0.updatePreference(.showCalendarMeetings(false)) })
        await fulfillment(of: [suppressed], timeout: 2)
        XCTAssertNil(strips.currentActivity)
        XCTAssertNil(strips.nextWake)
        // Exclude all-day events independently of CalendarService's preference filtering.
        source.allDay = true
        XCTAssertNotNil(store.apply { try $0.updatePreference(.showCalendarMeetings(true)) })
        service.refresh(day: time.now)
        strips.refresh()
        XCTAssertEqual(service.events.count, 1)
        XCTAssertNil(strips.currentActivity)
        XCTAssertNil(strips.nextWake)
        withExtendedLifetime((first, second, third)) {}
    }
}
