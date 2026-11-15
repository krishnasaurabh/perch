import AppKit
import Combine
import PerchUI
import PlannerCore
import ServiceManagement
import SwiftUI

/// The day and block preferences share the same persistent command path as the planner.
struct SettingsGeneralPane: View {
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var services: Services
    @ObservedObject var feedback: SettingsFailureFeedback
    @State private var choosingHour = false
    @State private var loginNeedsApproval = false
    @State private var showingMoreOptions = false

    var body: some View {
        SettingsSection("Opening") {
            SettingsRow("Hovering over the notch shows") {
                PerchSegmented(
                    title: AppL10n.text("Hovering over the notch shows"),
                    items: [
                        (.nothing, AppL10n.text("Nothing")),
                        (.hover, AppL10n.text("A peek")),
                        (.everything, AppL10n.text("Everything")),
                    ],
                    selection: Binding(
                        get: { Self.hoverChoice(store.prefs.notchOpenTrigger) },
                        set: { value in store.apply { try $0.updatePreference(.notchOpenTrigger(value)) } }))
            }
            ShortcutPreferenceRow(store: store)
            SettingsRow("Open Perch when you log in") {
                HStack(spacing: SurfaceMetrics.gap) {
                    if loginNeedsApproval {
                        PerchButton("Open Login Items", kind: .quiet, size: .small) {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                    PerchSwitch(
                        title: AppL10n.text("Open Perch when you log in"),
                        isOn: Binding(
                            get: { store.prefs.launchAtLogin },
                            set: {
                                Self.setLoginItem($0, store: store, feedback: feedback)
                                loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
                            }))
                }
                .onAppear { loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
                }
            }
        }
        SettingsSection("Your day") {
            SettingsRow("A new day starts at") {
                PerchButton(SettingsView.hourLabel(store.prefs.resetHour), kind: .soft, size: .small) {
                    choosingHour = true
                }
                .accessibilityLabel("A new day starts at")
                .accessibilityValue(SettingsView.hourLabel(store.prefs.resetHour))
                .help(
                    "Up to this hour, Perch still counts it as the previous day, so a late night stays on today's list."
                )
                .popover(isPresented: $choosingHour) {
                    VStack(spacing: SettingsMetrics.sectionGap) {
                        Picker(
                            "A new day starts at",
                            selection: preference(\.resetHour, update: PreferenceUpdate.resetHour)
                        ) {
                            ForEach(0..<24) { hour in
                                Text(SettingsView.hourLabel(hour)).tag(hour)
                            }
                        }
                        .pickerStyle(.menu)
                        .perchFont(.body)
                        PerchButton("Done", kind: .soft, size: .small) { choosingHour = false }
                    }
                    .padding(Theme.Size.cardPadding.value)
                    .background(Theme.paper)
                }
            }
            SettingsRow("Tasks left from yesterday") {
                PerchSegmented(
                    title: AppL10n.text("Tasks left from yesterday"),
                    items: [
                        (CarryMode.ask, AppL10n.text("Ask me")),
                        (CarryMode.auto, AppL10n.text("Carry over")),
                        (CarryMode.never, AppL10n.text("Leave them")),
                    ], selection: pref(\.carryMode))
            }
            SettingsRow("Time to set aside by default") {
                HStack(spacing: SurfaceMetrics.gap) {
                    Self.defaultLengthControl(store: store)
                    Text(Self.durationUnit(for: store.prefs.defaultFocusMinutes))
                        .perchFont(.detail).foregroundStyle(Theme.ink2)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Time to set aside by default")
                .accessibilityValue(AppL10n.format("%lld min", store.prefs.defaultFocusMinutes))
                .help("Tasks with their own time budget use that instead.")
            }
        }
        SettingsSection("During a block") {
            SettingsRow("Heads-up before it ends") {
                PerchSegmented(
                    title: AppL10n.text("Heads-up before it ends"),
                    items: [
                        (.off, AppL10n.text("Off")),
                        (.fiveMinutes, AppL10n.text("5 min")),
                        (.tenMinutes, AppL10n.text("10 min")),
                    ], selection: preference(\.blockHeadsUp, update: PreferenceUpdate.blockHeadsUp))
            }
            SettingsRow("When a block ends") {
                PerchSegmented(
                    title: AppL10n.text("When a block ends"),
                    items: [
                        (.ask, AppL10n.text("Ask me")),
                        (.takeBreak, AppL10n.text("Take a break")),
                        (.doNothing, AppL10n.text("Do nothing")),
                    ], selection: preference(\.blockEndAction, update: PreferenceUpdate.blockEndAction))
            }
            SettingsRow("Play a chime when it ends") {
                PerchSwitch(
                    title: AppL10n.text("Play a chime when it ends"),
                    isOn: preference(\.focusCompletionSound, update: PreferenceUpdate.focusCompletionSound))
            }
        }
        // Preserve the existing optional workspace and language controls below the primary rows.
        PerchButton(kind: .quiet, size: .small, action: { showingMoreOptions.toggle() }) {
            Label {
                Text("More options")
            } icon: {
                if showingMoreOptions {
                    Image(systemName: "chevron.down")
                } else {
                    Image(systemName: "chevron.right")
                }
            }
        }
        .accessibilityIdentifier("settings.general.more")
        .accessibilityValue(showingMoreOptions ? AppL10n.text("Expanded") : AppL10n.text("Collapsed"))
        if showingMoreOptions {
            additionalOptions
        }
    }

    static func connect(store: PlannerStore) -> AnyCancellable {
        let shortcut = ShortcutPreferenceSync.connect(store: store)
        let login = LoginItemPreferenceSync.connect(store: store)
        return AnyCancellable {
            shortcut.cancel(); login.cancel()
        }
    }

    #if DEBUG || PERCH_TESTING
        static func previewAlternatives(app: AppDelegate) {
            app.store.apply { commands in
                try commands.updatePreference(.notchOpenTrigger(.everything))
                try commands.updatePreference(.launchAtLogin(false))
                try commands.updatePreference(.resetHour(0))
                try commands.updatePreference(.carryMode(.ask))
                try commands.updatePreference(.defaultFocusMinutes(25))
                try commands.updatePreference(.blockHeadsUp(.off))
                try commands.updatePreference(.blockEndAction(.takeBreak))
                try commands.updatePreference(.focusCompletionSound(true))
            }
            SettingsWindow.preview(.general, app: app)
        }
    #endif

    private func pref(_ key: KeyPath<Preferences, CarryMode>) -> Binding<CarryMode> {
        preference(key, update: PreferenceUpdate.carryMode)
    }

    private func preference<Value>(
        _ key: KeyPath<Preferences, Value>, update: @escaping (Value) -> PreferenceUpdate
    ) -> Binding<Value> {
        Self.preference(key, update: update, store: store)
    }

    static func preference<Value>(
        _ key: KeyPath<Preferences, Value>, update: @escaping (Value) -> PreferenceUpdate, store: PlannerStore
    ) -> Binding<Value> {
        Binding(
            get: { store.prefs[keyPath: key] },
            set: { value in store.apply { try $0.updatePreference(update(value)) } })
    }

    static func defaultLengthControl(store: PlannerStore) -> some View {
        PerchSegmented(
            title: AppL10n.text("Time to set aside by default"),
            items: [15, 25, 45, 60].map { ($0, String($0)) },
            selection: preference(\.defaultFocusMinutes, update: PreferenceUpdate.defaultFocusMinutes, store: store))
    }

    /// Keep a saved custom length visible without changing it to a preset just by opening Settings.
    static func durationUnit(for minutes: Int) -> String {
        [15, 25, 45, 60].contains(minutes) ? AppL10n.text("min") : AppL10n.format("%lld min", minutes)
    }

    /// Legacy click choices meant no hover, and remain untouched until the person picks a new value.
    static func hoverChoice(_ stored: NotchOpenTrigger) -> NotchOpenTrigger {
        switch stored {
        case .click, .doubleClick: .nothing
        default: stored
        }
    }

    static func setLoginItem(
        _ enabled: Bool, store: PlannerStore, feedback: SettingsFailureFeedback,
        current: @escaping () -> Bool = { LoginItemPreferenceSync.accepted },
        change: @escaping (Bool) throws -> Void = { enabled in
            enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        }
    ) {
        feedback.perform(store: store, failure: { .loginItem($0.perchPresentationDetail) }) {
            let previous = current()
            if previous != enabled { try change(enabled) }
            // Persist only after macOS accepts the request; roll back the service on a storage failure.
            if store.apply({ try $0.updatePreference(.launchAtLogin(enabled)) }) == nil {
                let error = store.lastError ?? PerchAppError.loginItem(AppL10n.text("Action failed. Please try again."))
                if previous != enabled { try change(previous) }
                throw error
            }
        }
    }

    @ViewBuilder private var additionalOptions: some View {
        SettingsSection("Time display") {
            SettingsRow("Time display") {
                Picker(
                    "Time display",
                    selection: preference(\.workspaceTimerStyle, update: PreferenceUpdate.workspaceTimerStyle)
                ) {
                    Text("Digital").tag(WorkspaceTimerStyle.digital)
                    Text("Minimal").tag(WorkspaceTimerStyle.minimal)
                    Text("Dot grid").tag(WorkspaceTimerStyle.dotMatrix)
                }.labelsHidden()
            }
        }
        Card(.paper) { SettingsView.language }
        SettingsSection("Apple Intelligence") {
            SettingsRow("Auto-sort new tasks", help: SettingsView.appleIntelligenceHelp) {
                PerchSwitch(
                    title: AppL10n.text("Auto-sort new tasks"),
                    isOn: preference(\.sortWithAI, update: PreferenceUpdate.sortWithAI)
                )
                .disabled(!AISorter.isSupported)
            }
        }
        SettingsSection("Your week") {
            SettingsRow("Count Saturday and Sunday toward the streak") {
                PerchSwitch(
                    title: AppL10n.text("Count Saturday and Sunday toward the streak"),
                    isOn: preference(\.includeWeekendsInStreak, update: PreferenceUpdate.includeWeekendsInStreak))
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

    private func moveCard(_ id: String, _ delta: Int) {
        store.updatePrefs { p in
            var order = HomeLayout.ordered(p.workspaceCardOrder)
            guard let i = order.firstIndex(of: id), order.indices.contains(i + delta) else { return }
            order.swapAt(i, i + delta)
            p.workspaceCardOrder = order
        }
    }
}

/// Applies launch-at-login on ordinary app launches and on preference changes, including Undo.
/// Synthetic preview launches never register a real login item.
@MainActor
final class LoginItemPreferenceSync {
    private var observation: AnyCancellable?

    static var accepted: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static func connect(store: PlannerStore) -> AnyCancellable {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return AnyCancellable {} }
        #if DEBUG || PERCH_TESTING
            guard ProcessInfo.processInfo.environment["PERCH_DATA"] == nil else { return AnyCancellable {} }
        #endif
        let sync = LoginItemPreferenceSync(store: store)
        return AnyCancellable { withExtendedLifetime(sync) {} }
    }

    init(
        store: PlannerStore,
        current: @escaping () -> Bool = { LoginItemPreferenceSync.accepted },
        change: @escaping (Bool) throws -> Void = { enabled in
            enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        }
    ) {
        let apply: (Bool) -> Void = { [weak store] desired in
            guard let store, current() != desired else { return }
            do { try change(desired) } catch { store.lastError = .loginItem(error.perchPresentationDetail) }
        }
        observation = store.$planner.map(\.preferences.launchAtLogin).removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak store] _ in
                if let store { apply(store.prefs.launchAtLogin) }
            }
        apply(store.prefs.launchAtLogin)
    }
}
