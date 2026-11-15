import PlannerCore
import SwiftUI

struct SettingsNotchPane: View {
    @EnvironmentObject var store: PlannerStore

    private var preferences: SettingsNotchPreferences { SettingsNotchPreferences(store: store) }

    var body: some View {
        SettingsSection("Around the notch") {
            SettingsRow("Progress line under the housing") {
                PerchSwitch(title: "Progress line under the housing", isOn: preferences.progressLine)
                    .accessibilityIdentifier("settings.notchProgressLine")
            }
            SettingsRow("Time pill beside the notch") {
                PerchSwitch(title: "Time pill beside the notch", isOn: preferences.timePill)
                    .accessibilityIdentifier("settings.notchTimePill")
            }
            SettingsRow("Tasks-left pill beside the notch") {
                PerchSwitch(title: "Tasks-left pill beside the notch", isOn: preferences.taskPill)
                    .accessibilityIdentifier("settings.notchTaskCount")
            }
        }
        SettingsSection("Pill details") {
            SettingsRow("Pills sit on the") {
                PerchSegmented(
                    title: "Pills sit on the", items: preferences.sideItems, selection: preferences.pillSide
                )
                .accessibilityIdentifier("settings.notchTimerPlacement")
            }
            SettingsRow("Show the next block in its last 15 minutes") {
                PerchSwitch(title: "Show the next block in its last 15 minutes", isOn: preferences.nextBlock)
                    .accessibilityIdentifier("settings.notchNextBlock")
            }
            SettingsRow("Dot under the housing for a waiting reminder") {
                PerchSwitch(title: "Dot under the housing for a waiting reminder", isOn: preferences.reminderDot)
                    .accessibilityIdentifier("settings.notchReminderDot")
            }
        }
        SettingsSection("Menu bar") {
            SettingsRow("Show Perch in the menu bar as") {
                PerchSegmented(
                    title: "Show Perch in the menu bar as",
                    items: [
                        (MenuBarDisplay.icon, AppL10n.text("Icon")),
                        (MenuBarDisplay.timeLeft, AppL10n.text("Time left")),
                        (MenuBarDisplay.tasksLeft, AppL10n.text("Tasks left")),
                        (MenuBarDisplay.hidden, AppL10n.text("Hidden")),
                    ], selection: preferences.menuBar
                )
                .accessibilityIdentifier("settings.menuBarDisplay")
            }
            SettingsRow("Hide counts and times", help: "Manual switch. Screen sharing is not detected automatically.") {
                PerchSwitch(title: "Hide counts and times", isOn: preferences.privacy)
                    .accessibilityIdentifier("settings.hideCountsAndTimes")
            }
            Text("macOS places the menu bar item itself, so it can never cover another icon.")
                .perchFont(.detail)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: SettingsMetrics.rowHeight, alignment: .leading)
        }
    }
}

#if DEBUG || PERCH_TESTING
    @MainActor
    enum SettingsNotchPreview {
        static func showConfigured(app: AppDelegate) {
            configure(store: app.store)
            SettingsWindow.preview(.notch, app: app)
        }

        static func configure(store: PlannerStore) {
            let preferences = SettingsNotchPreferences(store: store)
            preferences.progressLine.wrappedValue = false
            preferences.timePill.wrappedValue = true
            preferences.taskPill.wrappedValue = true
            preferences.pillSide.wrappedValue = .split
            preferences.nextBlock.wrappedValue = true
            preferences.reminderDot.wrappedValue = false
            preferences.menuBar.wrappedValue = .timeLeft
            preferences.privacy.wrappedValue = false
        }
    }
#endif

/// Bind directly to the published store; every edit uses the typed, locked command path.
@MainActor
struct SettingsNotchPreferences {
    let store: PlannerStore

    var progressLine: Binding<Bool> { binding(\.notchProgressLine, update: PreferenceUpdate.notchProgressLine) }
    var timePill: Binding<Bool> { binding(\.notchTimePill, update: PreferenceUpdate.notchTimePill) }
    var taskPill: Binding<Bool> { binding(\.notchTaskCount, update: PreferenceUpdate.notchTaskCount) }
    var pillSide: Binding<NotchTimerPlacement> {
        binding(\.notchTimerPlacement, update: PreferenceUpdate.notchTimerPlacement)
    }
    var nextBlock: Binding<Bool> { binding(\.notchNextBlock, update: PreferenceUpdate.notchNextBlock) }
    var reminderDot: Binding<Bool> { binding(\.notchReminderDot, update: PreferenceUpdate.notchReminderDot) }
    var menuBar: Binding<MenuBarDisplay> { binding(\.menuBarDisplay, update: PreferenceUpdate.menuBarDisplay) }
    var privacy: Binding<Bool> { binding(\.hideCountsAndTimes, update: PreferenceUpdate.hideCountsAndTimes) }

    var sideItems: [(value: NotchTimerPlacement, label: String)] {
        let choices: [(value: NotchTimerPlacement, label: String)] = [
            (.left, AppL10n.text("Left")), (.right, AppL10n.text("Right")), (.split, AppL10n.text("One each side")),
        ]
        // Keep an older explicit Hidden choice selected until the person changes it.
        return store.prefs.notchTimerPlacement == .hidden ? choices + [(.hidden, AppL10n.text("Hidden"))] : choices
    }

    private func binding<Value>(
        _ keyPath: KeyPath<Preferences, Value>, update: @escaping (Value) -> PreferenceUpdate
    ) -> Binding<Value> {
        Binding(
            get: { store.prefs[keyPath: keyPath] },
            set: { value in store.apply { try $0.updatePreference(update(value)) } })
    }
}
