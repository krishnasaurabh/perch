import Foundation
import EventKit
import UniformTypeIdentifiers
import PlannerCore
import PerchUI
import XCTest
@testable import PerchApp

@MainActor private final class YourDayTestCalendar: CalendarAccess {
    var authorization: EKAuthorizationStatus = .fullAccess
    var days: [Date] = []
    let eventStore = EKEventStore()
    lazy var testCalendar = EKCalendar(for: .event, eventStore: eventStore)
    func requestAccess() async throws {}
    func calendars() -> [EKCalendar] { [testCalendar] }
    func events(on day: Date, calendars: [EKCalendar]) -> [CalendarService.Event] {
        days.append(day)
        return [
            .init(
                id: String(day.timeIntervalSinceReferenceDate), title: "Review",
                start: day.addingTimeInterval(2 * 3600), end: day.addingTimeInterval(3 * 3600),
                allDay: false, colorHex: "", location: nil, calendarTitle: "Work")
        ]
    }
}

final class YourDayActionsTests: XCTestCase {
    @MainActor func testChecklistProviderKeepsTypedAndLegacyIdentities() async {
        let provider = YourDayTaskDrag.provider(for: UUID())
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.perchTask.identifier))
        XCTAssertTrue(provider.canLoadObject(ofClass: NSString.self))
    }

    @MainActor func testCapturePublishesAndClearsWithoutWritingPlanner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = DayKey("2026-11-13").date().addingTimeInterval(9 * 3600)
        let store = PlannerStore(
            file: PlannerFile(url: root.appendingPathComponent("planner.json")),
            now: { now }, watching: false)
        let before = store.planner
        let home = TodayHomeState()
        YourDayCapture.update(
            text: "Review today at 1:30pm for 20 min", day: .day(store.today),
            home: home, store: store, language: .english)
        XCTAssertEqual(home.captureDraft?.minutes, 20)
        XCTAssertEqual(
            home.captureDraft?.startTime,
            store.capture.parse("Review today at 1:30pm for 20 min", language: .english).startAt)
        YourDayCapture.update(
            text: "No scheduled time", day: .day(store.today), home: home, store: store, language: .english)
        XCTAssertNil(home.captureDraft)
        YourDayCapture.update(
            text: "Review tomorrow at 1:30pm", day: .day(store.today), home: home, store: store, language: .english)
        XCTAssertNil(home.captureDraft)
        YourDayCapture.update(text: "Review today at 1:30pm", day: .inbox, home: home, store: store, language: .english)
        XCTAssertNil(home.captureDraft)
        YourDayCapture.update(
            text: "Review today at 1:30pm", day: .day(store.today), home: home, store: store, language: nil)
        XCTAssertNil(home.captureDraft)
        XCTAssertEqual(store.planner, before)
    }

    @MainActor func testCalendarQueriesBothCivilDaysAndKeepsPickerFiltering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = DayKey("2026-11-13").date().addingTimeInterval(10 * 3600)
        let store = PlannerStore(
            file: PlannerFile(url: root.appendingPathComponent("planner.json")),
            now: { now }, watching: false)
        let source = YourDayTestCalendar()
        let service = CalendarService(store: store, source: source)
        source.days = []
        let events = service.yourDayMeetings(
            day: store.today, calendar: store.engine.calendar,
            hiddenIDs: [], completedIDs: [])
        XCTAssertEqual(source.days, [store.today.date(), store.today.adding(days: 1).date()])
        XCTAssertEqual(events.count, 2)
        source.days = []
        XCTAssertTrue(
            service.yourDayMeetings(
                day: store.today, calendar: store.engine.calendar,
                hiddenIDs: [source.testCalendar.calendarIdentifier], completedIDs: []
            ).isEmpty)
        XCTAssertTrue(source.days.isEmpty)
    }

    @MainActor func testDropWritesOnlyStartTimeAndCanUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PlannerStore(
            file: PlannerFile(url: root.appendingPathComponent("planner.json")),
            now: { now }, watching: false)
        let id = try XCTUnwrap(
            store.send(.addTasks(["Write notes"], day: nil, literal: true, agentID: nil))?.tasks.first?.id)
        let reminder = now.addingTimeInterval(600)
        store.updateTask(id) {
            $0.remindAt = reminder; $0.minutes = 25
        }
        let start = now.addingTimeInterval(1800)
        XCTAssertTrue(YourDayActions.setStart(id, at: start, store: store))
        let saved = try XCTUnwrap(store.file.load().tasks.first { $0.id == id })
        XCTAssertEqual(saved.startAt, start)
        XCTAssertEqual(saved.remindAt, reminder)
        XCTAssertEqual(saved.minutes, 25)
        store.undo()
        XCTAssertNil(store.planner.tasks.first { $0.id == id }?.startAt)
        XCTAssertEqual(store.planner.tasks.first { $0.id == id }?.remindAt, reminder)
    }

    @MainActor func testDropsRejectMissingOtherDayAndOutsideDayWithoutWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PlannerStore(
            file: PlannerFile(url: root.appendingPathComponent("planner.json")),
            now: { now }, watching: false)
        let today = try XCTUnwrap(
            store.send(.addTasks(["Today"], day: nil, literal: true, agentID: nil))?.tasks.first?.id)
        let tomorrow = try XCTUnwrap(
            store.send(.addTasks(["Tomorrow"], day: .day(store.today.adding(days: 1)), literal: true, agentID: nil))?
                .tasks.first?.id)
        let before = try Data(contentsOf: store.file.url)
        XCTAssertFalse(YourDayActions.setStart(UUID(), at: now, store: store))
        XCTAssertFalse(YourDayActions.setStart(tomorrow, at: now, store: store))
        XCTAssertFalse(YourDayActions.setStart(today, at: now.addingTimeInterval(86400), store: store))
        XCTAssertEqual(try Data(contentsOf: store.file.url), before)
    }
}
