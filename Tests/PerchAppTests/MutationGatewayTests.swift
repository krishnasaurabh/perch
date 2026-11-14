import AppKit
import EventKit
import PlannerCore
import PerchUI
import UserNotifications
import XCTest
@testable import PerchApp

@MainActor
private final class FakeNotifications: NotificationAccess {
    var authorized = false
    var messages: [String] = []
    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate) {}
    func isAuthorized() async -> Bool { authorized }
    func requestAuthorization() async throws { authorized = true }
    func post(id: String, title: String, body: String) { messages.append(id) }
    func pendingReminders() async -> [ScheduledReminder] { [] }
    func deliveredReminderIDs() async -> Set<String> { [] }
    func schedule(_ reminder: ScheduledReminder) async throws {}
    func removeReminders(ids: [String]) {}
}

@MainActor
private final class FakePasteboard: PasteboardAccess {
    var changeCount = 0
    var declaredTypes: [String] = []
    var fileURLs: [URL] = []
    var imageData: Data?
    var plainText: String?
    func replace(with value: PasteboardValue) {
        changeCount += 1
        if case .text(let text) = value { plainText = text }
    }
}

@MainActor
private final class FakeCalendar: CalendarAccess {
    var authorization: EKAuthorizationStatus = .denied
    var requests = 0
    func requestAccess() async throws { requests += 1 }
    func calendars() -> [EKCalendar] { [] }
    func events(on day: Date, calendars: [EKCalendar]) -> [CalendarService.Event] { [] }
}

final class MutationGatewayTests: XCTestCase {
    func testUIEditsAndDebouncedTextCannotRewriteHistory() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var now = Date(timeIntervalSince1970: 1_800_000_000)
            let store = PlannerStore(
                file: PlannerFile(url: root.appendingPathComponent("planner.json")), now: { now }, watching: false)
            let id = try XCTUnwrap(
                store.send(.addTasks(["Original"], day: nil, literal: true, agentID: nil))?.tasks.first?.id)
            now += 86_400
            store.updateTask(id) { $0.notes = "Rejected" }
            XCTAssertNotNil(store.lastError)
            store.setText("Rejected", for: .title(id))
            XCTAssertFalse(store.flushPendingText())
            XCTAssertEqual(try store.file.load().tasks[0].title, "Original")
            XCTAssertEqual(try store.file.load().tasks[0].notes, "")
        }
    }

    func testUIInvalidDurationAndCompletionDraftAreRejected() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = PlannerStore(
                file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
            let id = try XCTUnwrap(
                store.send(.addTasks(["Original"], day: nil, literal: true, agentID: nil))?.tasks.first?.id)
            store.updateTask(id) { $0.minutes = -1 }
            XCTAssertNotNil(store.lastError)
            XCTAssertNil(store.planner.tasks[0].minutes)
            store.updateTask(id) { $0.done = true }
            XCTAssertNotNil(store.lastError)
            XCTAssertFalse(store.planner.tasks[0].done)
        }
    }

    func testDayRolloverDoesNotNeedHomeViewAndDoesNotReplayAfterUndo() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var now = Date(timeIntervalSince1970: 1_800_000_000)
            let store = PlannerStore(
                file: PlannerFile(url: root.appendingPathComponent("planner.json")), now: { now }, watching: false)
            store.updatePrefs { $0.carryMode = .ask }
            store.beginApplication()
            _ = store.send(.addTasks(["Carry this"], day: nil, literal: true, agentID: nil))
            store.updatePrefs { $0.carryMode = .auto }
            now += 86_400
            store.advanceLifecycle()
            XCTAssertEqual(store.planner.tasks.count, 2)
            // Changing policy is a user edit; automatic copies do not replace that undo entry.
            store.undo()
            XCTAssertEqual(store.prefs.carryMode, .ask)
            store.advanceLifecycle()
            XCTAssertTrue(store.canRedo)
        }
    }

    @MainActor func testFakeRemindersUseBackgroundGatewayWithoutClearingRedo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlannerStore(file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
        let id = try XCTUnwrap(
            store.send(.addTasks(["Original"], day: nil, literal: true, agentID: nil))?.tasks.first?.id)
        store.updatePrefs { $0.remindersSync = true }
        store.send(.rename(id, "Changed")); store.undo()
        let source = FakeReminders(), ledger = TestReminderLedger()
        ledger.ledger.enabled = true
        let sync = RemindersSync(store: store, source: source, storage: ledger, observing: false)
        let granted = await sync.requestAccess(); XCTAssertTrue(granted)
        await sync.reconcileNow()
        source.completeFirst()
        await sync.reconcileNow()
        XCTAssertTrue(store.canRedo)
        XCTAssertNil(store.planner.tasks[0].reminderLink)
        XCTAssertNotNil(ledger.ledger.links[id]?.remoteID)
        XCTAssertTrue(store.planner.tasks[0].done)
        store.redo()
        XCTAssertEqual(store.planner.tasks[0].title, "Changed")
        XCTAssertTrue(store.planner.tasks[0].done)
    }

    func testCalendarAndClipboardCanBeFakedWithoutSystemState() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = PlannerStore(
                file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
            let calendar = CalendarService(store: store, source: FakeCalendar())
            XCTAssertFalse(calendar.hasAccess)
            XCTAssertTrue(calendar.events.isEmpty)
            let pasteboard = FakePasteboard()
            let clips = ClipsService(store: store, pasteboard: pasteboard, monitoring: false)
            clips.add(.text("Synthetic copy"), source: "copied")
            clips.copy(clips.clips[0])
            XCTAssertEqual(pasteboard.plainText, "Synthetic copy")
            XCTAssertEqual(pasteboard.changeCount, 1)
        }
    }

    func testNotificationsCanBeFakedWithoutPermissionPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (service, source) = await MainActor.run {
            let store = PlannerStore(
                file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
            let source = FakeNotifications()
            return (ReminderService(store: store, source: source, observing: false), source)
        }
        await service.requestAuthorization()
        await MainActor.run {
            service.notify(id: "synthetic", title: "Test", body: "Body")
            XCTAssertTrue(service.notificationsAllowed)
            XCTAssertEqual(source.messages, ["synthetic"])
        }
    }
    func testVisibleFutureWeekMaterializesItsNewLastDayOnRollover() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var now = Date(timeIntervalSince1970: 1_800_000_000)
            let store = PlannerStore(
                file: PlannerFile(url: root.appendingPathComponent("planner.json")), now: { now }, watching: false)
            store.beginApplication()
            let id = try XCTUnwrap(
                store.send(.addTasks(["Daily fixture"], day: nil, literal: true, agentID: nil))?.tasks.first?.id)
            var edit = TaskEdit(); edit.repeatRule = "daily"
            store.send(.update(id, edit))
            store.materializeRepeats(on: (7..<14).map { store.today.adding(days: $0) })
            let last = store.today.adding(days: 14)
            XCTAssertFalse(store.planner.tasks.contains { $0.day == last })
            now += 86_400
            store.advanceLifecycle()
            XCTAssertEqual(store.planner.tasks.filter { $0.day == last }.count, 1)
        }
    }

}
