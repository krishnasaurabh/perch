import PerchUI
import PlannerCore
import ServiceManagement
import SwiftUI

/// Existing general controls remain usable while this pane is expanded independently.
struct SettingsGeneralPane: View {
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var services: Services
    @ObservedObject var feedback: SettingsFailureFeedback

    var body: some View {
        SettingsSection("Opening") {
            SettingsRow("Open the notch on") {
                Picker("Open the notch on", selection: pref(\.notchOpenTrigger)) {
                    Text("Hover").tag(NotchOpenTrigger.hover)
                    Text("Click").tag(NotchOpenTrigger.click)
                    Text("Double-click").tag(NotchOpenTrigger.doubleClick)
                }.labelsHidden()
            }
            ShortcutPreferenceRow()
                .frame(minHeight: SettingsMetrics.rowHeight)
            SettingsRow("Open Perch when you log in", help: "Works anywhere, even when Perch isn't the front app.") {
                PerchSwitch(
                    title: AppL10n.text("Open Perch when you log in"),
                    isOn: Binding(
                        get: { SMAppService.mainApp.status == .enabled },
                        set: { feedback.updateLoginItem($0, store: store) }))
            }
        }
        SettingsSection("Your day") {
            SettingsRow(
                "A new day starts at",
                help:
                    "Up to this hour, Perch still counts it as the previous day, so a late night stays on today's list."
            ) {
                Stepper(value: pref(\.resetHour), in: 0...6) {
                    Text(SettingsView.hourLabel(store.prefs.resetHour))
                }
                .accessibilityLabel("A new day starts at")
            }
            SettingsRow(
                "Tasks left from yesterday",
                help:
                    "Applies when Today opens and at the day boundary. Previously handled tasks are not restored. You can still move individual tasks yourself."
            ) {
                PerchSegmented(
                    title: AppL10n.text("Tasks left from yesterday"),
                    items: [
                        (CarryMode.ask, AppL10n.text("Ask me")),
                        (CarryMode.auto, AppL10n.text("Carry over")),
                        (CarryMode.never, AppL10n.text("Leave them")),
                    ], selection: pref(\.carryMode))
            }
            SettingsRow("Time to set aside by default", help: "Tasks with their own time budget use that instead.") {
                Stepper(value: pref(\.defaultFocusMinutes), in: 5...180, step: 5) {
                    Text(AppL10n.format("%lld min", store.prefs.defaultFocusMinutes))
                }
                .accessibilityLabel("Time to set aside by default")
            }
        }
        SettingsSection("During a block") {
            SettingsRow("Play a chime when it ends") {
                PerchSwitch(title: AppL10n.text("Play a chime when it ends"), isOn: pref(\.focusCompletionSound))
            }
            SettingsRow("Time display") {
                Picker("Time display", selection: pref(\.workspaceTimerStyle)) {
                    Text("Digital").tag(WorkspaceTimerStyle.digital)
                    Text("Minimal").tag(WorkspaceTimerStyle.minimal)
                    Text("Dot grid").tag(WorkspaceTimerStyle.dotMatrix)
                }.labelsHidden()
            }
        }
        Card(.paper) { SettingsView.language }
        SettingsSection("Apple Intelligence") {
            SettingsRow("Auto-sort new tasks", help: SettingsView.appleIntelligenceHelp) {
                PerchSwitch(title: AppL10n.text("Auto-sort new tasks"), isOn: pref(\.sortWithAI))
                    .disabled(!AISorter.isSupported)
            }
        }
        SettingsSection("Your week") {
            SettingsRow("Count Saturday and Sunday toward the streak") {
                PerchSwitch(
                    title: AppL10n.text("Count Saturday and Sunday toward the streak"),
                    isOn: pref(\.includeWeekendsInStreak))
            }
        }
        SettingsSection("Beside today's tasks") {
            for id in HomeLayout.ordered(store.prefs.workspaceCardOrder) {
                SettingsRow(SettingsView().cardName(id)) {
                    HStack(spacing: SurfaceMetrics.gap) {
                        PerchSwitch(
                            title: SettingsView().cardName(id),
                            isOn: Binding(
                                get: { !store.prefs.hiddenWorkspaceCards.contains(id) },
                                set: { show in
                                    store.updatePrefs { p in
                                        if show {
                                            p.hiddenWorkspaceCards.removeAll { $0 == id }
                                        } else if !p.hiddenWorkspaceCards.contains(id) {
                                            p.hiddenWorkspaceCards.append(id)
                                        }
                                    }
                                }))
                        PerchButton(kind: .quiet, size: .small, action: { moveCard(id, -1) }) {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(HomeLayout.ordered(store.prefs.workspaceCardOrder).first == id)
                        .accessibilityLabel(AppL10n.format("Move %@ up", SettingsView().cardName(id)))
                        PerchButton(kind: .quiet, size: .small, action: { moveCard(id, 1) }) {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(HomeLayout.ordered(store.prefs.workspaceCardOrder).last == id)
                        .accessibilityLabel(AppL10n.format("Move %@ down", SettingsView().cardName(id)))
                    }
                }
            }
            PerchButton("Reset to default", kind: .soft, size: .small) {
                store.updatePrefs {
                    $0.workspaceCardOrder = Preferences().workspaceCardOrder
                    $0.hiddenWorkspaceCards = Preferences().hiddenWorkspaceCards
                }
            }
        }
        SettingsSection("Permissions") {
            PermissionPanel(services: services, features: [.speech, .microphone])
        }
    }

    private func pref<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        settingsPreference(keyPath, store: store)
    }

    private func moveCard(_ id: String, _ delta: Int) {
        store.updatePrefs { p in
            var order = HomeLayout.ordered(p.workspaceCardOrder)
            guard let i = order.firstIndex(of: id), order.indices.contains(i + delta) else { return }
            order.swapAt(i, i + delta)
            p.workspaceCardOrder = order
        }
    }
}
