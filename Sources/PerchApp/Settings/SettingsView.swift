import AppKit
import PerchUI
import PlannerCore
import ServiceManagement
import SwiftUI

enum SettingsWindow {
    @MainActor static func show(store: PlannerStore, services: Services) {
        WindowHost.show("settings", title: "Perch Settings", size: CGSize(width: 620, height: 560)) {
            SettingsView().environmentObject(store).environmentObject(services)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var services: Services
    @State private var section: Pane = .general
    @State private var agentStatuses: [AgentConnector.App: AgentConnector.Status] = [:]
    @StateObject private var feedback = SettingsFailureFeedback()
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", workspace = "Workspace", focus = "Focus timer", agents = "AI agents", system =
            "System"
        var id: String { rawValue }
        var title: String { AppL10n.text(rawValue) }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .workspace: "rectangle.3.group"
            case .focus: "timer"
            case .agents: "sparkles"
            case .system: "lock.shield"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $section) { s in Label(s.title, systemImage: s.symbol).tag(s) }
                .navigationSplitViewColumnWidth(170)
        } detail: {
            SettingsDetail(feedback: feedback) {
                Form {
                    switch section {
                    case .general: general
                    case .workspace: workspace
                    case .focus: focus
                    case .agents: AgentsSettings(statuses: $agentStatuses, feedback: feedback)
                    case .system: system
                    }
                }
                .formStyle(.grouped)
            }
            .font(Theme.body)
            .foregroundStyle(Theme.text)
            .buttonStyle(PillStyle())
        }
        .environment(\.controlSurface, Color(nsColor: .windowBackgroundColor))
    }

    func pref<V>(_ kp: WritableKeyPath<Preferences, V>) -> Binding<V> {
        Binding(get: { store.prefs[keyPath: kp] }, set: { v in store.updatePrefs { $0[keyPath: kp] = v } })
    }

    @ViewBuilder var general: some View {
        Section("Opening") {
            Picker("Open the notch on", selection: pref(\.notchOpenTrigger)) {
                Text("Hover").tag(NotchOpenTrigger.hover)
                Text("Click").tag(NotchOpenTrigger.click)
                Text("Double-click").tag(NotchOpenTrigger.doubleClick)
            }
            ShortcutPreferenceRow()
            Text("Works anywhere, even when Perch isn't the front app.").font(Theme.meta).foregroundStyle(
                Theme.secondary)
            Toggle(
                "Open at login",
                isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in
                        feedback.updateLoginItem(on, store: store)
                    }))
        }
        Section("Language") {
            LabeledContent(
                "Interface",
                value: Locale.current.localizedString(
                    forLanguageCode: Locale.current.language.languageCode?.identifier ?? "")
                    ?? AppL10n.text("System language"))
            LabeledContent("Task entry parser", value: AppL10n.text("English"))
            Text(
                "Perch follows the app language for dates, numbers and interface text. Natural-language task entry supports English; other languages never fall back to English or rewrite tasks."
            )
            .font(Theme.meta).foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if TaskParserLanguage.current == nil {
                Text(
                    "Task entry is unavailable in this app language. Choose English to add parsed tasks; existing tasks and literal imports are unchanged."
                )
                .font(Theme.meta).foregroundStyle(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        Section("Notch glance") {
            Toggle("Show today's unfinished task count", isOn: pref(\.notchTaskCount))
                .accessibilityIdentifier("settings.notchTaskCount")
            Text("Off by default. Shows a count only, never task titles. Timers and reminders take priority.")
                .font(Theme.meta).foregroundStyle(Theme.secondary)
            Text(
                "Screen sharing is not detected automatically. Turn this off, or choose Hide task count in the Perch menu, before sharing. If the menu action cannot save, it hides the count for this session only."
            )
            .font(Theme.meta).foregroundStyle(Theme.secondary)
        }
        Section("Displays") {
            Picker(
                "Show Perch on",
                selection: Binding(
                    get: { store.prefs.showOnDisplay ?? "" },
                    set: { v in store.updatePrefs { $0.showOnDisplay = v.isEmpty ? nil : v } })
            ) {
                Text("Automatic").tag("")
                Text("Built-in display").tag("builtIn")
                ForEach(NSScreen.screens.filter { !$0.isBuiltIn }, id: \.displayID) { s in
                    Text(s.localizedName).tag(s.localizedName)
                }
            }
            Text("Choose Automatic to follow the pointer between displays.").font(Theme.meta).foregroundStyle(
                Theme.secondary)
            Toggle("Draw a fake notch on external displays", isOn: pref(\.notchOnMonitors))
            Text("Behaves like the built-in notch and hides while an app is full screen.").font(Theme.meta)
                .foregroundStyle(Theme.secondary)
        }
        Section("Day") {
            Stepper(value: pref(\.resetHour), in: 0...6) {
                LabeledContent("Day ends at", value: Self.hourLabel(store.prefs.resetHour))
            }
            Text("Up to this hour, Perch still counts it as the previous day, so a late night stays on today's list.")
                .font(Theme.meta).foregroundStyle(Theme.secondary)
        }
        Section("Overdue tasks") {
            Picker("Unfinished tasks from earlier days", selection: pref(\.carryMode)) {
                Text("Ask each time").tag(CarryMode.ask)
                Text("Automatically bring to today").tag(CarryMode.auto)
                Text("Leave in history").tag(CarryMode.never)
            }
            Text(
                "Applies when Today opens and at the day boundary. Previously handled tasks are not restored. You can still move individual tasks yourself."
            )
            .font(Theme.meta).foregroundStyle(Theme.secondary)
        }
        Section("Insights") {
            Toggle("Count Saturday and Sunday toward the streak", isOn: pref(\.includeWeekendsInStreak))
        }
        Section("Apple Intelligence") {
            Toggle("Auto-sort new tasks", isOn: pref(\.sortWithAI)).disabled(!AISorter.isSupported)
            Text(
                Self.appleIntelligenceExplanation(
                    isSupported: AISorter.isSupported, unavailableReason: AISorter.unavailableReason)
            )
            .font(Theme.meta).foregroundStyle(Theme.secondary)
        }
    }

    @ViewBuilder var workspace: some View {
        Section("Beside today's tasks") {
            ForEach(HomeLayout.ordered(store.prefs.workspaceCardOrder), id: \.self) { id in
                HStack {
                    Toggle(
                        cardName(id),
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
                    Spacer()
                    Button {
                        moveCard(id, -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }.buttonStyle(PillStyle())
                        .disabled(HomeLayout.ordered(store.prefs.workspaceCardOrder).first == id)
                        .accessibilityLabel(AppL10n.format("Move %@ up", cardName(id)))
                    Button {
                        moveCard(id, 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }.buttonStyle(PillStyle())
                        .disabled(HomeLayout.ordered(store.prefs.workspaceCardOrder).last == id)
                        .accessibilityLabel(AppL10n.format("Move %@ down", cardName(id)))
                }
            }
            Button("Reset to default") {
                store.updatePrefs {
                    $0.workspaceCardOrder = Preferences().workspaceCardOrder;
                    $0.hiddenWorkspaceCards = Preferences().hiddenWorkspaceCards
                }
            }
            Text(
                "Today always shows your tasks. The focus timer appears while it runs and the agenda when you have events. Insights has its own tab."
            )
            .font(Theme.meta).foregroundStyle(Theme.secondary)
        }
        Section("Clips") {
            Toggle("Add new screenshots to Clips", isOn: pref(\.catchScreenshots))
            Toggle("Add copied items to Clips", isOn: pref(\.catchCopies))
            Text("Password managers' concealed copies are always skipped.").font(Theme.meta).foregroundStyle(
                Theme.secondary)
        }
        Section("Calendar") {
            if services.calendar.hasAccess {
                ForEach(services.calendar.calendars, id: \.calendarIdentifier) { c in
                    Toggle(
                        c.title,
                        isOn: Binding(
                            get: { !store.prefs.hiddenCalendarIDs.contains(c.calendarIdentifier) },
                            set: { on in
                                store.updatePrefs { p in
                                    if on {
                                        p.hiddenCalendarIDs.removeAll { $0 == c.calendarIdentifier }
                                    } else {
                                        p.hiddenCalendarIDs.append(c.calendarIdentifier)
                                    }
                                }
                                services.calendar.refresh()
                            }))
                }
            }
            PermissionPanel(services: services, features: [.calendar])
        }
    }

    @ViewBuilder var focus: some View {
        Section("Focus timer") {
            Stepper(value: pref(\.defaultFocusMinutes), in: 5...180, step: 5) {
                LabeledContent("Default length", value: AppL10n.format("%lld min", store.prefs.defaultFocusMinutes))
            }
            Text("Tasks with their own time budget use that instead.").font(Theme.meta).foregroundStyle(Theme.secondary)
            Toggle("Chime when the timer ends", isOn: pref(\.focusCompletionSound))
            Picker("Timer in the notch", selection: pref(\.notchTimerPlacement)) {
                Text("Right of the notch").tag(NotchTimerPlacement.right)
                Text("Left of the notch").tag(NotchTimerPlacement.left)
                Text("Hidden").tag(NotchTimerPlacement.hidden)
            }
            Picker("Workspace timer face", selection: pref(\.workspaceTimerStyle)) {
                Text("Digital").tag(WorkspaceTimerStyle.digital)
                Text("Minimal").tag(WorkspaceTimerStyle.minimal)
                Text("Dot grid").tag(WorkspaceTimerStyle.dotMatrix)
            }
        }
    }

    @ViewBuilder var system: some View {
        Section("Apple Reminders") {
            Toggle(
                "Mirror tasks to Apple Reminders",
                isOn: Binding(
                    get: { store.prefs.remindersSync },
                    set: { on in
                        Task {
                            if on {
                                guard await services.remindersSync.requestAccess() else {
                                    store.lastError = .remindersPermission
                                    return
                                }
                            }
                            store.updatePrefs { $0.remindersSync = on }
                            services.remindersSync.sync()
                        }
                    }))
            Text(
                "Perch creates a separate Reminders list for today's and upcoming tasks. Standard mirroring imports only today's completion. Experimental two-way sync can also import text, priority, due dates, reopening and deletion for linked tasks. Conflicting edits pause sync rather than choose a winner. Existing reminders and other lists are never adopted. Undo or Redo pauses sync until you turn it off and on again."
            )
            .font(Theme.meta).foregroundStyle(Theme.secondary)
            Toggle("Alert on iPhone and Apple Watch too", isOn: pref(\.ringOnPhone)).disabled(
                !store.prefs.remindersSync)
            Text(
                "Mirroring pauses if access is denied or revoked. Phone and Watch alerts also depend on your Reminders account and device settings."
            )
            .font(Theme.meta).foregroundStyle(Theme.secondary)
            ReminderSyncStatus(sync: services.remindersSync)
        }
        Section("Permissions") {
            PermissionPanel(services: services)
        }
        Section("Your data") {
            LabeledContent("Stored at", value: store.file.url.path).textSelection(.enabled)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.file.url]) }
                Button("Export JSON backup…") { exportBackup() }
            }
            Text(
                "Perch stores your planner on this Mac and has no analytics. Optional Reminders sync uses your configured Reminders account. Connected AI apps can read and edit the planner."
            )
            .font(Theme.meta).foregroundStyle(Theme.secondary)
        }
        Section("About") {
            LabeledContent("Version", value: AppInfo.version)
            Button("Quit Perch") { NSApp.terminate(nil) }
        }
    }

    static func appleIntelligenceExplanation(
        isSupported: Bool, unavailableReason: String, locale: Locale? = nil
    ) -> String {
        isSupported
            ? AppL10n.text(
                "Uses the on-device model to suggest a priority and project for new tasks. Your explicit #project and !priority choices take precedence.",
                locale: locale)
            : unavailableReason
    }

    /// "Midnight" for 0, otherwise the hour in the user's clock style ("4 AM" or "04:00").
    static func hourLabel(_ hour: Int) -> String {
        guard hour > 0, let d = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) else {
            return AppL10n.text("Midnight")
        }
        return d.formatted(date: .omitted, time: .shortened)
    }

    func cardName(_ id: String, locale: Locale? = nil) -> String {
        switch id {
        case "focus": AppL10n.text("Focus timer (while running)", locale: locale)
        case "notepad": AppL10n.text("Notepad", locale: locale)
        case "events": AppL10n.text("Today's agenda (when there are events)", locale: locale)
        default: id
        }
    }

    func moveCard(_ id: String, _ delta: Int) {
        store.updatePrefs { p in
            var order = HomeLayout.ordered(p.workspaceCardOrder)
            guard let i = order.firstIndex(of: id) else { return }
            let j = i + delta
            guard order.indices.contains(j) else { return }
            order.swapAt(i, j)
            p.workspaceCardOrder = order
        }
    }

    func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Perch-\(store.today).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            feedback.exportBackup(to: url, store: store)
        }
    }
}

/// Retains only the failed Settings operation, never a guessed retry for an unrelated store error.
@MainActor
final class SettingsFailureFeedback: ObservableObject {
    @Published private(set) var retryError: PerchAppError?
    private var retryAction: (() -> Void)?

    func canRetry(_ error: PerchAppError) -> Bool { retryError == error && retryAction != nil }

    func retry(_ error: PerchAppError) {
        guard canRetry(error) else { return }
        retryAction?()
    }

    @discardableResult
    func perform(
        store: PlannerStore, failure: @escaping (Error) -> PerchAppError,
        operation: @escaping () throws -> Void
    ) -> Bool {
        do {
            try operation()
            if store.lastError == retryError { store.lastError = nil }
            retryError = nil
            retryAction = nil
            return true
        } catch {
            let presented = failure(error)
            retryAction = { [weak self, weak store] in
                guard let self, let store else { return }
                self.perform(store: store, failure: failure, operation: operation)
            }
            retryError = presented
            store.lastError = presented
            return false
        }
    }

    func updateLoginItem(
        _ enabled: Bool, store: PlannerStore,
        change: @escaping (Bool) throws -> Void = { enabled in
            enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        }
    ) {
        perform(store: store, failure: { .loginItem($0.perchPresentationDetail) }) { try change(enabled) }
    }

    func exportBackup(
        to url: URL, store: PlannerStore, export: ((URL) throws -> Void)? = nil
    ) {
        let write = export ?? { try store.file.export(to: $0) }
        perform(store: store, failure: { .planner($0.perchPresentationDetail) }) { try write(url) }
    }
}

struct SettingsErrorRow: View {
    let error: PerchAppError
    var retry: (() -> Void)?
    var status: StatusLabel { StatusLabel(title: error.perchPresentationDetail, tone: .danger) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            status.textSelection(.enabled)
            Spacer(minLength: 0)
            if let retry {
                Button("Repeat", systemImage: "arrow.clockwise", action: retry)
                    .help("Action failed. Please try again.")
                    .buttonStyle(PillStyle())
                    .accessibilityIdentifier("settings.error.retry")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.08))
    }
}

/// The detail surface is stable while the selected form changes.
struct SettingsDetail<Content: View>: View {
    @EnvironmentObject var store: PlannerStore
    @ObservedObject var feedback: SettingsFailureFeedback
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.lastError {
                SettingsErrorRow(
                    error: error,
                    retry: feedback.canRetry(error) ? { feedback.retry(error) } : nil
                )
                .padding([.horizontal, .top], 12)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
