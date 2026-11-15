import AppKit
import PlannerCore
import SwiftUI

/// The current notch controls, ready for the remaining presentation preferences.
struct SettingsNotchPane: View {
    @EnvironmentObject var store: PlannerStore

    var body: some View {
        SettingsSection("Around the notch") {
            SettingsRow(
                "Open the notch on",
                help: "Hover keeps your click choice. Double-click opens only after two clicks."
            ) {
                Picker("Open the notch on", selection: SettingsView.openingPreference(store: store)) {
                    Text("Hover").tag(NotchOpenTrigger.hover)
                    Text("Click").tag(NotchOpenTrigger.click)
                    Text("Double-click").tag(NotchOpenTrigger.doubleClick)
                }.labelsHidden()
            }
            SettingsRow(
                "Show today's unfinished task count",
                help: "Off by default. Shows a count only, never task titles. Timers and reminders take priority."
            ) {
                PerchSwitch(title: AppL10n.text("Show today's unfinished task count"), isOn: pref(\.notchTaskCount))
                    .accessibilityIdentifier("settings.notchTaskCount")
            }
            Text(
                "Screen sharing is not detected automatically. Turn this off, or choose Hide task count in the Perch menu, before sharing. If the menu action cannot save, it hides the count for this session only."
            )
            .perchFont(.detail)
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
        SettingsSection("Pill details") {
            SettingsRow("Time beside the notch") {
                Picker("Time beside the notch", selection: pref(\.notchTimerPlacement)) {
                    Text("Right of the notch").tag(NotchTimerPlacement.right)
                    Text("Left of the notch").tag(NotchTimerPlacement.left)
                    Text("Hidden").tag(NotchTimerPlacement.hidden)
                }.labelsHidden()
            }
        }
        SettingsSection("Displays") {
            SettingsRow("Show Perch on", help: "Choose Automatic to follow the pointer between displays.") {
                Picker(
                    "Show Perch on",
                    selection: Binding(
                        get: { store.prefs.showOnDisplay ?? "" },
                        set: { value in store.updatePrefs { $0.showOnDisplay = value.isEmpty ? nil : value } })
                ) {
                    Text("Automatic").tag("")
                    Text("Built-in display").tag("builtIn")
                    ForEach(NSScreen.screens.filter { !$0.isBuiltIn }, id: \.displayID) { screen in
                        Text(screen.localizedName).tag(screen.localizedName)
                    }
                }.labelsHidden()
            }
        }
    }

    private func pref<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        settingsPreference(keyPath, store: store)
    }
}

extension SettingsView {
    /// Bridge the legacy picker at its UI boundary; hover keeps the independent click choice.
    static func openingPreference(store: PlannerStore) -> Binding<NotchOpenTrigger> {
        Binding(
            get: { store.prefs.notchOpenTrigger },
            set: { choice in
                store.updatePrefs {
                    $0.notchOpenTrigger = choice
                    switch choice {
                    case .click: $0.notchClickToOpen = true
                    case .doubleClick: $0.notchClickToOpen = false
                    default: break
                    }
                }
            })
    }
}
