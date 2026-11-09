import PlannerCore
import SwiftUI

/// The expanded workspace: header with page picker, then the page.
struct WorkspaceView: View {
    let notchHeight: CGFloat
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var services: Services

    var body: some View {
        VStack(spacing: 10) {
            header.frame(height: max(notchHeight, 30))
            ErrorBanner()
            Group {
                switch model.page {
                case .home: HomePage()
                case .week: WeekPage()
                case .clips: ClipsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 14)
        .foregroundStyle(Theme.text)
        .sheet(item: Binding(get: { model.detailsTaskID.map(IDBox.init) }, set: { model.detailsTaskID = $0?.id })) { box in
            TaskDetailsSheet(taskID: box.id).environmentObject(store).environmentObject(model)
        }
    }

    private var header: some View {
        ZStack {
            pagePicker
            HStack(spacing: 10) {
            HStack(spacing: 7) {
                OwlMark(size: 18)
                Text(Date.now, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
            }
            Spacer()
            HStack(spacing: 6) {
                GlassButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { store.undo() }.disabled(!store.canUndo)
                GlassButton(symbol: "macwindow", help: "Open dashboard") { DashboardWindow.show(store: store, model: model, services: services) }
                GlassButton(symbol: "gearshape", help: "Settings") { SettingsWindow.show(store: store, services: services) }
            }
            }
        }
        .padding(.horizontal, 6)
    }

    /// Centered on the panel (and therefore under the notch) regardless of the side groups' widths.
    private var pagePicker: some View {
            HStack(spacing: 2) {
                ForEach(NotchPage.allCases) { p in
                    Button { withAnimation(.spring(response: 0.3)) { model.page = p } } label: {
                        Label(p.title, systemImage: p.symbol)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(model.page == p ? Color.white.opacity(0.14) : .clear))
                            .foregroundStyle(model.page == p ? Theme.text : Theme.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            // On a MacBook the hardware notch sits dead center, so the picker drops just below it.
            .offset(y: (model.geometry?.hasHardwareNotch ?? false) ? (model.geometry!.notchSize.height + 2) / 2 + 12 : 0)
    }
}

struct IDBox: Identifiable { let id: UUID }

/// Today: tasks | focus | notepad, with agenda + insights underneath. Cards follow the user's order and visibility.
struct HomePage: View {
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        let order = store.prefs.workspaceCardOrder.filter { !store.prefs.hiddenWorkspaceCards.contains($0) }
        let top = order.filter { ["tasks", "focus", "notepad"].contains($0) }
        let bottom = order.filter { ["events", "insights"].contains($0) }
        VStack(spacing: 10) {
            OverdueBanner()
            HStack(alignment: .top, spacing: 10) {
                ForEach(top, id: \.self) { id in
                    switch id {
                    case "tasks": TasksCard().frame(minWidth: 300, maxWidth: .infinity)
                    case "focus": FocusCard().frame(width: 200)
                    default: NotepadCard().frame(minWidth: 200, maxWidth: .infinity)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            if !bottom.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(bottom, id: \.self) { id in
                        if id == "events" { AgendaCard().frame(maxWidth: .infinity) } else { InsightsCard().frame(maxWidth: .infinity) }
                    }
                }
                .frame(height: 104)
            }
        }
    }
}

/// Resolve overdue work explicitly, or save a policy for future Home visits.
struct OverdueBanner: View {
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @State private var lastPolicyDay: DayKey?

    var body: some View {
        let overdue = store.engine.overdue()
        Group {
            if !overdue.isEmpty || store.prefs.carryMode != .ask {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(Theme.accent)
                        Text(summary(count: overdue.count))
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 8)
                        policyMenu
                    }
                    if !overdue.isEmpty && store.prefs.carryMode == .ask {
                        HStack(spacing: 8) {
                            Text("Keep their history, or mark them done on their original days.")
                                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button("Bring to today") {
                                store.apply { $0.carryForward(overdue.map(\.id), to: $0.today) }
                            }
                            .buttonStyle(PillStyle(prominent: true))
                            .help("Copy these tasks to today and keep the originals in history.")
                            Button("Mark all done") {
                                store.apply { $0.completeOverdue(overdue.map(\.id)) }
                            }
                            .buttonStyle(PillStyle())
                            .help("Complete these tasks on their original days, without moving them.")
                            Button("Leave in history") {
                                store.apply { $0.dismissOverdue(overdue.map(\.id)) }
                            }
                            .buttonStyle(PillStyle())
                        }
                    }
                }
                .card(padding: 10)
            }
        }
        .onAppear { applyPolicyIfNeeded(force: true) }
        // Run once per logical day, not after each mutation: Undo must not immediately
        // trigger the same automatic action again and erase the redo stack.
        .onReceive(model.$now) { _ in applyPolicyIfNeeded() }
    }

    private var policyMenu: some View {
        Menu {
            Picker("Overdue tasks", selection: Binding(
                get: { store.prefs.carryMode },
                set: { mode in
                    store.apply { engine in
                        engine.planner.preferences.carryMode = mode
                        engine.applyCarryMode()
                    }
                }
            )) {
                Text("Ask each time").tag(CarryMode.ask)
                Text("Automatically bring to today").tag(CarryMode.auto)
                Text("Never carry; leave in history").tag(CarryMode.never)
            }
        } label: {
            Text("Overdue: \(policyLabel)").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Overdue task policy: \(policyLabel)")
        .help("Applies when Home opens and at the day boundary. Ask does not restore already handled tasks.")
    }

    private var policyLabel: String {
        switch store.prefs.carryMode {
        case .ask: return "Ask"
        case .auto: return "Auto"
        case .never: return "Never"
        }
    }

    private func summary(count: Int) -> String {
        switch store.prefs.carryMode {
        case .ask: return "\(count) unfinished \(count == 1 ? "task" : "tasks") from earlier days"
        case .auto: return "Leftover tasks copy forward automatically"
        case .never: return "Unfinished tasks stay in history"
        }
    }

    private func applyPolicyIfNeeded(force: Bool = false) {
        let day = store.engine.today
        guard force || lastPolicyDay != day else { return }
        lastPolicyDay = day
        guard store.prefs.carryMode != .ask, !store.engine.overdue().isEmpty else { return }
        store.apply { $0.applyCarryMode() }
    }
}

struct PillStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(prominent ? Theme.accent.opacity(configuration.isPressed ? 0.7 : 0.9) : Color.white.opacity(configuration.isPressed ? 0.2 : 0.1)))
            .foregroundStyle(prominent ? Color.black : Theme.text)
    }
}
