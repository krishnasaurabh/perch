import Foundation
import PerchUI
import PerchReminders
import PlannerCore
import XCTest
@testable import PerchApp

@MainActor
private final class CalendarSettingsAccess: PermissionAccess {
    var states: [PermissionFeature: PermissionReading] = [:]
    var requests: [PermissionFeature] = []
    var grants = true
    func read(_ feature: PermissionFeature) async -> PermissionReading {
        states[feature] ?? PermissionReading(.notDetermined)
    }
    func request(_ feature: PermissionFeature) async throws {
        requests.append(feature)
        states[feature] = PermissionReading(grants ? .allowed : .denied)
    }
}

private final class CalendarConsentScheduledAction: AppScheduledAction {
    func cancel() {}
}

@MainActor
private final class CalendarConsentScheduler: AppScheduling {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any AppScheduledAction {
        CalendarConsentScheduledAction()
    }
}

final class CalendarSettingsModelTests: XCTestCase {
    @MainActor
    private func fixture() -> (PlannerStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = PlannerFile(
            url: root.appendingPathComponent("planner.json"), preferences: MemoryPlannerPreferences())
        return (PlannerStore(file: file, watching: false), root)
    }

    @MainActor
    func testMeetingSwitchRequestsOnlyOnEnableAndReloads() async throws {
        let (store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let access = CalendarSettingsAccess()
        let permissions = PermissionPanelModel(access: access)
        var refreshes = 0
        let model = CalendarSettingsModel(store: store, permissions: permissions, refreshCalendar: { refreshes += 1 })
        await model.setShowMeetings(false)
        XCTAssertEqual(access.requests, [])
        XCTAssertFalse(try store.file.load().preferences.showCalendarMeetings)
        await model.setShowMeetings(true)
        XCTAssertEqual(access.requests, [.calendar])
        XCTAssertTrue(try store.file.load().preferences.showCalendarMeetings)
        XCTAssertEqual(refreshes, 2)
    }

    @MainActor
    func testDeniedCalendarNeverTurnsOnAndOffersRecovery() async throws {
        let (store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.updatePrefs { $0.showCalendarMeetings = false }
        let access = CalendarSettingsAccess()
        access.grants = false
        let permissions = PermissionPanelModel(access: access)
        let model = CalendarSettingsModel(store: store, permissions: permissions)
        await model.setShowMeetings(true)
        XCTAssertFalse(try store.file.load().preferences.showCalendarMeetings)
        XCTAssertEqual(permissions.readings[.calendar]?.state, .denied)
        XCTAssertTrue(model.showsPermission(.calendar))
        await model.setShowMeetings(true)
        XCTAssertEqual(access.requests, [.calendar], "Denied access is recovered in System Settings, not re-prompted.")
    }

    @MainActor
    func testCalendarPickerPreservesUnknownIDsAndCountsVisibleChoices() async throws {
        let (store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.updatePrefs { $0.hiddenCalendarIDs = ["absent-account", "work"] }
        var refreshes = 0
        let model = CalendarSettingsModel(
            store: store, permissions: PermissionPanelModel(access: CalendarSettingsAccess()),
            refreshCalendar: { refreshes += 1 })
        let choices = [CalendarSettingsChoice(id: "work", title: "Work"), .init(id: "home", title: "Home")]
        XCTAssertEqual(model.calendarCount(choices), "1 of 2")
        model.setCalendarVisible("work", visible: true)
        XCTAssertEqual(try store.file.load().preferences.hiddenCalendarIDs, ["absent-account"])
        XCTAssertEqual(model.calendarCount(choices), "2 of 2")
        model.setCalendarVisible("home", visible: false)
        model.setCalendarVisible("home", visible: false)
        XCTAssertEqual(try store.file.load().preferences.hiddenCalendarIDs, ["absent-account", "home"])
        XCTAssertEqual(refreshes, 3)
    }

    @MainActor
    func testNotificationEnableIsPermissionGatedAndRefreshesImmediately() async throws {
        let (store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let access = CalendarSettingsAccess()
        var refreshes = 0
        let model = CalendarSettingsModel(
            store: store, permissions: PermissionPanelModel(access: access), refreshReminders: { refreshes += 1 })
        await model.setNotifyWhenClosed(false)
        await model.setNotifyWhenClosed(true)
        XCTAssertEqual(access.requests, [.notifications])
        XCTAssertEqual(refreshes, 2)
        XCTAssertTrue(try store.file.load().preferences.notifyWhenClosed)
        await model.setNotifyWhenClosed(false)
        access.states[.notifications] = PermissionReading(.denied)
        await model.setNotifyWhenClosed(true)
        XCTAssertFalse(try store.file.load().preferences.notifyWhenClosed)
    }

    @MainActor
    func testRemainingReminderControlsUseTypedActionsAndReload() async throws {
        let (store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CalendarSettingsModel(
            store: store, permissions: PermissionPanelModel(access: CalendarSettingsAccess()))
        model.setMeetingHeadsUp(.tenMinutes)
        model.setPersistentReminders(false)
        model.setSnoozeDuration(.fifteenMinutes)
        let saved = try store.file.load().preferences
        XCTAssertEqual(saved.meetingHeadsUp, .tenMinutes)
        XCTAssertFalse(saved.persistentReminders)
        XCTAssertEqual(saved.snoozeMinutes, .fifteenMinutes)
    }

    @MainActor
    func testMirroringNeedsPermissionAndExplicitLedgerConsent() async throws {
        let (store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let access = CalendarSettingsAccess()
        var consents = 0
        var refreshes = 0
        let model = CalendarSettingsModel(
            store: store, permissions: PermissionPanelModel(access: access),
            enableMirroring: {
                consents += 1; return true
            }, refreshMirroring: { refreshes += 1 })
        await model.setMirroring(true)
        XCTAssertEqual(access.requests, [.reminders])
        XCTAssertEqual(consents, 1)
        XCTAssertTrue(try store.file.load().preferences.remindersSync)
        await model.setMirroring(false)
        XCTAssertFalse(try store.file.load().preferences.remindersSync)
        XCTAssertEqual(consents, 1)
        XCTAssertEqual(refreshes, 2)
    }

    @MainActor
    func testMirroringFailureDoesNotStoreEnablement() async throws {
        let (store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CalendarSettingsModel(
            store: store, permissions: PermissionPanelModel(access: CalendarSettingsAccess()),
            enableMirroring: { false })
        await model.setMirroring(true)
        XCTAssertFalse(try store.file.load().preferences.remindersSync)
    }

    @MainActor
    func testPermissionRevocationIsReflectedWithoutAnotherToggle() async throws {
        let (store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let access = CalendarSettingsAccess()
        access.states[.calendar] = PermissionReading(.allowed)
        let permissions = PermissionPanelModel(access: access)
        let model = CalendarSettingsModel(store: store, permissions: permissions)
        await permissions.refresh()
        XCTAssertFalse(model.showsPermission(.calendar))
        access.states[.calendar] = PermissionReading(.denied)
        await permissions.refresh()
        XCTAssertEqual(permissions.readings[.calendar]?.state, .revoked)
        XCTAssertTrue(model.showsPermission(.calendar))
        XCTAssertTrue(access.requests.isEmpty)
    }

    @MainActor
    func testExistingPhoneConsentIsShownWithoutEnablingItAgain() async throws {
        let (store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var changes = 0
        let model = CalendarSettingsModel(
            store: store, permissions: PermissionPanelModel(access: CalendarSettingsAccess()),
            setTwoWay: { _ in
                changes += 1; return true
            })
        model.reflectExistingPhoneConsent(true)
        XCTAssertEqual(try store.file.load().preferences.phoneEdits, .bringBack)
        model.reflectExistingPhoneConsent(false)
        XCTAssertEqual(try store.file.load().preferences.phoneEdits, .ignore)
        XCTAssertEqual(changes, 0)
    }

    @MainActor
    func testPhoneConsentSurvivesWorkspaceUndoAndExplicitMirroringResume() async throws {
        let (store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FakeReminders(), ledger = TestReminderLedger()
        let sync = RemindersSync(
            store: store, source: source, storage: ledger, scheduler: CalendarConsentScheduler())
        let model = CalendarSettingsModel(
            store: store, permissions: PermissionPanelModel(access: CalendarSettingsAccess()),
            enableMirroring: { await sync.requestAccess() },
            setTwoWay: {
                sync.setTwoWayEnabled($0)
                return sync.lastError == nil
            }, readPhoneConsent: { await sync.refreshTwoWayConsent() })
        await model.setMirroring(true)
        model.setPhoneEdits(.bringBack)
        XCTAssertTrue(ledger.ledger.twoWayEnabled)
        XCTAssertEqual(store.prefs.phoneEdits, .bringBack)

        store.undo()
        await model.refreshPhoneConsent()
        XCTAssertFalse(store.prefs.remindersSync, "Undo skips the non-undoable phone consent cache.")
        XCTAssertTrue(store.canRedo, "Reflecting consent must not clear Redo.")
        XCTAssertFalse(ledger.ledger.enabled, "History traversal still pauses mirroring.")
        XCTAssertTrue(ledger.ledger.twoWayEnabled, "Undo cannot revoke explicit consent.")
        XCTAssertEqual(try store.file.load().preferences.phoneEdits, .bringBack)
        await sync.reconcileNow()
        XCTAssertEqual(source.fetches, 0, "Consent reflection cannot resume paused sync.")

        await model.setMirroring(true)
        await model.refreshPhoneConsent()
        XCTAssertTrue(ledger.ledger.enabled)
        XCTAssertTrue(ledger.ledger.twoWayEnabled)
        XCTAssertTrue(sync.twoWayEnabled)
        XCTAssertEqual(try store.file.load().preferences.phoneEdits, .bringBack)
    }

    @MainActor
    func testPhoneConsentChangesAndReflectionsPreserveUnrelatedUndoAndRedo() async throws {
        let (store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls: [Bool] = []
        let model = CalendarSettingsModel(
            store: store, permissions: PermissionPanelModel(access: CalendarSettingsAccess()),
            setTwoWay: {
                calls.append($0); return true
            })
        model.reflectExistingPhoneConsent(true)
        XCTAssertFalse(store.canUndo, "Pane entry does not create an Undo item.")
        model.setPhoneEdits(.ignore)
        XCTAssertFalse(store.canUndo, "Changing consent does not create a planner-only inverse.")
        let task = try XCTUnwrap(store.addTasks(["Synthetic task"], literal: true)?.first)
        model.setPhoneEdits(.bringBack)
        store.undo()
        XCTAssertFalse(store.planner.tasks.contains { $0.id == task.id })
        XCTAssertEqual(store.prefs.phoneEdits, .bringBack)
        XCTAssertTrue(store.canRedo)
        model.reflectExistingPhoneConsent(false)
        XCTAssertTrue(store.canRedo, "An external consent reflection preserves the task's Redo.")
        store.redo()
        XCTAssertTrue(store.planner.tasks.contains { $0.id == task.id })
        XCTAssertEqual(try store.file.load().preferences.phoneEdits, .ignore)
        XCTAssertEqual(calls, [false, true], "History and reflection never change the ledger.")
    }

    @MainActor
    func testExternalLedgerChangesRefreshPhoneModeWithoutWritingConsent() async throws {
        let (store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FakeReminders(), ledger = TestReminderLedger()
        let sync = RemindersSync(store: store, source: source, storage: ledger, observing: false)
        var consentWrites = 0
        let model = CalendarSettingsModel(
            store: store, permissions: PermissionPanelModel(access: CalendarSettingsAccess()),
            setTwoWay: { _ in
                consentWrites += 1; return true
            },
            readPhoneConsent: { await sync.refreshTwoWayConsent() })
        ledger.ledger.twoWayEnabled = true
        let externalOptIn = ledger.ledger
        await model.refreshPhoneConsent()
        XCTAssertTrue(sync.twoWayEnabled)
        XCTAssertEqual(try store.file.load().preferences.phoneEdits, .bringBack)
        XCTAssertEqual(ledger.ledger, externalOptIn)
        ledger.ledger.twoWayEnabled = false
        let externalOptOut = ledger.ledger
        await model.refreshPhoneConsent()
        XCTAssertFalse(sync.twoWayEnabled)
        XCTAssertEqual(try store.file.load().preferences.phoneEdits, .ignore)
        XCTAssertEqual(ledger.ledger, externalOptOut)
        XCTAssertFalse(store.canUndo)
        XCTAssertEqual(consentWrites, 0)
        XCTAssertEqual(source.fetches, 0)
        XCTAssertEqual(source.saves, 0)
    }

    @MainActor
    func testPhoneConsentRefreshWaitsForSuspendedSyncLedgerLock() async throws {
        let (store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.updatePrefs { $0.remindersSync = true }
        _ = try XCTUnwrap(store.addTasks(["Synthetic linked task"], literal: true)?.first)
        let source = FakeReminders()
        let ledger = ReminderLedgerFile(url: root.appendingPathComponent("reminders.json"))
        let reconciler = ReminderReconciler(repository: source, storage: ledger)
        try reconciler.enable()
        let sync = RemindersSync(
            store: store, source: source, storage: ledger, scheduler: CalendarConsentScheduler(), observing: false)
        // A different adapter changes consent after this service took its initial snapshot.
        try reconciler.setTwoWayEnabled(true)
        let model = CalendarSettingsModel(
            store: store, permissions: PermissionPanelModel(access: CalendarSettingsAccess()),
            readPhoneConsent: { await sync.refreshTwoWayConsent() })
        let fetching = AsyncStream<Void>.makeStream()
        var releaseFetch: CheckedContinuation<Void, Never>?
        source.onFetch = {
            fetching.continuation.yield(())
            await withCheckedContinuation { releaseFetch = $0 }
        }
        let pass = Task { await sync.reconcileNow() }
        for await _ in fetching.stream { break }
        let refreshing = AsyncStream<Void>.makeStream()
        var finished = false
        let refresh = Task {
            refreshing.continuation.yield(())
            await model.refreshPhoneConsent()
            finished = true
        }
        for await _ in refreshing.stream { break }
        XCTAssertFalse(finished, "Refresh waits for the in-flight pass instead of dropping a busy-ledger read.")
        XCTAssertNil(sync.lastError, "Ordinary lock ownership is not an access failure.")
        releaseFetch?.resume()
        await pass.value
        await refresh.value
        XCTAssertTrue(finished)
        XCTAssertTrue(sync.twoWayEnabled)
        XCTAssertEqual(try store.file.load().preferences.phoneEdits, .bringBack)
        XCTAssertTrue(try reconciler.twoWayEnabled())
        XCTAssertNil(sync.lastError)
    }

    @MainActor
    func testPhoneEditsMapsBothWaysAndDoesNotCommitFailedOptIn() async throws {
        let (store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls: [Bool] = []
        var succeeds = true
        let model = CalendarSettingsModel(
            store: store, permissions: PermissionPanelModel(access: CalendarSettingsAccess()),
            setTwoWay: {
                calls.append($0); return succeeds
            })
        model.setPhoneEdits(.bringBack)
        XCTAssertEqual(calls, [true])
        XCTAssertEqual(try store.file.load().preferences.phoneEdits, .bringBack)
        model.setPhoneEdits(.ignore)
        XCTAssertEqual(calls, [true, false])
        XCTAssertEqual(try store.file.load().preferences.phoneEdits, .ignore)
        succeeds = false
        model.setPhoneEdits(.bringBack)
        XCTAssertEqual(try store.file.load().preferences.phoneEdits, .ignore)
    }
}
