import PlannerCore
import SwiftUI

/// The expanded workspace: header with page picker, then the page.
struct WorkspaceView: View {
    let notchHeight: CGFloat
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var services: Services

    var body: some View {
        VStack(spacing: WorkspaceLayout.headerGap) {
            header.frame(height: WorkspaceLayout.headerHeight(notchHeight: notchHeight))
            ErrorBanner()
            // In-place crossfade between pages: nothing slides or scales.
            ZStack(alignment: .top) {
                page.id(model.page).transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, WorkspaceLayout.bottomInset)
        .foregroundStyle(Theme.text)
        .sheet(item: Binding(get: { model.detailsTaskID.map(IDBox.init) }, set: { model.detailsTaskID = $0?.id })) { box in
            TaskDetailsSheet(taskID: box.id).environmentObject(store).environmentObject(model)
        }
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .home: HomePage()
        case .week: WeekPage()
        case .clips: ClipsPage()
        case .insights: InsightsPage()
        }
    }

    /// Identity on the left, pages and one menu on the right, so nothing sits under the camera housing.
    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                OwlMark(size: 18)
                Text(Date.now, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            pagePicker
            moreMenu
        }
        .padding(.horizontal, 6)
    }

    /// Text-only tabs in one dark pill. The selected pill snaps; only the page below crossfades.
    private var pagePicker: some View {
        HStack(spacing: 0) {
            ForEach(NotchPage.allCases) { p in
                let on = model.page == p
                Button { Motion.animate(Motion.page) { model.page = p } } label: {
                    Text(p.title)
                        .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(on ? Theme.fillStrong : .clear))
                        .foregroundStyle(on ? Theme.text : Theme.secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .transaction { $0.animation = nil }
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.fill))
    }

    /// Undo, Dashboard and Settings behind one button. ⌘Z still undoes directly.
    private var moreMenu: some View {
        Menu {
            Button("Undo") { store.undo() }.disabled(!store.canUndo)
            Divider()
            Button("Open Dashboard") { DashboardWindow.show(store: store, model: model, services: services) }
            Button("Settings…") { SettingsWindow.show(store: store, services: services) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.fill))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }
}

struct IDBox: Identifiable { let id: UUID }

/// Today: today's tasks with the capture field, and beside them only what matters right now:
/// the focus timer while it runs, today's agenda when there are events, the notepad if turned on.
struct HomePage: View {
    @EnvironmentObject var services: Services
    var body: some View { HomeBody(calendar: services.calendar) }
}

private struct HomeBody: View {
    @ObservedObject var calendar: CalendarService
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel

    var body: some View {
        let timer = store.planner.focus.map { $0.state != .finished } ?? false
        let events = calendar.hasAccess && calendar.events.contains { $0.end > model.now }
        let side = HomeLayout.sideCards(store.prefs, timerActive: timer, hasEvents: events)
        VStack(spacing: Theme.gutter) {
            OverdueBanner()
            HStack(alignment: .top, spacing: Theme.gutter) {
                TasksCard().frame(maxHeight: .infinity)
                if !side.isEmpty {
                    Group {
                        if side.count == 1, let id = side.first {
                            sideCard(id).frame(maxHeight: .infinity)
                        } else {
                            // Optional cards scroll independently: never squeeze the timer's controls
                            // or move today's capture out of view when all three cards are enabled.
                            ScrollView {
                                VStack(spacing: Theme.gutter) {
                                    ForEach(side, id: \.self) { id in
                                        sideCard(id).frame(minHeight: id == "notepad" ? 160 : nil)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: Theme.sideColumn)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        // Card enter/leave: the timer starting or today's events loading fades a card in while the task card resizes.
        .motion(Motion.card, value: side)
    }

    @ViewBuilder private func sideCard(_ id: String) -> some View {
        switch id {
        case "focus": FocusCard()
        case "events": AgendaCard()
        default: NotepadCard().frame(maxHeight: .infinity)
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
            .background(Capsule().fill(prominent ? Theme.prominent : (configuration.isPressed ? Theme.fillStrong : Theme.fill)))
            .opacity(prominent && configuration.isPressed ? 0.8 : 1)
            .foregroundStyle(prominent ? Theme.onAccent : Theme.text)
    }
}
