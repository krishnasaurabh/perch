import PerchUI
import PlannerCore
import SwiftUI

/// A local draft with one explicit save. Closing or cancelling never commits field edits.
struct TaskDetailsSheet: View {
    let taskID: UUID
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let task = store.planner.tasks.first(where: { $0.id == taskID }) {
            TaskDetailsEditor(task: task, today: store.today, calendar: store.engine.calendar).id(taskID)
        } else {
            VStack(spacing: Theme.cardPadding) {
                ContentUnavailableView(
                    "Task unavailable", systemImage: "checkmark.circle", description: Text("This task was removed.")
                )
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(PillStyle())
                    .accessibilityIdentifier("details-close")
            }
            .padding()
        }
    }
}

private struct TaskDetailsEditor: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var editor: TaskDetailsPickerDraft
    @State private var newStep = ""
    @State private var saveError: String?
    @State private var confirmDelete = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case title, notes, newStep }

    @FocusState private var repeatFocus: RepeatPickerFields.Focus?

    init(task: PlanTask, today: DayKey, calendar: Calendar) {
        _editor = State(initialValue: TaskDetailsPickerDraft(task: task, today: today, calendar: calendar))
    }

    private var readOnly: Bool { editor.details.original.day.map { $0 < store.today } ?? false }
    private var errors: [TaskDetailsField: String] {
        editor.errors(today: store.today, now: store.engine.now(), projects: store.planner.projects)
    }
    private var calendar: Calendar { store.engine.calendar }

    var body: some View {
        // Reserve the footer in layout, not just in the scroll view's safe area.
        // Native scrolling content must never draw underneath these controls.
        VStack(spacing: 0) {
            form
            footer
        }
        .font(Theme.body).foregroundStyle(Theme.text)
        .frame(minWidth: 280, idealWidth: 460, maxWidth: 600, minHeight: 220, idealHeight: 600, maxHeight: 760)
        .environment(\.calendar, calendar)
        .onAppear { if !readOnly { focusedField = .title } }
    }

    private var form: some View {
        let draft = editor.details
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardPadding) {
                if readOnly {
                    Label(
                        "Earlier days are read-only. Your history and focus time stay unchanged.", systemImage: "lock"
                    )
                    .font(Theme.body).foregroundStyle(Theme.secondary)
                    Text(draft.title).font(Theme.heading).textSelection(.enabled)
                } else {
                    field("Title", error: errors[.title]) {
                        TextField("Task title", text: $editor.details.title)
                            .textFieldStyle(.roundedBorder).focused($focusedField, equals: .title)
                            .accessibilityIdentifier("details-title")
                            .onSubmit { focusedField = nil }
                    }
                }
                VStack(alignment: .leading, spacing: Theme.cardPadding) {
                    schedule
                    reminder
                    deadline
                    field("Priority") {
                        Picker("Priority", selection: $editor.details.priority) {
                            ForEach(TaskPriority.allCases.reversed(), id: \.self) { priority in
                                Text(priority == .none ? "None" : priority.rawValue.capitalized).tag(priority)
                            }
                        }.labelsHidden().pickerStyle(.menu)
                    }
                    field("Project", error: errors[.project]) {
                        Picker("Project", selection: $editor.details.projectID) {
                            Text("None").tag(UUID?.none)
                            ForEach(store.planner.projects) { project in
                                Text(project.name).tag(Optional(project.id))
                            }
                            if let missing = editor.details.projectID,
                                !store.planner.projects.contains(where: { $0.id == missing })
                            {
                                Text("Unavailable project").tag(Optional(missing))
                            }
                        }.labelsHidden()
                    }
                    field("Repeat") {
                        RepeatPickerFields(draft: $editor.repeatRule, focus: $repeatFocus)
                    }
                    field("Time limit", error: errors[.minutes]) {
                        Stepper(value: $editor.details.minutes, in: 0...720, step: 5) {
                            Text(editor.details.minutes == 0 ? "None" : "\(editor.details.minutes) min")
                                .monospacedDigit()
                        }.disabled(editor.details.original.done)
                    }
                    steps
                    field("Notes") {
                        TextEditor(text: $editor.details.notes)
                            .font(Theme.body).frame(minHeight: 90)
                            .focused($focusedField, equals: .notes)
                            .scrollContentBackground(.hidden).padding(6)
                            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(Theme.inputStroke))
                            .overlay(
                                ControlFocusRing(
                                    shape: RoundedRectangle(cornerRadius: Theme.controlRadius),
                                    focused: focusedField == .notes)
                            )
                            .accessibilityLabel("Notes")
                    }
                }.disabled(readOnly)
                if let seconds = store.planner.tasks.first(where: { $0.id == editor.details.original.id })?
                    .focusedSeconds,
                    seconds > 0
                {
                    Text("Focused \(TimerText.short(seconds))").font(Theme.meta).foregroundStyle(Theme.secondary)
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.circle")
                        .font(Theme.body).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("details-save-error")
                }
                Button("Delete task", role: .destructive) { confirmDelete = true }
                    .buttonStyle(PillStyle()).disabled(readOnly)
                    .confirmationDialog("Delete this task?", isPresented: $confirmDelete) {
                        Button("Delete task", role: .destructive) { deleteTask() }
                        Button("Keep task", role: .cancel) {}
                    } message: {
                        Text("Any active focus session will stop and its elapsed time will be recorded.")
                    }
            }
            .padding(Theme.cardPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var footer: some View {
        HStack(spacing: Theme.gutter) {
            Text(readOnly ? "History" : (editor.hasChanges ? "Unsaved changes" : "Task details"))
                .font(Theme.meta).foregroundStyle(Theme.secondary).lineLimit(1)
            Spacer(minLength: Theme.gutter)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction).buttonStyle(PillStyle())
                .accessibilityIdentifier("details-cancel")
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction).buttonStyle(PillStyle(prominent: true))
                .disabled(readOnly || !errors.isEmpty)
                .accessibilityIdentifier("details-save")
        }
        .padding(Theme.cardPadding)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Theme.cardStroke).frame(height: 1) }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var schedule: some View {
        field("Scheduled day") {
            DateFieldEditor(
                field: "Schedule",
                draft: Binding(get: { editor.scheduledDate }, set: { selectDate($0) }),
                onCommit: nil, onCancel: nil
            )
            .disabled(editor.details.original.done)
            if editor.scheduledDate.entry == .none {
                Text("No scheduled day. Moving to Inbox also clears the reminder and stops repeating.")
                    .font(Theme.meta).foregroundStyle(Theme.secondary)
            }
        }
    }

    private var reminder: some View {
        field("Reminder", error: errors[.reminder]) {
            Toggle(
                "Set a reminder",
                isOn: Binding(
                    get: { editor.details.hasReminder },
                    set: { value in
                        if value {
                            let soon = store.engine.now().addingTimeInterval(3600)
                            let morning =
                                (try? store.engine.parseReminder("9:00 am", on: editor.details.day ?? store.today))
                                ?? soon
                            editor.setReminder(max(soon, morning), using: store.engine)
                        } else {
                            editor.setReminder(nil, using: store.engine)
                        }
                    })
            ).disabled(!editor.details.scheduled || editor.details.original.done)
            if editor.details.hasReminder {
                DatePicker(
                    "Remind at",
                    selection: Binding(
                        get: { editor.details.remindAt ?? store.engine.now().addingTimeInterval(3600) },
                        set: {
                            editor.setReminder($0, using: store.engine)
                        }), displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.field).disabled(editor.details.original.done)
                Text("Reminders use your planner’s day-reset hour. Moving the day keeps the reminder’s local time.")
                    .font(Theme.meta).foregroundStyle(Theme.secondary)
            } else {
                Text("None").font(Theme.meta).foregroundStyle(Theme.secondary)
            }
        }
    }

    private var deadline: some View {
        field("Deadline") {
            DateFieldEditor(field: "Deadline", draft: $editor.deadline, onCommit: nil, onCancel: nil)
        }
    }

    private var steps: some View {
        field("Steps", error: errors[.steps]) {
            ForEach($editor.details.steps) { $step in
                HStack {
                    Toggle(step.title, isOn: $step.done)
                    Spacer(minLength: Theme.gutter)
                    Button {
                        editor.details.steps.removeAll { $0.id == step.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }.buttonStyle(PillStyle()).accessibilityLabel("Remove step \(step.title)")
                }
            }
            HStack {
                TextField("Add a step", text: $newStep)
                    .textFieldStyle(.roundedBorder).focused($focusedField, equals: .newStep).onSubmit { addStep() }
                Button("Add") { addStep() }.buttonStyle(PillStyle())
                    .disabled(newStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func field<Content: View>(_ title: String, error: String? = nil, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: Theme.gutter) {
            Text(title).font(Theme.label).foregroundStyle(Theme.secondary)
            content()
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(Theme.meta).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectDate(_ value: DateFieldDraft) {
        do {
            try editor.setScheduledDate(value, using: store.engine)
            saveError = nil
        } catch { saveError = error.localizedDescription }
    }

    private func addStep() {
        let title = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        editor.details.steps.append(Subtask(title: title)); newStep = ""
    }

    private func save() {
        guard !readOnly, errors.isEmpty else { return }
        // Include a typed but not yet submitted step in the same transaction.
        if !newStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addStep() }
        guard editor.hasChanges else { dismiss(); return }
        if store.apply({ try editor.apply(using: $0) }) != nil {
            dismiss()
        } else {
            saveError = store.lastError?.localizedDescription ?? "Could not save. Your edits are still here; try again."
        }
    }

    private func deleteTask() {
        guard !readOnly else { return }
        if store.send(.delete(editor.details.original.id)) != nil {
            dismiss()
        } else {
            saveError = store.lastError?.localizedDescription ?? "Could not delete this task."
        }
    }
}
