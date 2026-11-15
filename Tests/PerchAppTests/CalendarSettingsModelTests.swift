import Foundation
import PerchUI
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
