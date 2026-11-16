import Combine
import EventKit
import Foundation
import PerchUI
import PlannerCore
import XCTest
@testable import PerchApp

@MainActor
private final class RuntimeCalendar: CalendarAccess {
    var authorization: EKAuthorizationStatus = .fullAccess
    private let eventsStore = EKEventStore()
    lazy var calendar = EKCalendar(for: .event, eventStore: eventsStore)
    let start: Date
    init(start: Date) { self.start = start }
    func requestAccess() async throws {}
    func calendars() -> [EKCalendar] { [calendar] }
    func events(on day: Date, calendars: [EKCalendar]) -> [CalendarService.Event] {
        [
            .init(
                id: "synthetic-meeting", title: "Review", start: start, end: start.addingTimeInterval(3600),
                allDay: false, colorHex: "", location: nil, calendarTitle: "Synthetic")
        ]
    }
}

final class CalendarRuntimeConsumerTests: XCTestCase {
    @MainActor
    func testRetainedReminderUpdatesItsTextWithoutReplacingIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let store = PlannerStore(
            file: PlannerFile(url: root.appendingPathComponent("planner.json")), now: { now }, watching: false)
        let id = try XCTUnwrap(
            store.send(.addTasks(["Original title"], day: nil, literal: true, agentID: nil))?.tasks.first?.id)
        store.updateTask(id) { $0.remindAt = now.addingTimeInterval(-120) }
        let service = CalendarService(store: store, source: RuntimeCalendar(start: now.addingTimeInterval(480)))
        let model = NotchModel()
        let driver = NotchTimelineDriver(store: store, calendar: service)
        driver.start(model: model)
        let uiID = try XCTUnwrap(model.activity?.id)
        XCTAssertEqual(model.activity?.title, "Original title")
        let renamed = expectation(description: "Retained reminder reflects task edits")
        let token = model.$activity.first(where: { $0?.title == "Renamed task" }).sink { _ in renamed.fulfill() }
        XCTAssertNotNil(store.send(.rename(id, "Renamed task")))
        await fulfillment(of: [renamed], timeout: 2)
        XCTAssertEqual(model.activity?.id, uiID)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testMeetingPreferencePublishesAndChangesYourDayWithoutExplicitRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        let source = RuntimeCalendar(start: Date().addingTimeInterval(480))
        let service = CalendarService(store: store, source: source)
        XCTAssertEqual(service.events.count, 1)
        func meetings() -> [YourDayTimeline.Meeting] {
            service.yourDayMeetings(day: store.today, calendar: store.engine.calendar, hiddenIDs: [], completedIDs: [])
        }
        XCTAssertEqual(meetings().count, 1)
        let hidden = expectation(description: "Stored preference removes published calendar events")
        let token = service.$events.dropFirst().first(where: { $0.isEmpty }).sink { _ in hidden.fulfill() }
        XCTAssertNotNil(store.apply { try $0.updatePreference(.showCalendarMeetings(false)) })
        await fulfillment(of: [hidden], timeout: 2)
        XCTAssertTrue(service.events.isEmpty)
        XCTAssertTrue(meetings().isEmpty)
        XCTAssertEqual(service.calendars.count, 1, "Calendar selection remains available while meetings are hidden")
        let visible = expectation(description: "Undo restores events without recreating the service")
        let restored = service.$events.first(where: { !$0.isEmpty }).sink { _ in visible.fulfill() }
        store.undo()
        await fulfillment(of: [visible], timeout: 2)
        XCTAssertEqual(meetings().count, 1)
        withExtendedLifetime((token, restored)) {}
    }

    @MainActor
    func testHeadsUpEditRefreshesDriverEvenWhenThereAreNoReminderTasks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        let source = RuntimeCalendar(start: Date().addingTimeInterval(480))
        let service = CalendarService(store: store, source: source)
        let model = NotchModel()
        let driver = NotchTimelineDriver(store: store, calendar: service)
        driver.start(model: model)
        XCTAssertNil(model.activity, "Default five-minute heads-up has not started")
        let visible = expectation(description: "A stored ten-minute preference emits the heads-up")
        visible.assertForOverFulfill = false
        driver.onPass = { id, _ in if id != nil { visible.fulfill() } }
        XCTAssertNotNil(store.apply { try $0.updatePreference(.meetingHeadsUp(.tenMinutes)) })
        await fulfillment(of: [visible], timeout: 2)
        XCTAssertEqual(model.activity?.title, "Review")
        XCTAssertEqual(driver.nextWake, source.start)
        let ui = try XCTUnwrap(model.activity)
        XCTAssertEqual(driver.subtitle(for: ui, now: source.start.addingTimeInterval(-480)), "Starts in 8 min")
        let hidden = expectation(description: "Off withdraws the heads-up without recreating the driver")
        hidden.assertForOverFulfill = false
        driver.onPass = { id, _ in if id == nil { hidden.fulfill() } }
        XCTAssertNotNil(store.apply { try $0.updatePreference(.meetingHeadsUp(.off)) })
        await fulfillment(of: [hidden], timeout: 2)
        XCTAssertNil(model.activity)
        XCTAssertEqual(driver.nextWake, source.start, "Starting-now remains a separate phase")
    }
}
