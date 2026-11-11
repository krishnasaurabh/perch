import PlannerCore
import PerchUI
import SwiftUI

enum TodayFocus: Hashable {
    case capture
    case undo
    case task(UUID, RowAction)

    enum RowAction: Hashable {
        case complete, focus, details, delete, rename
        var identifierPrefix: String {
            switch self {
            case .complete: "task-complete-"
            case .focus: "task-focus-"
            case .details: "task-details-"
            case .delete: "task-delete-"
            case .rename: "task-rename-"
            }
        }
    }
    var taskID: UUID? {
        if case .task(let id, _) = self { return id }
        return nil
    }
}

/// Stable, visible actions. Hover changes the background, never the row's layout or available controls.
struct TaskRow: View {
    let task: PlanTask
    var compact = false
    var focus: FocusState<TodayFocus?>.Binding? = nil
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @FocusState private var localFocus: TodayFocus?
    @State private var hover = false
    @State private var editing = false
    @State private var draft = ""
    @State private var ticked = false

    private var focusBinding: FocusState<TodayFocus?>.Binding { focus ?? $localFocus }
    private var canFocus: Bool {
        !task.done && task.day == store.today
            && store.planner.focus.map { $0.state == .running || $0.state == .paused } != true
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            completion
            VStack(alignment: .leading, spacing: 5) {
                if editing {
                    TextField("Task title", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).font(Theme.body)
                        .focused(focusBinding, equals: .task(task.id, .rename))
                        .onSubmit(commitRename)
                        .onExitCommand {
                            editing = false; focusBinding.wrappedValue = .task(task.id, .complete)
                        }
                } else {
                    accessibleTitle
                }
                if !compact { metadata }
                // Keep the title's full width at narrow sizes and at larger text sizes.
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 7).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hover ? Theme.fill : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .onChange(of: canFocus) { _, available in
            if !available && focusBinding.wrappedValue == .task(task.id, .focus) {
                focusBinding.wrappedValue = .task(task.id, .complete)
            }
        }
        .task(id: ticked) {
            guard ticked else { return }
            do { try await Task.sleep(nanoseconds: Motion.reduceMotion ? 0 : 140_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            Motion.animate(Motion.row) {
                if task.day == store.today {
                    store.apply { try $0.complete(task.id) }
                } else if let day = task.day, day < store.today {
                    store.send(.completeOverdue([task.id]))
                } else {
                    store.send(.complete(task.id))
                }
            }
            ticked = false
        }
    }

    // Keep native child buttons navigable, but publish the row summary on a leaf.
    // macOS accessibility groups do not consistently expose a value or help text.
    private var accessibleTitle: some View {
        Text(task.title).font(Theme.title)
            .foregroundStyle(task.done ? Theme.secondary : Theme.text)
            .strikethrough(task.done)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onTapGesture(count: 2, perform: beginRename)
            .accessibilityIdentifier("task-row-\(task.id)")
            .accessibilityLabel(task.title)
            .accessibilityValue(accessibilitySummary)
            .accessibilityHint(
                "Use actions to complete or reopen, view details, focus, or delete this task. Deletion can be undone."
            )
            .accessibilityActions {
                Button(task.done ? "Reopen" : "Complete", action: toggle)
                Button("Details") { model.detailsTaskID = task.id }
                Button("Delete", role: .destructive, action: delete)
                if canFocus { Button("Focus", action: startFocus) }
            }
    }

    private var completion: some View {
        Button(action: toggle) {
            let on = task.done || ticked
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(on ? Theme.text : Theme.secondary)
                .frame(width: Theme.minimumTarget, height: Theme.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused(focusBinding, equals: .task(task.id, .complete))
        .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
            // This custom focus target must activate the same action as the button.
            // Consume the rest of the gesture even if completion moves focus to another row.
            guard focusBinding.wrappedValue == .task(task.id, .complete), press.modifiers.isEmpty else {
                return .ignored
            }
            if press.phase == .down { toggle() }
            return .handled
        }
        .focusEffectDisabled()
        .overlay(
            ControlFocusRing(
                shape: RoundedRectangle(cornerRadius: 6),
                focused: focusBinding.wrappedValue == .task(task.id, .complete))
        )
        .accessibilityLabel(
            task.done
                ? AppL10n.format("Reopen %@", task.title)
                : AppL10n.format("Complete %@", task.title)
        )
        .accessibilityValue(task.done || ticked ? AppL10n.text("Completed") : AppL10n.text("Not completed"))
        .accessibilityIdentifier("task-complete-\(task.id)")
        .help(task.done ? "Reopen task" : "Complete task")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if canFocus {
                action("play.fill", title: "Focus", kind: .focus, perform: startFocus)
            }
            action("slider.horizontal.3", title: "Details", kind: .details) { model.detailsTaskID = task.id }
            action("trash", title: "Delete", kind: .delete, role: .destructive, perform: delete)
        }
    }

    private func action(
        _ symbol: String, title: String, kind: TodayFocus.RowAction,
        role: ButtonRole? = nil, perform: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: perform) {
            Label(title, systemImage: symbol).labelStyle(.titleOnly)
                .foregroundStyle(role == .destructive ? Theme.danger : Theme.text)
        }
        .buttonStyle(PillStyle())
        .focusable(true)
        .focused(focusBinding, equals: .task(task.id, kind))
        .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
            guard focusBinding.wrappedValue == .task(task.id, kind), press.modifiers.isEmpty else {
                return .ignored
            }
            if press.phase == .down { perform() }
            return .handled
        }
        .focusEffectDisabled()
        .overlay(
            ControlFocusRing(
                shape: Capsule(), focused: focusBinding.wrappedValue == .task(task.id, kind))
        )
        .accessibilityLabel("\(title) \(task.title)")
        .accessibilityIdentifier(kind.identifierPrefix + task.id.uuidString)
        .help(title == "Delete" ? "Delete task. Use Undo below the list to restore it." : "\(title) task")
    }

    private var metadata: some View {
        // A wrapping layout keeps priority and scheduling information readable rather than truncating chips.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) { metadataLabels }
            VStack(alignment: .leading, spacing: 3) { metadataLabels }
        }
        .font(Theme.meta)
        .foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var metadataLabels: some View {
        if task.priority != .none {
            Label(task.priority.rawValue.capitalized, systemImage: "flag.fill")
                .foregroundStyle(Theme.priority(task.priority))
                .accessibilityLabel("\(task.priority.rawValue.capitalized) priority")
        }
        if let r = task.remindAt {
            Label(r.formatted(date: .omitted, time: .shortened), systemImage: "bell")
                .foregroundStyle(r < Date() && !task.done ? Theme.danger : Theme.secondary)
        }
        if let p = store.engine.project(id: task.projectID) { Label(p.name, systemImage: "number") }
        if let d = task.deadline {
            Label("Due " + shortDay(d), systemImage: "calendar")
                .foregroundStyle(d < store.today && !task.done ? Theme.danger : Theme.secondary)
        }
        if let rule = task.repeatRule { Label(rule.description, systemImage: "repeat") }
        if let m = task.minutes { Label("\(m)m", systemImage: "timer") }
        if !task.steps.isEmpty {
            Label("\(task.steps.filter(\.done).count)/\(task.steps.count) steps", systemImage: "list.bullet")
        }
        if let c = task.carriedFrom { Label("From " + shortDay(c), systemImage: "arrow.uturn.right") }
        if let agent = task.agentID, let name = AgentName.short(agent) {
            Label("Via " + name, systemImage: "sparkles").help("Added through MCP by \(agent)")
        }
    }

    private func shortDay(_ d: DayKey) -> String { d.date().formatted(.dateTime.month(.abbreviated).day()) }

    @ViewBuilder private var menu: some View {
        if !task.done {
            Button("Start focusing", action: startFocus).disabled(!canFocus)
            Button("Set Time Limit…") { model.detailsTaskID = task.id }
            Divider()
            Button("Move to Tomorrow") { move(.day(store.today.adding(days: 1))) }
            Button("Move to Inbox") { move(.inbox) }
            if task.day != store.today { Button("Move to Today") { move(.day(store.today)) } }
            Divider()
            Menu("Priority") {
                ForEach(TaskPriority.allCases.reversed(), id: \.self) { p in
                    Button(p == .none ? "None" : p.rawValue.capitalized) {
                        store.updateTask(task.id) { $0.priority = p }
                    }
                }
            }
        }
        Button("Rename", action: beginRename)
        Button("Details…") { model.detailsTaskID = task.id }
        if task.repeatRule != nil { Button("Stop Repeating") { store.apply { try $0.endRepeat(of: task.id) } } }
        Divider()
        Button("Delete", role: .destructive, action: delete)
    }

    private var accessibilitySummary: String {
        let state = task.done || ticked ? AppL10n.text("Completed") : AppL10n.text("Not completed")
        return task.priority == .none
            ? state
            : AppL10n.format("%@, %@ priority", state, task.priority.rawValue.capitalized)
    }

    private func startFocus() {
        guard canFocus else { return }
        store.apply { try $0.startTimer(task: task.id, minutes: nil) }
    }

    func toggle() {
        if task.done { Motion.animate(Motion.row) { _ = store.apply { try $0.reopen(task.id) } }; return }
        guard !ticked else { return }
        ticked = true
    }

    private func beginRename() {
        draft = task.title
        editing = true
        focusBinding.wrappedValue = .task(task.id, .rename)
    }
    private func move(_ to: DayRef) {
        store.apply { try $0.move(task.id, from: task.day.map { .day($0) } ?? .inbox, to: to) }
    }
    func delete() { store.apply { try $0.delete(task.id, on: task.day.map { .day($0) } ?? .inbox) } }
    private func commitRename() {
        editing = false
        focusBinding.wrappedValue = .task(task.id, .complete)
        guard draft != task.title else { return }
        store.apply { try $0.rename(task.id, on: task.day.map { .day($0) } ?? .inbox, to: draft) }
    }
}
