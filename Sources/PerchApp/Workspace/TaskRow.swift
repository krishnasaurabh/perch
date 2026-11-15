import PlannerCore
import PerchUI
import SwiftUI
import UniformTypeIdentifiers

/// Export the typed identity and the legacy UUID text from a single drag. Week's
/// existing String destinations remain usable while typed timelines adopt it.
@MainActor enum ChecklistTaskDrag {
    static func provider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider(object: id.uuidString as NSString)
        let data = try? JSONEncoder().encode(TaskDragItem(taskID: id))
        provider.registerDataRepresentation(forTypeIdentifier: UTType.perchTask.identifier, visibility: .ownProcess) {
            completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

/// Capture and Undo stay outside the checklist's single keyboard stop.
enum TodayFocus: Hashable {
    case capture, undo, checklist
}

/// One row, one layout pass. The checklist owns keyboard movement; every action
/// remains available to pointer and assistive technology without extra Tab stops.
struct TaskRow: View {
    let task: PlanTask
    var compact = false
    var current = false
    var selected = false
    var keyboardFocused = false
    var inChecklist = false
    var selectedStepID: UUID? = nil
    var expanded: Binding<Bool>? = nil
    var onSelect: () -> Void = {}
    var onEdit: (() -> Void)? = nil
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @State private var locallyExpanded = false

    private var isExpanded: Bool { current || (expanded?.wrappedValue ?? locallyExpanded) }
    private var surface: PerchSurface { current ? .butter : .paper }
    private var canFocus: Bool {
        !task.done && task.day == store.today
            && store.planner.focus.map { $0.state == .running || $0.state == .paused } != true
    }

    var body: some View {
        Group {
            if current {
                CurrentTaskBlock(task: task) {
                    completion
                } title: {
                    accessibleTitle
                } steps: {
                    steps
                }
            } else {
                VStack(alignment: .leading, spacing: .zero) {
                    HStack(spacing: Theme.Size.focusGap.value) {
                        disclosure
                        completion
                        accessibleTitle
                        details.fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(minHeight: Theme.Size.taskRowHeight.value)
                    if isExpanded { steps }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(); if !task.steps.isEmpty && !current { toggleSteps() }
        }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .overlay(
            FocusRing(
                shape: RoundedRectangle(cornerRadius: Theme.Size.currentTaskRadius.value),
                focused: keyboardFocused && selected && selectedStepID == nil, surface: surface)
        )
        .onDrag { ChecklistTaskDrag.provider(for: task.id) }
    }

    private var accessibleTitle: some View {
        Text(task.title)
            .perchFont(current ? .currentTask : .body)
            .foregroundStyle(task.done ? Theme.ink3 : Theme.ink)
            .strikethrough(task.done)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .designMotion(.strikeThrough, value: task.done)
            .onTapGesture(count: 2, perform: edit)
            .accessibilityIdentifier("task-row-\(task.id)")
            .accessibilityLabel(task.title)
            .accessibilityValue(accessibilitySummary)
            .accessibilityHint("Use the arrow keys to choose a task. Space checks it off. Return edits it.")
            .accessibilityActions {
                Button(AppL10n.text(task.done ? "Reopen" : "Complete"), action: toggle)
                Button("Details", action: edit)
                Button("Delete", role: .destructive, action: delete)
                Button("Park it for later", action: park)
                if !task.steps.isEmpty && !current { Button("Show or hide its steps", action: toggleSteps) }
                if canFocus { Button("Set time aside", action: startFocus) }
            }
    }

    private var completion: some View {
        PerchCheckbox(
            title: task.title,
            isOn: Binding(get: { task.done }, set: { _ in toggle() }),
            surface: surface, keyboardFocusable: !inChecklist
        )
        .frame(width: Theme.Size.minimumTarget.value, height: Theme.Size.minimumTarget.value)
        .accessibilityLabel(
            task.done ? AppL10n.format("Reopen %@", task.title) : AppL10n.format("Complete %@", task.title)
        )
        .accessibilityValue(task.done ? AppL10n.text("Done") : AppL10n.text("Not completed"))
        .accessibilityIdentifier("task-complete-\(task.id)")
    }

    private var disclosure: some View {
        Button(action: toggleSteps) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .perchFont(.detailStrong)
                .opacity(task.steps.isEmpty ? 0 : 1)
                .frame(width: Theme.Size.minimumTarget.value, height: Theme.Size.minimumTarget.value)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink2)
        .disabled(task.steps.isEmpty)
        .focusable(false)
        .accessibilityHidden(task.steps.isEmpty)
        .accessibilityLabel(AppL10n.format(isExpanded ? "Hide steps for %@" : "Show steps for %@", task.title))
        .accessibilityValue(isExpanded ? AppL10n.text("Open") : AppL10n.text("Closed"))
        .accessibilityIdentifier("task-steps-\(task.id)")
    }

    private var details: some View {
        Text(detailText)
            .perchFont(.detail)
            .foregroundStyle(task.done ? Theme.doneText : task.carriedFrom != nil ? Theme.carried : Theme.ink2)
            .accessibilityIdentifier("task-detail-\(task.id)")
    }

    private var detailText: String {
        if task.done { return AppL10n.text("Done") }
        var bits: [String] = []
        if task.carriedFrom != nil { bits.append(AppL10n.text("Carried over")) }
        if let start = task.startAt { bits.append(start.formatted(date: .omitted, time: .shortened)) }
        if !task.steps.isEmpty {
            bits.append(AppL10n.format("%lld of %lld", task.steps.filter(\.done).count, task.steps.count))
        }
        return bits.joined(separator: " · ")
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Theme.Size.focusGap.value) {
            ForEach(task.steps) { step in
                TaskStepRow(
                    taskID: task.id, step: step,
                    next: current && step.id == TodayTaskNavigation.nextStep(in: task.steps),
                    selected: keyboardFocused && selected && selectedStepID == step.id,
                    keyboardFocusable: false, surface: surface
                )
                .id(step.id)
            }
        }
        .padding(.leading, Theme.Size.minimumTarget.value + Theme.Size.focusGap.value)
    }

    private var accessibilitySummary: String {
        var bits = [task.done ? AppL10n.text("Done") : AppL10n.text("Not completed")]
        if !detailText.isEmpty && !task.done { bits.append(detailText) }
        if task.priority != .none { bits.append(AppL10n.format("%@ priority", AppL10n.priority(task.priority))) }
        if let r = task.remindAt, r < store.engine.now() && !task.done {
            bits.append(AppL10n.text("The reminder time has passed."))
        }
        return bits.joined(separator: ", ")
    }

    @ViewBuilder private var menu: some View {
        if !task.done {
            Button("Set time aside", action: startFocus).disabled(!canFocus)
            Button("Move to Tomorrow") { move(.day(store.today.adding(days: 1))) }
            Button("Park it for later", action: park)
            if task.day != store.today { Button("Move to Today") { move(.day(store.today)) } }
            Menu("Priority") {
                ForEach(TaskPriority.allCases.reversed(), id: \.self) { priority in
                    Button(AppL10n.priority(priority)) { store.updateTask(task.id) { $0.priority = priority } }
                }
            }
        }
        Button("Edit task", action: edit)
        if task.repeatRule != nil { Button("Stop Repeating") { store.apply { try $0.endRepeat(of: task.id) } } }
        Divider()
        Button("Delete", role: .destructive, action: delete)
    }

    private func toggleSteps() {
        guard !current else { return }
        if let expanded { expanded.wrappedValue.toggle() } else { locallyExpanded.toggle() }
        onSelect()
    }
    private func edit() { if let onEdit { onEdit() } else { model.detailsTaskID = task.id } }
    private func startFocus() {
        guard canFocus else { return }
        store.apply { try $0.startTimer(task: task.id, minutes: nil) }
    }
    func toggle() {
        onSelect()
        if task.done {
            store.apply { try $0.reopen(task.id) }
        } else if let day = task.day, day < store.today {
            store.send(.completeOverdue([task.id]))
        } else {
            store.send(.complete(task.id))
        }
    }
    private func move(_ day: DayRef) {
        store.apply { try $0.move(task.id, from: task.day.map { .day($0) } ?? .inbox, to: day) }
    }
    private func park() { store.apply { try TodayTaskNavigation.park(task.id, commands: $0) } }
    func delete() { store.apply { try $0.delete(task.id, on: task.day.map { .day($0) } ?? .inbox) } }
}

/// Shared by the checklist and compact presentations of the current task.
struct TaskStepRow: View {
    let taskID: UUID
    let step: Subtask
    var next = false
    var selected = false
    var keyboardFocusable = true
    var surface: PerchSurface = .paper
    @EnvironmentObject var store: PlannerStore

    var body: some View {
        HStack(spacing: Theme.Size.cardPadding.value / 2) {
            PerchCheckbox(
                title: step.title,
                isOn: Binding(
                    get: { step.done },
                    set: { value in
                        store.updateTask(taskID) { draft in
                            if let index = draft.steps.firstIndex(where: { $0.id == step.id }) {
                                draft.steps[index].done = value
                            }
                        }
                    }), kind: .step, surface: surface, keyboardFocusable: keyboardFocusable
            )
            .frame(width: Theme.Size.minimumTarget.value, height: Theme.Size.minimumTarget.value)
            .accessibilityIdentifier("step-complete-\(step.id)")
            Text(step.title)
                .perchFont(next ? .button : .body)
                .strikethrough(step.done)
                .foregroundStyle(step.done ? Theme.ink3 : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .designMotion(.strikeThrough, value: step.done)
            if next { Text("next").perchFont(.detail).foregroundStyle(Theme.ink2) }
            Spacer(minLength: .zero)
        }
        .frame(minHeight: Theme.Size.stepRowHeight.value)
        .overlay(
            FocusRing(
                shape: RoundedRectangle(cornerRadius: Theme.Size.stepCheckboxRadius.value),
                focused: selected, surface: surface))
    }
}
