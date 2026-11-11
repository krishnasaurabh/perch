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
            TaskDetailsEditor(task: task).id(taskID)
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
    @State private var draft: TaskDetailsDraft
    @State private var newStep = ""
    @State private var saveError: String?
    @State private var confirmDelete = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case title, notes, newStep }

    init(task: PlanTask) { _draft = State(initialValue: TaskDetailsDraft(task: task)) }

    private var readOnly: Bool { draft.original.day.map { $0 < store.today } ?? false }
    private var errors: [TaskDetailsField: String] {
        draft.errors(today: store.today, now: store.engine.now(), projects: store.planner.projects)
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
        .onAppear { if !readOnly { focusedField = .title } }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardPadding) {
                if readOnly {
                    Label(
                        "Earlier days are read-only. Your history and focus time stay unchanged.", systemImage: "lock"
                    )
                    .font(Theme.body).foregroundStyle(Theme.secondary)
                    Text(draft.title).font(Theme.heading).textSelection(.enabled)
                } else {
                    field("Title", error: errors[.title]) {
                        TextField("Task title", text: $draft.title)
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
                        Picker("Priority", selection: $draft.priority) {
                            ForEach(TaskPriority.allCases.reversed(), id: \.self) { priority in
                                Text(priority == .none ? "None" : priority.rawValue.capitalized).tag(priority)
                            }
                        }.labelsHidden().pickerStyle(.menu)
                    }
                    field("Project", error: errors[.project]) {
                        Picker("Project", selection: $draft.projectID) {
                            Text("None").tag(UUID?.none)
                            ForEach(store.planner.projects) { project in
                                Text(project.name).tag(Optional(project.id))
                            }
                            if let missing = draft.projectID,
                                !store.planner.projects.contains(where: { $0.id == missing })
                            {
                                Text("Unavailable project").tag(Optional(missing))
                            }
                        }.labelsHidden()
                    }
                    field("Repeat", error: errors[.recurrence]) {
                        TaskRecurrencePicker(draft: $draft.recurrence)
                        if !draft.scheduled {
                            Text("Choose a day before adding a repeat.").font(Theme.meta).foregroundStyle(
                                Theme.secondary)
                        }
                    }
                    field("Time limit", error: errors[.minutes]) {
                        Stepper(value: $draft.minutes, in: 0...720, step: 5) {
                            Text(draft.minutes == 0 ? "None" : "\(draft.minutes) min").monospacedDigit()
                        }.disabled(draft.original.done)
                    }
                    steps
                    field("Notes") {
                        TextEditor(text: $draft.notes)
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
                if let seconds = store.planner.tasks.first(where: { $0.id == draft.original.id })?.focusedSeconds,
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
            Text(readOnly ? "History" : (draft.hasChanges ? "Unsaved changes" : "Task details"))
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
        field("Scheduled day", error: errors[.day]) {
            Picker(
                "Scheduled day",
                selection: Binding(
                    get: { draft.scheduled },
                    set: { scheduled in
                        if scheduled { selectDay(store.today) } else { draft.moveToInbox() }
                    })
            ) {
                Text("Inbox").tag(false)
                Text("Choose date").tag(true)
            }.labelsHidden().pickerStyle(.segmented).disabled(draft.original.done)
            if draft.scheduled {
                DatePicker(
                    "Day",
                    selection: Binding(
                        get: { (draft.day ?? store.today).date(calendar: calendar) },
                        set: { selectDay(DayKey($0, calendar: calendar)) }),
                    in: store.today.date(calendar: calendar)..., displayedComponents: .date
                )
                .datePickerStyle(.field).disabled(draft.original.done)
                HStack {
                    Button("Today") { selectDay(store.today) }
                    Button("Tomorrow") { selectDay(store.today.adding(days: 1, calendar: calendar)) }
                }.buttonStyle(PillStyle()).disabled(draft.original.done)
            } else {
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
                    get: { draft.hasReminder },
                    set: { value in
                        draft.hasReminder = value
                        if value {
                            let soon = store.engine.now().addingTimeInterval(3600)
                            let morning =
                                (try? store.engine.parseReminder("9:00 am", on: draft.day ?? store.today)) ?? soon
                            draft.remindAt = max(soon, morning)
                            draft.day = store.dayKey(draft.remindAt!)
                        } else {
                            draft.remindAt = nil
                        }
                    })
            ).disabled(!draft.scheduled || draft.original.done)
            if draft.hasReminder {
                DatePicker(
                    "Remind at",
                    selection: Binding(
                        get: { draft.remindAt ?? store.engine.now().addingTimeInterval(3600) },
                        set: {
                            draft.remindAt = $0; draft.day = store.dayKey($0)
                        }), displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.field).disabled(draft.original.done)
                Text("Reminders use your planner’s day-reset hour. Moving the day keeps the reminder’s local time.")
                    .font(Theme.meta).foregroundStyle(Theme.secondary)
            } else {
                Text("None").font(Theme.meta).foregroundStyle(Theme.secondary)
            }
        }
    }

    private var deadline: some View {
        field("Deadline", error: errors[.deadline]) {
            Toggle(
                "Set a deadline",
                isOn: Binding(
                    get: { draft.hasDeadline },
                    set: { value in
                        draft.hasDeadline = value
                        draft.deadline = value ? (draft.day ?? store.today) : nil
                    }))
            if draft.hasDeadline {
                DatePicker(
                    "Due",
                    selection: Binding(
                        get: { (draft.deadline ?? store.today).date(calendar: calendar) },
                        set: { draft.deadline = DayKey($0, calendar: calendar) }), displayedComponents: .date
                )
                .datePickerStyle(.field)
            } else {
                Text("None").font(Theme.meta).foregroundStyle(Theme.secondary)
            }
        }
    }

    private var steps: some View {
        field("Steps", error: errors[.steps]) {
            ForEach($draft.steps) { $step in
                HStack {
                    Toggle(step.title, isOn: $step.done)
                    Spacer(minLength: Theme.gutter)
                    Button {
                        draft.steps.removeAll { $0.id == step.id }
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

    private func selectDay(_ day: DayKey) {
        do { try draft.selectDay(day, using: store.engine) } catch { saveError = error.localizedDescription }
    }

    private func addStep() {
        let title = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        draft.steps.append(Subtask(title: title)); newStep = ""
    }

    private func save() {
        guard !readOnly, errors.isEmpty else { return }
        // Include a typed but not yet submitted step in the same transaction.
        if !newStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addStep() }
        guard draft.hasChanges else { dismiss(); return }
        if store.apply({ try draft.apply(using: $0) }) != nil {
            dismiss()
        } else {
            saveError = store.lastError?.localizedDescription ?? "Could not save. Your edits are still here; try again."
        }
    }

    private func deleteTask() {
        guard !readOnly else { return }
        if store.send(.delete(draft.original.id)) != nil {
            dismiss()
        } else {
            saveError = store.lastError?.localizedDescription ?? "Could not delete this task."
        }
    }
}

private struct TaskRecurrencePicker: View {
    @Binding var draft: TaskRecurrenceDraft

    private var usesWeekdays: Bool { draft.frequency == .weekly || (draft.frequency == .custom && draft.unit == .week) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gutter) {
            Picker("Repeat frequency", selection: $draft.frequency) {
                ForEach(TaskRecurrenceDraft.Frequency.allCases, id: \.self) { frequency in
                    Text(frequency.rawValue).tag(frequency)
                }
            }.labelsHidden().accessibilityIdentifier("details-repeat")
            if draft.frequency == .custom {
                HStack {
                    Text("Every")
                    TextField("Interval", text: $draft.interval).textFieldStyle(.roundedBorder).frame(width: 58)
                        .accessibilityLabel("Repeat interval")
                    Picker("Unit", selection: $draft.unit) {
                        Text("days").tag(TaskRepeat.Unit.day)
                        Text("weeks").tag(TaskRepeat.Unit.week)
                        Text("months").tag(TaskRepeat.Unit.month)
                    }.labelsHidden()
                }
            }
            if usesWeekdays {
                Toggle("On specific weekdays", isOn: $draft.selectWeekdays)
                if draft.selectWeekdays {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], alignment: .leading) {
                        ForEach(1...7, id: \.self) { weekday in
                            Toggle(
                                Calendar.current.shortWeekdaySymbols[weekday - 1],
                                isOn: Binding(
                                    get: { draft.weekdays.contains(weekday) },
                                    set: { selected in
                                        if selected {
                                            draft.weekdays.insert(weekday)
                                        } else {
                                            draft.weekdays.remove(weekday)
                                        }
                                    })
                            )
                            .toggleStyle(.button)
                            .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
                        }
                    }
                }
            }
            if draft.frequency != .none {
                Toggle("Count from completion", isOn: $draft.fromCompletion)
                Text(
                    draft.fromCompletion
                        ? "The next copy is based on the day you finish." : "The next copy is based on the planned day."
                )
                .font(Theme.meta).foregroundStyle(Theme.secondary)
            } else {
                Text("No new copies. Existing planned copies stay in place.").font(Theme.meta).foregroundStyle(
                    Theme.secondary)
            }
        }
    }
}
