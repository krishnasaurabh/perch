import Foundation
import XCTest
@testable import PerchApp

@MainActor
private final class CoreTypesScheduler: AppScheduling {
    final class Token: AppScheduledAction {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }
    var jobs: [(Token, @MainActor () -> Void)] = []
    var tokens: [Token] { jobs.map(\.0) }
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any AppScheduledAction {
        let token = Token()
        jobs.append((token, action))
        return token
    }
    func fireAll() {
        let current = jobs
        jobs = []
        for (token, action) in current where !token.cancelled { action() }
    }
}

final class CoreTypesTests: XCTestCase {
    func testEnumMetadataIsExhaustiveAndStable() {
        XCTAssertEqual(NotchPage.allCases.map(\.title), ["Today", "Week", "Clips", "Insights"])
        XCTAssertEqual(NotchPage.allCases.map(\.symbol), ["sun.max", "calendar", "paperclip", "chart.bar"])
        XCTAssertEqual(AgentConnector.App.allCases.map(\.name), ["Claude Code", "Claude app", "Cursor"])
        XCTAssertEqual(
            SettingsView.Pane.allCases.map(\.symbol),
            ["gearshape", "rectangle.3.group", "timer", "sparkles", "lock.shield"])
    }

    func testKnownErrorsKeepAdapterSpecificPresentation() {
        XCTAssertEqual(PerchAppError.planner("Storage unavailable").message, "Storage unavailable")
        XCTAssertEqual(PerchAppError.reminderScheduling("Denied").message, "Reminder scheduling failed: Denied")
        XCTAssertEqual(
            PerchAppError.loginItem("Denied").message, "Perch couldn't update the login item: Denied")
        XCTAssertEqual(PerchAppError.aiSorting("Unavailable").message, "AI sorting failed: Unavailable")
        XCTAssertEqual(
            PerchAppError.remindersPermission.message,
            "Perch has no Reminders permission. Grant it under System Settings › Privacy & Security › Reminders.")
        XCTAssertEqual(
            ReminderServiceError.authorization("Denied").message, "Notification permission failed: Denied")
        XCTAssertEqual(
            ReminderServiceError.scheduling("Denied").message, "Reminder scheduling failed: Denied")
        XCTAssertEqual(RemindersSyncFailure.consentRequired.message, RemindersSyncFailure.consentMessage)
        XCTAssertEqual(RemindersSyncFailure.historyPaused.message, RemindersSyncFailure.historyMessage)
        XCTAssertEqual(RemindersSyncFailure.access("Denied").message, "Denied")
        XCTAssertEqual(RemindersSyncFailure.sync("Conflict").message, "Reminders sync stopped: Conflict")
        XCTAssertEqual(
            RemindersSyncFailure.disableAfterHistory("Denied").message,
            RemindersSyncFailure.historyMessage + " Denied")
    }

    @MainActor
    func testActivityReplacementAndDismissCancelOwnedWork() {
        let scheduler = CoreTypesScheduler()
        let model = NotchModel(scheduler: scheduler)
        let first = PresentedNotchActivity(kind: .message, title: "First", subtitle: "")
        let second = PresentedNotchActivity(kind: .message, title: "Second", subtitle: "")
        model.show(first, for: 1)
        model.show(second, for: 2)
        XCTAssertEqual(scheduler.jobs.count, 2)
        XCTAssertTrue(scheduler.tokens[0].cancelled)
        XCTAssertFalse(scheduler.tokens[1].cancelled)
        model.dismissActivity()
        XCTAssertTrue(scheduler.tokens[1].cancelled)
        scheduler.fireAll()
        XCTAssertNil(model.activity)
    }

    @MainActor
    func testActivityFiresOnceAndTeardownCancelsPendingWork() {
        let scheduler = CoreTypesScheduler()
        var model: NotchModel? = NotchModel(scheduler: scheduler)
        weak var weakModel = model
        model?.show(PresentedNotchActivity(kind: .message, title: "One", subtitle: ""), for: 1)
        let token = scheduler.tokens[0]
        scheduler.fireAll()
        XCTAssertNil(model?.activity)
        model?.show(PresentedNotchActivity(kind: .message, title: "Two", subtitle: ""), for: 1)
        let pending = scheduler.tokens[0]
        model = nil
        XCTAssertNil(weakModel)
        XCTAssertTrue(pending.cancelled)
        XCTAssertFalse(token.cancelled)
    }
}
