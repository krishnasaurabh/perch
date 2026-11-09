import Charts
import PlannerCore
import ServiceManagement
import SwiftUI

/// Regular windows (Settings, Dashboard, Welcome) hosted outside the notch panel.
@MainActor
enum WindowHost {
    static var windows: [String: NSWindow] = [:]

    static func show<V: View>(_ id: String, title: String, size: CGSize, @ViewBuilder content: () -> V) {
        if let w = windows[id] { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content())
        w.center()
        windows[id] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in windows[id] = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

enum SettingsWindow {
    @MainActor static func show(store: PlannerStore, services: Services) {
        WindowHost.show("settings", title: "Perch Settings", size: CGSize(width: 620, height: 560)) {
            SettingsView().environmentObject(store).environmentObject(services)
        }
    }
}

enum DashboardWindow {
    @MainActor static func show(store: PlannerStore, model: NotchModel, services: Services) {
        WindowHost.show("dashboard", title: "Perch", size: CGSize(width: 900, height: 640)) {
            DashboardView().environmentObject(store).environmentObject(model).environmentObject(services)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var services: Services
    @State private var section: Pane = .general
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", workspace = "Workspace", focus = "Focus timer", agents = "AI agents", system = "System"
        var id: String { rawValue }
        var symbol: String { ["General": "gearshape", "Workspace": "rectangle.3.group", "Focus timer": "timer", "AI agents": "sparkles", "System": "lock.shield"][rawValue]! }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $section) { s in Label(s.rawValue, systemImage: s.symbol).tag(s) }
                .navigationSplitViewColumnWidth(170)
        } detail: {
            Form {
                switch section {
                case .general: general
                case .workspace: workspace
                case .focus: focus
                case .agents: AgentsSettings()
                case .system: system
                }
            }
            .formStyle(.grouped)
        }
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
            LabeledContent("Shortcut", value: "⌥N")
            Toggle("Open at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { on in
                do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                catch { store.lastError = "Perch couldn't update the login item: \(error.localizedDescription)" }
            }))
        }
        Section("Displays") {
            Picker("Show Perch on", selection: Binding(get: { store.prefs.showOnDisplay ?? "" }, set: { v in store.updatePrefs { $0.showOnDisplay = v.isEmpty ? nil : v } })) {
                Text("Automatic").tag("")
                Text("Built-in display").tag("builtIn")
                ForEach(NSScreen.screens.filter { !$0.isBuiltIn }, id: \.displayID) { s in Text(s.localizedName).tag(s.localizedName) }
            }
            Text("Choose Automatic to follow the pointer between displays.").font(.caption).foregroundStyle(.secondary)
            Toggle("Draw a notch on external displays", isOn: pref(\.notchOnMonitors))
            Text("Behaves like the built-in notch and hides while an app is full screen.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Insights") {
            Toggle("Count Saturday and Sunday toward the streak", isOn: pref(\.includeWeekendsInStreak))
        }
        Section("Apple Intelligence") {
            Toggle("Auto-sort new tasks", isOn: pref(\.sortWithAI)).disabled(!AISorter.isSupported)
            Text(AISorter.isSupported
                 ? "Uses the on-device model to suggest a priority and project for new tasks. Your explicit #project and !priority choices take precedence."
                 : AISorter.unavailableReason)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var workspace: some View {
        Section("Cards") {
            ForEach(store.prefs.workspaceCardOrder, id: \.self) { id in
                HStack {
                    Toggle(cardName(id), isOn: Binding(get: { !store.prefs.hiddenWorkspaceCards.contains(id) }, set: { show in
                        store.updatePrefs { p in
                            if show { p.hiddenWorkspaceCards.removeAll { $0 == id } }
                            else if p.workspaceCardOrder.count - p.hiddenWorkspaceCards.count > 1 { p.hiddenWorkspaceCards.append(id) }
                        }
                    }))
                    Spacer()
                    Button { moveCard(id, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                    Button { moveCard(id, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                }
            }
            Button("Reset to default") { store.updatePrefs { $0.workspaceCardOrder = Preferences().workspaceCardOrder; $0.hiddenWorkspaceCards = [] } }
            Text("Hiding a card doesn't delete what's in it. One card must stay shown.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Clips") {
            Toggle("Add new screenshots to Clips", isOn: pref(\.catchScreenshots))
            Toggle("Add copied items to Clips", isOn: pref(\.catchCopies))
            Text("Password managers' concealed copies are always skipped.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Calendar") {
            if services.calendar.hasAccess {
                ForEach(services.calendar.calendars, id: \.calendarIdentifier) { c in
                    Toggle(c.title, isOn: Binding(get: { !store.prefs.hiddenCalendarIDs.contains(c.calendarIdentifier) }, set: { on in
                        store.updatePrefs { p in
                            if on { p.hiddenCalendarIDs.removeAll { $0 == c.calendarIdentifier } } else { p.hiddenCalendarIDs.append(c.calendarIdentifier) }
                        }
                        services.calendar.refresh()
                    }))
                }
            } else {
                Button("Allow Calendar Access") { Task { await services.calendar.requestAccess() } }
                Text("Read your schedule alongside the task list. Calendar access is read-only.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder var focus: some View {
        Section("Focus timer") {
            Stepper(value: pref(\.defaultFocusMinutes), in: 5...180, step: 5) { LabeledContent("Default length", value: "\(store.prefs.defaultFocusMinutes) min") }
            Text("Tasks with their own time budget use that instead.").font(.caption).foregroundStyle(.secondary)
            Toggle("Chime when the timer ends", isOn: pref(\.focusCompletionSound))
            Picker("Timer in the notch", selection: pref(\.notchTimerPlacement)) {
                Text("Right of the notch").tag(NotchTimerPlacement.right)
                Text("Left of the notch").tag(NotchTimerPlacement.left)
                Text("Hidden").tag(NotchTimerPlacement.hidden)
            }
            Picker("Workspace timer face", selection: pref(\.workspaceTimerStyle)) {
                Text("Dot grid").tag(WorkspaceTimerStyle.dotMatrix)
                Text("Digital").tag(WorkspaceTimerStyle.digital)
                Text("Minimal").tag(WorkspaceTimerStyle.minimal)
            }
        }
    }

    @ViewBuilder var system: some View {
        Section("Apple Reminders") {
            Toggle("Mirror tasks to Apple Reminders", isOn: Binding(get: { store.prefs.remindersSync }, set: { on in
                Task {
                    if on { guard await services.remindersSync.requestAccess() else {
                        store.lastError = "Perch has no Reminders permission. Grant it under System Settings › Privacy & Security › Reminders."; return } }
                    store.updatePrefs { $0.remindersSync = on }
                    services.remindersSync.sync()
                }
            }))
            Text("Perch maintains its own “Perch” list in Reminders covering today and upcoming days. Edits flow both directions, so checking something off on your phone or watch checks it off here. No other list is touched.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Alert on iPhone and Apple Watch too", isOn: pref(\.ringOnPhone)).disabled(!store.prefs.remindersSync)
            if let e = services.remindersSync.lastError { Text(e).font(.caption).foregroundStyle(.red) }
        }
        Section("Permissions") {
            Button("Request notification permission") { Task { await services.reminders.requestAuthorization() } }
            Button("Privacy settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!) }
        }
        Section("Your data") {
            LabeledContent("Stored at", value: store.file.url.path).textSelection(.enabled)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.file.url]) }
                Button("Export JSON backup…") { exportBackup() }
            }
            Text("Perch has no account, no server and no analytics. Nothing leaves this Mac unless you turn on Reminders sync (via iCloud) or connect an AI app.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("About") {
            LabeledContent("Version", value: AppInfo.version)
            Button("Quit Perch") { NSApp.terminate(nil) }
        }
    }

    func cardName(_ id: String) -> String {
        ["tasks": "Tasks", "focus": "Focus timer", "notepad": "Notepad", "events": "Calendar", "insights": "Insights"][id] ?? id
    }

    func moveCard(_ id: String, _ delta: Int) {
        store.updatePrefs { p in
            guard let i = p.workspaceCardOrder.firstIndex(of: id) else { return }
            let j = i + delta
            guard p.workspaceCardOrder.indices.contains(j) else { return }
            p.workspaceCardOrder.swapAt(i, j)
        }
    }

    func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Perch-\(DayKey(Date())).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try store.file.export(to: url) } catch { store.lastError = error.localizedDescription }
        }
    }
}

struct AgentsSettings: View {
    @EnvironmentObject var store: PlannerStore
    @State private var statuses: [AgentConnector.App: AgentConnector.Status] = [:]
    @State private var message: String?
    @State private var copied: String?

    var body: some View {
        Section("Connect AI agents") {
            Text("One-time setup that lets Claude read and edit your plan, tick tasks off and run timers. The MCP server runs inside Perch on this Mac, with no network hop.")
                .font(.caption).foregroundStyle(.secondary)
            if !AppInfo.isInApplications {
                Label("Agent setup requires Perch to be installed in Applications.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(AgentConnector.App.allCases) { app in
                HStack {
                    Text(app.name)
                    Spacer()
                    switch statuses[app] ?? .notInstalled {
                    case .connected:
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Disconnect") { try? AgentConnector.disconnect(app); refresh() }
                    case .notConnected:
                        Button("Connect") {
                            do { message = try AgentConnector.connect(app) } catch { message = (error as? PlannerError)?.message ?? error.localizedDescription }
                            refresh()
                        }
                    case .notInstalled:
                        Text("Not installed").foregroundStyle(.secondary)
                        if app == .claudeApp { Link("Get it", destination: URL(string: "https://claude.ai/download")!) }
                    }
                }
            }
            if let message { Text(message).font(.caption) }
        }
        Section("Or use Terminal") {
            HStack {
                Text(AgentConnector.terminalCommand).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                Spacer()
                Button(copied == "cmd" ? "Copied" : "Copy") { copy(AgentConnector.terminalCommand, "cmd") }
            }
            Text("Scripts can also open perch://add?title=Your%20task").font(.caption).foregroundStyle(.secondary)
        }
        Section("Try one of these") {
            ForEach(AgentConnector.examplePrompts, id: \.self) { p in
                Button { copy(p, p) } label: {
                    HStack { Text(p); Spacer(); if copied == p { Text("Copied").foregroundStyle(.secondary) } }
                }.buttonStyle(.plain)
            }
            Text("Click a prompt to copy it and paste it into Claude. Its edits appear in the notch immediately; ⌘Z reverts them.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
    }

    func refresh() { for a in AgentConnector.App.allCases { statuses[a] = AgentConnector.status(a) } }
    func copy(_ s: String, _ tag: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == tag { copied = nil } }
    }
}

// MARK: - Dashboard: Today, Upcoming, History, Insights

struct DashboardView: View {
    @EnvironmentObject var store: PlannerStore
    @State private var tab: Tab = .insights
    enum Tab: String, CaseIterable { case upcoming = "Upcoming", history = "History", insights = "Insights", projects = "Projects" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 420).padding(.top, 34).padding(.bottom, 12)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .upcoming: UpcomingList()
                    case .history: HistoryList()
                    case .insights: InsightsDashboard()
                    case .projects: ProjectsList()
                    }
                }.padding(20)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

struct UpcomingList: View {
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        let future = store.planner.tasks.filter { ($0.day.map { $0 > store.today } ?? false) }
        let groups = Dictionary(grouping: future, by: { $0.day! }).sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: 16) {
            if groups.isEmpty { Text("Nothing planned ahead. Add “tomorrow” or a day to a task.").foregroundStyle(.secondary) }
            ForEach(groups, id: \.key) { day, tasks in
                VStack(alignment: .leading, spacing: 4) {
                    Text(day.date().formatted(.dateTime.weekday(.wide).month().day())).font(.headline)
                    ForEach(tasks) { t in DashboardTaskLine(task: t) }
                }
            }
            let inbox = store.engine.tasks(on: .inbox)
            if !inbox.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Inbox").font(.headline)
                    ForEach(inbox) { t in DashboardTaskLine(task: t) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HistoryList: View {
    @EnvironmentObject var store: PlannerStore
    @State private var query = ""
    var body: some View {
        let past = store.planner.tasks.filter { ($0.day.map { $0 < store.today } ?? false) }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        let groups = Dictionary(grouping: past, by: { $0.day! }).sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: 16) {
            TextField("Search history", text: $query).textFieldStyle(.roundedBorder).frame(width: 280)
            if groups.isEmpty { Text(query.isEmpty ? "Finished days show up here." : "No matches. Change the search text.").foregroundStyle(.secondary) }
            ForEach(groups, id: \.key) { day, tasks in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(day.date().formatted(.dateTime.weekday(.wide).month().day())).font(.headline)
                        Text("\(tasks.filter(\.done).count)/\(tasks.count) done").foregroundStyle(.secondary)
                    }
                    ForEach(tasks) { t in DashboardTaskLine(task: t) }
                    let note = store.engine.notepad(on: day)
                    if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.secondary).padding(.leading, 22) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardTaskLine: View {
    let task: PlanTask
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.done ? "checkmark.circle.fill" : "circle").foregroundStyle(task.done ? .green : .secondary)
            Text(task.title).strikethrough(task.done)
            if let p = store.engine.project(id: task.projectID) { Text("#\(p.name)").foregroundStyle(Color(hex: p.colorHex)).font(.caption) }
            if task.focusedSeconds > 0 { Text(TimerText.short(task.focusedSeconds)).font(.caption).foregroundStyle(.secondary) }
            if let c = task.carriedFrom { Text("carried from \(c.raw)").font(.caption).foregroundStyle(.tertiary) }
        }
    }
}

struct InsightsDashboard: View {
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        let i = store.engine.insights()
        let lastDone = i.lastSeven.reduce(0) { $0 + $1.completed }, prevDone = i.previousSeven.reduce(0) { $0 + $1.completed }
        let lastFocus = i.lastSeven.reduce(0) { $0 + $1.focusSeconds }, prevFocus = i.previousSeven.reduce(0) { $0 + $1.focusSeconds }
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                tile("Streak", "\(i.streak) day\(i.streak == 1 ? "" : "s")", "flame.fill")
                tile("Done this week", "\(lastDone)", "checkmark.circle", delta: lastDone - prevDone)
                tile("Focus this week", TimerText.short(lastFocus), "timer", delta: Int((lastFocus - prevFocus) / 60), unit: "m")
                tile("All time", "\(i.allTimeCompleted) tasks", "trophy")
            }
            VStack(alignment: .leading) {
                Text("Planned vs. done, last 7 days").font(.headline)
                Chart {
                    ForEach(i.lastSeven, id: \.day) { d in
                        BarMark(x: .value("Day", d.day.date(), unit: .day), y: .value("Planned", d.planned)).foregroundStyle(.gray.opacity(0.35))
                        BarMark(x: .value("Day", d.day.date(), unit: .day), y: .value("Completed", d.completed)).foregroundStyle(Theme.accent)
                    }
                }.frame(height: 170)
            }
            VStack(alignment: .leading) {
                Text("Minutes focused, last 7 days").font(.headline)
                Chart(i.lastSeven, id: \.day) { d in
                    AreaMark(x: .value("Day", d.day.date(), unit: .day), y: .value("Minutes", d.focusSeconds / 60))
                        .foregroundStyle(Theme.accent.opacity(0.3)).interpolationMethod(.catmullRom)
                    LineMark(x: .value("Day", d.day.date(), unit: .day), y: .value("Minutes", d.focusSeconds / 60))
                        .foregroundStyle(Theme.accent).interpolationMethod(.catmullRom)
                }.frame(height: 150)
            }
            if !i.peakHours.isEmpty {
                Text("Your peak hours: " + i.peakHours.map { Calendar.current.date(bySettingHour: $0, minute: 0, second: 0, of: Date())!.formatted(date: .omitted, time: .shortened) }.joined(separator: ", "))
                    .font(.callout)
            } else {
                Text("No focus sessions yet. Run a timer to see your best hours.").foregroundStyle(.secondary)
            }
        }
    }

    func tile(_ label: String, _ value: String, _ symbol: String, delta: Int? = nil, unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded))
            if let delta {
                Text(delta == 0 ? "same as the week before" : "\(delta > 0 ? "+" : "")\(delta)\(unit) vs the week before")
                    .font(.caption2).foregroundStyle(delta >= 0 ? .green : .orange)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}

struct ProjectsList: View {
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.planner.projects.isEmpty { Text("No projects yet. Add #project to a new task.").foregroundStyle(.secondary) }
            ForEach(store.planner.projects) { p in
                let tasks = store.planner.tasks.filter { $0.projectID == p.id }
                let open = tasks.filter { !$0.done && ($0.day == nil || $0.day! >= store.today) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(Color(hex: p.colorHex)).frame(width: 10, height: 10)
                        Text(p.name).font(.headline)
                        Text("\(open.count) open · \(tasks.filter(\.done).count) done").foregroundStyle(.secondary)
                        Spacer()
                        Button("Delete Project", role: .destructive) {
                            store.apply { e in
                                e.planner.projects.removeAll { $0.id == p.id }
                                for i in e.planner.tasks.indices where e.planner.tasks[i].projectID == p.id { e.planner.tasks[i].projectID = nil }
                            }
                        }.buttonStyle(.borderless)
                    }
                    ForEach(open) { t in DashboardTaskLine(task: t) }
                }
            }
            if !store.planner.projects.isEmpty {
                Text("Deleting a project keeps its tasks, without a project. ⌘Z undoes it.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
