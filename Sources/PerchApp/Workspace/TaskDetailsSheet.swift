import PlannerCore
import SwiftUI

/// Everything about one task: title, day, reminder, deadline, priority, project, repeat, time limit, steps, notes.
struct TaskDetailsSheet: View {
    let taskID: UUID
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @Environment(\.dismiss) var dismiss
    @State private var newStep = ""
    @State private var repeatText = ""
    @FocusState private var textField: String?

    var body: some View {
        if let t = store.planner.tasks.first(where: { $0.id == taskID }) {
            let readOnly = (t.day.map { $0 < store.today }) ?? false
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField("Title", text: textBinding(.title(t.id))).textFieldStyle(.plain).font(
                        .system(size: 16, weight: .semibold)
                    )
                    .focused($textField, equals: "title").onSubmit { store.flushPendingText() }
                    Spacer()
                    Button("Done") { if store.flushPendingText() { dismiss() } }.keyboardShortcut(.defaultAction)
                }
                if readOnly {
                    Text("Older days stay unchanged in your history.").font(.caption).foregroundStyle(.secondary)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        label("Day")
                        HStack {
                            Text(t.day.map { $0.date().formatted(.dateTime.weekday(.wide).month().day()) } ?? "Inbox")
                            Spacer()
                            if !t.done && !readOnly {
                                Menu("Move") {
                                    Button("Today") { move(t, .day(store.today)) }
                                    Button("Tomorrow") { move(t, .day(store.today.adding(days: 1))) }
                                    Button("Next week") { move(t, .day(store.today.adding(days: 7))) }
                                    Button("Inbox") { move(t, .inbox) }
                                }.fixedSize()
                            }
                        }
                    }
                    GridRow {
                        label("Reminder")
                        HStack {
                            if let r = t.remindAt {
                                DatePicker(
                                    "",
                                    selection: Binding(
                                        get: { r },
                                        set: { v in
                                            store.updateTask(t.id) {
                                                $0.remindAt = v; $0.day = store.dayKey(v)
                                            }
                                        })
                                )
                                .labelsHidden()
                                Button("Remove") { store.updateTask(t.id) { $0.remindAt = nil } }
                            } else {
                                Button("Remind me") {
                                    let base = t.day?.date() ?? Date()
                                    let at = max(
                                        Date().addingTimeInterval(3600),
                                        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: base)!)
                                    store.updateTask(t.id) {
                                        $0.remindAt = at; $0.day = store.dayKey(at)
                                    }
                                }.disabled(t.day == nil || t.done)
                            }
                        }
                    }
                    GridRow {
                        label("Deadline")
                        HStack {
                            if let d = t.deadline {
                                DatePicker(
                                    "",
                                    selection: Binding(
                                        get: { d.date() },
                                        set: { v in store.updateTask(t.id) { $0.deadline = DayKey(v) } }),
                                    displayedComponents: .date
                                )
                                .labelsHidden()
                                Button("Remove") { store.updateTask(t.id) { $0.deadline = nil } }
                            } else {
                                Button("Add deadline") {
                                    store.updateTask(t.id) { $0.deadline = (t.day ?? store.today).adding(days: 2) }
                                }
                            }
                        }
                    }
                    GridRow {
                        label("Priority")
                        Picker("", selection: binding(\.priority, t)) {
                            ForEach(TaskPriority.allCases.reversed(), id: \.self) {
                                Text($0 == .none ? "None" : $0.rawValue.capitalized).tag($0)
                            }
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    GridRow {
                        label("Project")
                        Picker(
                            "",
                            selection: Binding(
                                get: { t.projectID }, set: { v in store.updateTask(t.id) { $0.projectID = v } })
                        ) {
                            Text("None").tag(UUID?.none)
                            ForEach(store.planner.projects) { p in Text("#\(p.name)").tag(UUID?.some(p.id)) }
                        }.labelsHidden().fixedSize()
                    }
                    GridRow {
                        label("Repeat")
                        HStack {
                            TextField("e.g. every mon, wed", text: $repeatText).textFieldStyle(.roundedBorder)
                                .onSubmit { applyRepeat(t) }
                            Button("Set") { applyRepeat(t) }.disabled(t.day == nil)
                            if t.repeatRule != nil {
                                Button("Stop repeating") { stopRepeating(t) }
                                    .help("Keeps this task and copies already planned. No new copies are made.")
                            }
                        }
                    }
                    GridRow {
                        label("Time limit")
                        Stepper(
                            value: Binding(
                                get: { t.minutes ?? 0 },
                                set: { v in store.updateTask(t.id) { $0.minutes = v == 0 ? nil : v } }), in: 0...720,
                            step: 5
                        ) {
                            Text(t.minutes.map { "\($0) min" } ?? "None").monospacedDigit()
                        }
                    }
                }
                .disabled(readOnly)

                VStack(alignment: .leading, spacing: 6) {
                    label("Steps")
                    ForEach(t.steps) { s in
                        HStack {
                            Toggle(
                                isOn: Binding(
                                    get: { s.done },
                                    set: { v in
                                        store.updateTask(t.id) { tt in
                                            if let i = tt.steps.firstIndex(where: { $0.id == s.id }) {
                                                tt.steps[i].done = v
                                            }
                                        }
                                    })
                            ) { Text(s.title).strikethrough(s.done) }
                            Spacer()
                            Button {
                                store.updateTask(t.id) { $0.steps.removeAll { $0.id == s.id } }
                            } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.plain)
                        }
                    }
                    TextField("Add a step", text: $newStep).textFieldStyle(.roundedBorder).onSubmit {
                        let s = newStep.trimmingCharacters(in: .whitespaces)
                        guard !s.isEmpty else { return }
                        store.updateTask(t.id) { $0.steps.append(Subtask(title: s)) }
                        newStep = ""
                    }
                }
                .disabled(readOnly)

                VStack(alignment: .leading, spacing: 6) {
                    label("Notes")
                    TextEditor(text: textBinding(.notes(t.id))).font(.system(size: 12.5)).frame(minHeight: 70)
                        .focused($textField, equals: "notes")
                        .scrollContentBackground(.hidden).padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                }
                .disabled(readOnly)

                HStack {
                    if t.focusedSeconds > 0 {
                        Text("Focused \(TimerText.short(t.focusedSeconds))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete Task", role: .destructive) {
                        store.apply { try $0.delete(t.id.uuidString, on: t.day.map { .day($0) } ?? .inbox) }
                        dismiss()
                    }.disabled(readOnly)
                }
            }
            .padding(20)
            .frame(width: 460)
            .onAppear { repeatText = t.repeatRule?.description ?? "" }
            .onChange(of: textField) { _, _ in store.flushPendingText() }
            .onDisappear { store.flushPendingText() }
        } else {
            Text("This task was removed.").padding(30).onAppear { dismiss() }
        }
    }

    func label(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).frame(
            width: 74, alignment: .leading)
    }

    func textBinding(_ target: PlannerStore.TextTarget) -> Binding<String> {
        Binding(get: { store.text(for: target) }, set: { store.setText($0, for: target) })
    }

    func binding<V>(_ kp: WritableKeyPath<PlanTask, V>, _ t: PlanTask) -> Binding<V> {
        Binding(
            get: { store.planner.tasks.first { $0.id == t.id }?[keyPath: kp] ?? t[keyPath: kp] },
            set: { v in store.updateTask(t.id) { $0[keyPath: kp] = v } })
    }

    func move(_ t: PlanTask, _ to: DayRef) {
        store.apply { try $0.move(t.id.uuidString, from: t.day.map { .day($0) } ?? .inbox, to: to) }
    }

    func stopRepeating(_ t: PlanTask) {
        if store.apply({ try $0.endRepeat(of: t.id) }) != nil { repeatText = "" }
    }

    func applyRepeat(_ t: PlanTask) {
        var e = TaskEdit(); e.repeatRule = repeatText.isEmpty ? "none" : repeatText
        if store.apply({ try $0.update(t.id.uuidString, on: t.day.map { .day($0) } ?? .inbox, e) }) != nil {
            repeatText = store.planner.tasks.first { $0.id == t.id }?.repeatRule?.description ?? ""
        }
    }
}
