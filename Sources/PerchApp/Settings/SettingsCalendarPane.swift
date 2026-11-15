import PlannerCore
import SwiftUI

/// Calendar visibility, consent and existing mirroring remain in one pane.
struct SettingsCalendarPane: View {
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var services: Services

    var body: some View {
        SettingsSection("Calendar") {
            if services.calendar.hasAccess {
                for calendar in services.calendar.calendars {
                    SettingsRow(calendar.title) {
                        PerchSwitch(
                            title: calendar.title,
                            isOn: Binding(
                                get: { !store.prefs.hiddenCalendarIDs.contains(calendar.calendarIdentifier) },
                                set: { visible in
                                    store.updatePrefs { p in
                                        if visible {
                                            p.hiddenCalendarIDs.removeAll { $0 == calendar.calendarIdentifier }
                                        } else if !p.hiddenCalendarIDs.contains(calendar.calendarIdentifier) {
                                            p.hiddenCalendarIDs.append(calendar.calendarIdentifier)
                                        }
                                    }
                                    services.calendar.refresh()
                                }))
                    }
                }
            }
            PermissionPanel(services: services, features: [.calendar])
        }
        SettingsSection("Apple Reminders") {
            SettingsRow(
                "Mirror tasks to a Perch list",
                help:
                    "Perch creates a separate Reminders list for today's and upcoming tasks. Standard mirroring imports only today's completion. Experimental two-way sync can also import text, priority, due dates, reopening and deletion for linked tasks. Conflicting edits pause sync rather than choose a winner. Existing reminders and other lists are never adopted. Undo or Redo pauses sync until you turn it off and on again."
            ) {
                PerchSwitch(
                    title: AppL10n.text("Mirror tasks to a Perch list"),
                    isOn: Binding(
                        get: { store.prefs.remindersSync },
                        set: { enabled in
                            Task {
                                if enabled {
                                    guard await services.remindersSync.requestAccess() else {
                                        store.lastError = .remindersPermission
                                        return
                                    }
                                }
                                store.updatePrefs { $0.remindersSync = enabled }
                                services.remindersSync.sync()
                            }
                        }))
            }
            SettingsRow(
                "Alert on iPhone and Apple Watch too",
                help:
                    "Mirroring pauses if access is denied or revoked. Phone and Watch alerts also depend on your Reminders account and device settings."
            ) {
                PerchSwitch(
                    title: AppL10n.text("Alert on iPhone and Apple Watch too"),
                    isOn: settingsPreference(\.ringOnPhone, store: store)
                )
                .disabled(!store.prefs.remindersSync)
            }
            ReminderSyncStatus(sync: services.remindersSync)
        }
        SettingsSection("Permissions") {
            PermissionPanel(services: services, features: [.reminders, .notifications])
        }
    }
}
