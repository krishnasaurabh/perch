import AppKit
import EventKit
import PerchUI
import PlannerCore
import SwiftUI

struct SettingsCalendarPane: View {
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var services: Services
    #if DEBUG || PERCH_TESTING
        @Environment(\.calendarSettingsPreview) private var preview
    #endif

    var body: some View {
        #if DEBUG || PERCH_TESTING
            if let preview {
                SettingsCalendarContent(
                    store: store, services: services,
                    permissionAccess: CalendarSettingsPreviewAccess(denied: preview == .denied),
                    choices: preview == .denied ? [] : SettingsCalendarPreview.choices)
            } else {
                SettingsCalendarContent(store: store, services: services)
            }
        #else
            SettingsCalendarContent(store: store, services: services)
        #endif
    }
}

private struct SettingsCalendarContent: View {
    @ObservedObject var store: PlannerStore
    @ObservedObject var calendar: CalendarService
    @ObservedObject var sync: RemindersSync
    @StateObject private var model: CalendarSettingsModel
    @StateObject private var permissions: PermissionPanelModel
    @State private var choosingCalendars = false
    @State private var confirmingPhoneEdits = false
    private let suppliedChoices: [CalendarSettingsChoice]?
    private let hasSuppliedAccess: Bool

    init(
        store: PlannerStore, services: Services,
        permissionAccess: (any PermissionAccess)? = nil,
        choices: [CalendarSettingsChoice]? = nil
    ) {
        self.store = store
        calendar = services.calendar
        sync = services.remindersSync
        suppliedChoices = choices
        hasSuppliedAccess = choices != nil
        let permissions = PermissionPanelModel(access: permissionAccess ?? SettingsPermissionAccess(services: services))
        _permissions = StateObject(wrappedValue: permissions)
        _model = StateObject(
            wrappedValue: CalendarSettingsModel(
                store: store, permissions: permissions,
                refreshCalendar: { services.calendar.refresh() },
                enableMirroring: { await services.remindersSync.requestAccess() },
                setTwoWay: { enabled in
                    services.remindersSync.setTwoWayEnabled(enabled)
                    return services.remindersSync.lastError == nil && services.remindersSync.twoWayEnabled == enabled
                },
                refreshReminders: { services.reminders.refreshAuthorization() },
                refreshMirroring: { services.remindersSync.sync() }))
    }

    private var choices: [CalendarSettingsChoice] {
        suppliedChoices ?? calendar.calendars.map { CalendarSettingsChoice(id: $0.calendarIdentifier, title: $0.title) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
            SettingsSection("Calendar") {
                SettingsRow("Show meetings in Your day") {
                    PerchSwitch(
                        title: "Show meetings in Your day",
                        isOn: Binding(
                            get: { store.prefs.showCalendarMeetings },
                            set: { value in Task { await model.setShowMeetings(value) } })
                    )
                    .disabled(model.busy)
                    .accessibilityIdentifier("settings.calendar.meetings")
                }
                SettingsRow("Calendars shown") {
                    HStack(spacing: SurfaceMetrics.compactGap) {
                        PerchPill(model.calendarCount(hasSuppliedAccess || calendar.hasAccess ? choices : []))
                        PerchButton("Change", kind: .quiet, size: .small) {
                            Task { choosingCalendars = await model.openCalendarPicker() }
                        }
                        .disabled(model.busy)
                        .accessibilityLabel("Change calendars shown")
                        .accessibilityIdentifier("settings.calendar.choose")
                        .popover(isPresented: $choosingCalendars) {
                            calendarPicker
                        }
                    }
                }
                SettingsRow("Heads-up before a meeting") {
                    PerchSegmented(
                        title: "Heads-up before a meeting",
                        items: [(.off, "Off"), (.fiveMinutes, "5 min"), (.tenMinutes, "10 min")],
                        selection: Binding(get: { store.prefs.meetingHeadsUp }, set: model.setMeetingHeadsUp))
                }
                if model.showsPermission(.calendar) {
                    PermissionPanel(model: permissions, features: [.calendar])
                }
            }
            SettingsSection("Reminders") {
                SettingsRow("Notify me when Perch is closed") {
                    PerchSwitch(
                        title: "Notify me when Perch is closed",
                        isOn: Binding(
                            get: { store.prefs.notifyWhenClosed },
                            set: { value in Task { await model.setNotifyWhenClosed(value) } })
                    )
                    .disabled(model.busy)
                    .accessibilityIdentifier("settings.calendar.notifications")
                }
                SettingsRow("Keep a reminder up until I answer") {
                    PerchSwitch(
                        title: "Keep a reminder up until I answer",
                        isOn: Binding(get: { store.prefs.persistentReminders }, set: model.setPersistentReminders)
                    )
                    .accessibilityIdentifier("settings.calendar.persistent")
                }
                SettingsRow("\"In a bit\" means") {
                    HStack(spacing: SurfaceMetrics.compactGap) {
                        PerchSegmented(
                            title: "\"In a bit\" means",
                            items: [(.fiveMinutes, "5"), (.tenMinutes, "10"), (.fifteenMinutes, "15")],
                            selection: Binding(get: { store.prefs.snoozeMinutes }, set: model.setSnoozeDuration))
                        Text("min").perchFont(.detail).foregroundStyle(Theme.ink2)
                    }
                }
                if model.showsPermission(.notifications) {
                    PermissionPanel(model: permissions, features: [.notifications])
                }
            }
            SettingsSection("Apple Reminders") {
                SettingsRow("Mirror tasks to a Perch list") {
                    PerchSwitch(
                        title: "Mirror tasks to a Perch list",
                        isOn: Binding(
                            get: { store.prefs.remindersSync },
                            set: { value in Task { await model.setMirroring(value) } })
                    )
                    .disabled(model.busy)
                    .accessibilityIdentifier("settings.calendar.mirroring")
                }
                SettingsRow("Edits made on your phone") {
                    PerchSegmented(
                        title: "Edits made on your phone",
                        items: [(.ignore, "Ignore"), (.bringBack, "Bring back")],
                        selection: Binding(
                            get: { store.prefs.phoneEdits },
                            set: { value in
                                if value == .bringBack && !sync.twoWayEnabled {
                                    confirmingPhoneEdits = true
                                } else {
                                    model.setPhoneEdits(value)
                                }
                            })
                    )
                    .disabled(!store.prefs.remindersSync || model.busy)
                }
                Text(
                    "Mirroring sends tasks to your phone and watch. It only reads changes back if you choose Bring back."
                )
                .perchFont(.detail).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, SettingsMetrics.titleGap)
                if model.showsPermission(.reminders) {
                    PermissionPanel(model: permissions, features: [.reminders])
                }
                if let error = sync.lastError {
                    Text(error.message)
                        .perchFont(.detail).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .task {
            await permissions.refresh()
            model.reflectExistingPhoneConsent(sync.twoWayEnabled)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await permissions.refresh() }
        }
        .alert("Enable two-way sync for the Perch list?", isPresented: $confirmingPhoneEdits) {
            Button("Not now", role: .cancel) {}
            Button("Bring back", role: .destructive) { model.setPhoneEdits(.bringBack) }
        } message: {
            Text(
                "Edits and deletions to linked tasks can change both Perch and its Reminders list. Conflicting edits stop sync."
            )
        }
    }

    private var calendarPicker: some View {
        CalendarSettingsPicker(store: store, model: model, choices: choices) { choosingCalendars = false }
    }
}

private struct CalendarSettingsPicker: View {
    @ObservedObject var store: PlannerStore
    @ObservedObject var model: CalendarSettingsModel
    let choices: [CalendarSettingsChoice]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
            Text("Calendars shown").perchFont(.stripTitle).accessibilityAddTraits(.isHeader)
            if choices.isEmpty {
                Text("No calendars are available.")
                    .perchFont(.detail).foregroundStyle(Theme.ink2)
            } else {
                ScrollView {
                    VStack(spacing: .zero) {
                        ForEach(choices) { choice in
                            SettingsRow(choice.title) {
                                PerchSwitch(
                                    title: choice.title,
                                    isOn: Binding(
                                        get: { !store.prefs.hiddenCalendarIDs.contains(choice.id) },
                                        set: { model.setCalendarVisible(choice.id, visible: $0) }))
                            }
                        }
                    }
                }
                .frame(maxHeight: SettingsMetrics.windowSize.height / 2)
            }
            HStack {
                Spacer()
                PerchButton("Done", kind: .soft, size: .small) { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Size.cardPadding.value)
        .frame(width: SettingsMetrics.windowSize.width - SettingsMetrics.sidebarWidth * 2)
        .background(Theme.paper)
        .onExitCommand { close() }
    }
}

struct CalendarSettingsChoice: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

/// Keeps consent, typed persistence and immediate refreshes on the same user-action path.
@MainActor
final class CalendarSettingsModel: ObservableObject {
    @Published private(set) var busy = false
    private let store: PlannerStore
    let permissions: PermissionPanelModel
    private var attempted: Set<PermissionFeature> = []
    private let refreshCalendar: () -> Void
    private let enableMirroring: () async -> Bool
    private let setTwoWay: (Bool) -> Bool
    private let refreshReminders: () -> Void
    private let refreshMirroring: () -> Void

    init(
        store: PlannerStore, permissions: PermissionPanelModel,
        refreshCalendar: @escaping () -> Void = {}, enableMirroring: @escaping () async -> Bool = { false },
        setTwoWay: @escaping (Bool) -> Bool = { _ in false }, refreshReminders: @escaping () -> Void = {},
        refreshMirroring: @escaping () -> Void = {}
    ) {
        self.store = store
        self.permissions = permissions
        self.refreshCalendar = refreshCalendar
        self.enableMirroring = enableMirroring
        self.setTwoWay = setTwoWay
        self.refreshReminders = refreshReminders
        self.refreshMirroring = refreshMirroring
    }

    @discardableResult
    private func save(_ update: PreferenceUpdate) -> Bool {
        let result: Bool? = store.performMutation(origin: .user) {
            try $0.updatePreference(update)
            return true
        }
        return result == true
    }

    func showsPermission(_ feature: PermissionFeature) -> Bool {
        switch permissions.readings[feature]?.state ?? .checking {
        case .checking, .allowed: false
        case .notDetermined: attempted.contains(feature)
        default: true
        }
    }

    private func allow(_ feature: PermissionFeature) async -> Bool {
        attempted.insert(feature)
        return await permissions.ensureAllowed(feature)
    }

    func setShowMeetings(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if enabled {
            guard await allow(.calendar) else { return }
        }
        if save(.showCalendarMeetings(enabled)) { refreshCalendar() }
    }

    func openCalendarPicker() async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        guard await allow(.calendar) else { return false }
        refreshCalendar()
        return true
    }

    func calendarCount(_ choices: [CalendarSettingsChoice]) -> String {
        let visible = choices.filter { !store.prefs.hiddenCalendarIDs.contains($0.id) }.count
        return AppL10n.format("%lld of %lld", visible, choices.count)
    }

    func setCalendarVisible(_ id: String, visible: Bool) {
        var hidden = store.prefs.hiddenCalendarIDs.filter { $0 != id }
        if !visible { hidden.append(id) }
        if save(.hiddenCalendarIDs(hidden)) { refreshCalendar() }
    }

    func setMeetingHeadsUp(_ value: HeadsUpInterval) {
        if save(.meetingHeadsUp(value)) { refreshCalendar() }
    }

    func setNotifyWhenClosed(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if enabled {
            guard await allow(.notifications) else { return }
        }
        if save(.notifyWhenClosed(enabled)) { refreshReminders() }
    }

    func setPersistentReminders(_ enabled: Bool) {
        if save(.persistentReminders(enabled)) { refreshReminders() }
    }

    func setSnoozeDuration(_ value: SnoozeDuration) {
        if save(.snoozeMinutes(value)) { refreshReminders() }
    }

    func setMirroring(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if enabled {
            guard await allow(.reminders), await enableMirroring() else { return }
        }
        if save(.remindersSync(enabled)) { refreshMirroring() }
    }

    func setPhoneEdits(_ value: PhoneEditPolicy) {
        let previous = store.prefs.phoneEdits
        guard setTwoWay(value == .bringBack) else { return }
        if !save(.phoneEdits(value)) { _ = setTwoWay(previous == .bringBack) }
    }

    /// Preserve a prior installation's explicit two-way consent when showing its new typed setting.
    func reflectExistingPhoneConsent(_ enabled: Bool) {
        let value: PhoneEditPolicy = enabled ? .bringBack : .ignore
        if store.prefs.phoneEdits != value { _ = save(.phoneEdits(value)) }
    }
}

#if DEBUG || PERCH_TESTING
    enum SettingsCalendarPreview: Sendable {
        case standard, denied, picker

        static let choices = [
            CalendarSettingsChoice(id: "sample-home", title: "Home"),
            CalendarSettingsChoice(id: "sample-work", title: "Work"),
            CalendarSettingsChoice(id: "sample-family", title: "Family"),
            CalendarSettingsChoice(id: "sample-other", title: "Other"),
        ]

        @MainActor
        static func show(_ state: Self, app: AppDelegate) {
            if state == .picker {
                let permissions = PermissionPanelModel(access: CalendarSettingsPreviewAccess(denied: false))
                let model = CalendarSettingsModel(store: app.store, permissions: permissions)
                WindowHost.show(
                    "settings-calendar-picker", title: "Calendars shown",
                    size: CGSize(
                        width: SettingsMetrics.windowSize.width - SettingsMetrics.sidebarWidth * 2,
                        height: SettingsMetrics.rowHeight * CGFloat(choices.count + 2) + Theme.Size.cardPadding.value
                            * 2)
                ) {
                    CalendarSettingsPicker(store: app.store, model: model, choices: choices) {
                        WindowHost.windows["settings-calendar-picker"]?.close()
                    }
                }
            } else {
                WindowHost.show("settings", title: "Perch Settings", size: SettingsMetrics.windowSize) {
                    SettingsView(navigation: SettingsNavigation(pane: .calendar))
                        .environmentObject(app.store).environmentObject(app.services)
                        .environment(\.calendarSettingsPreview, state)
                }
            }
        }
    }

    private struct CalendarSettingsPreviewKey: EnvironmentKey {
        static let defaultValue: SettingsCalendarPreview? = nil
    }

    extension EnvironmentValues {
        fileprivate var calendarSettingsPreview: SettingsCalendarPreview? {
            get { self[CalendarSettingsPreviewKey.self] }
            set { self[CalendarSettingsPreviewKey.self] = newValue }
        }
    }

    @MainActor
    private final class CalendarSettingsPreviewAccess: PermissionAccess {
        let denied: Bool
        init(denied: Bool) { self.denied = denied }
        func read(_ feature: PermissionFeature) async -> PermissionReading {
            PermissionReading(denied ? .denied : .allowed)
        }
        func request(_ feature: PermissionFeature) async throws {}
    }
#endif
