import PlannerCore
import SwiftUI

/// Today's tasks with a quick-add composer (typing or voice), swipe to delete, drag to reorder. Sage card.
struct TasksCard: View {
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @State private var tab: Tab = .active
    enum Tab: String, CaseIterable { case active = "To do", completed = "Completed" }

    var body: some View {
        let all = store.engine.tasks(on: .day(store.today))
        let open = all.filter { !$0.done }, finished = all.filter(\.done)
        let shown = tab == .active ? open : finished
        VStack(alignment: .leading, spacing: 10) {
            CardHeading("Today's tasks", trailing: AnyView(
                SegmentPills(items: [(Tab.active, "To do \(open.count)"), (Tab.completed, "Completed \(finished.count)")], selection: $tab)))
            ScrollView {
                // A plain VStack (not Lazy) so a ticked row can fade out while the rows below slide up.
                VStack(spacing: 0) {
                    ForEach(shown) { t in
                        TaskRow(task: t)
                            .onDrag { NSItemProvider(object: t.id.uuidString as NSString) }
                            .onDrop(of: [.plainText], isTargeted: nil) { items in
                                reorder(items, before: t.id); return true
                            }
                            .transition(.opacity)
                        if t.id != shown.last?.id { RowDivider() }
                    }
                    if shown.isEmpty { empty(all: all) }
                }
                .motion(Motion.row, value: shown.map(\.id))
            }
            .scrollIndicators(.never)
            TaskComposer(day: .day(store.today), placeholder: "What would you like to do?")
        }
        .card(.tasks)
    }

    /// Task rows are separated by a dotted rule.
    private struct RowDivider: View {
        var body: some View {
            Line().stroke(Theme.tertiary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [1.5, 3]))
                .frame(height: 1).padding(.horizontal, 7)
        }
        private struct Line: Shape {
            func path(in r: CGRect) -> Path { Path { p in p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
        }
    }

    @ViewBuilder func empty(all: [PlanTask]) -> some View {
        if tab == .active {
            EmptyStateView(all.isEmpty ? "Start with one task." : "All clear for today.",
                           symbol: all.isEmpty ? "square.and.pencil" : "checkmark.circle")
        } else {
            EmptyStateView("Your finished tasks will land here.", symbol: "checkmark.circle")
        }
    }

    func reorder(_ items: [NSItemProvider], before target: UUID) {
        items.first?.loadObject(ofClass: NSString.self) { s, _ in
            guard let s = s as? String, let id = UUID(uuidString: s), id != target else { return }
            Task { @MainActor in store.apply { $0.reorder(id, before: target) } }
        }
    }
}

struct TaskRow: View {
    let task: PlanTask
    var compact = false
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @State private var hover = false
    @State private var editing = false
    @State private var draft = ""
    @State private var offset: CGFloat = 0
    /// Set the instant the circle is clicked, so the tick shows before the row leaves.
    @State private var ticked = false

    var body: some View {
        ZStack(alignment: .trailing) {
            // Swipe left to delete.
            if offset < -4 {
                Image(systemName: "trash.fill").foregroundStyle(.white).padding(.trailing, 12)
                    .frame(maxHeight: .infinity).frame(width: -offset).background(Theme.danger).clipShape(RoundedRectangle(cornerRadius: 9))
            }
            row
                .offset(x: offset)
                .gesture(DragGesture(minimumDistance: 18).onChanged { v in
                    if abs(v.translation.width) > abs(v.translation.height) { offset = min(0, v.translation.width) }
                }.onEnded { v in
                    if v.translation.width < -110 { delete() }
                    Motion.animate(Motion.row) { offset = 0 }
                })
        }
    }

    private var row: some View {
        HStack(spacing: 9) {
            Button { toggle() } label: {
                let on = task.done || ticked
                ZStack {
                    Circle().strokeBorder(on ? Theme.text : (task.priority == .high ? Theme.priority(.high) : Theme.secondary), lineWidth: 1.5)
                    Circle().fill(Theme.text).padding(2.5).scaleEffect(on ? 1 : 0.2).opacity(on ? 1 : 0)
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.sage)
                        .opacity(on ? 1 : 0)
                }
                .frame(width: 17, height: 17)
                .motion(Motion.tick, value: on)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.done ? "Uncheck task" : "Check off task")

            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("Title", text: $draft, onCommit: commitRename)
                        .textFieldStyle(.plain).font(.system(size: 12.5))
                        .onExitCommand { editing = false }
                } else {
                    Text(task.title).font(Theme.title)
                        .foregroundStyle(task.done ? Theme.tertiary : Theme.text)
                        .lineLimit(compact ? 1 : 2)
                        .onTapGesture(count: 2) { draft = task.title; editing = true }
                }
                if !compact { meta }
            }
            Spacer(minLength: 4)
            if hover && !task.done && task.day == store.today {
                GlassButton(symbol: "play.fill", help: "Focus on this", tint: Theme.accent, size: 22) {
                    store.apply { try $0.startTimer(task: task.id.uuidString, minutes: nil) }
                }
            }
            if hover {
                GlassButton(symbol: "ellipsis", help: "Details", size: 22) { model.detailsTaskID = task.id }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hover ? Theme.fill : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { menu }
    }

    @ViewBuilder private var meta: some View {
        let bits = metaBits
        if !bits.isEmpty {
            HStack(spacing: 10) {
                ForEach(bits, id: \.text) { b in
                    HStack(spacing: 3) {
                        if let s = b.symbol { Image(systemName: s).font(.system(size: 9, weight: .semibold)) }
                        Text(b.text).font(.system(size: 10.5, weight: b.strong ? .bold : .medium))
                    }
                    .foregroundStyle(b.color)
                }
            }
        }
    }

    /// Meta chips use monochrome ink; emphasis is weight, and red only for late.
    private struct Bit {
        let symbol: String?; let text: String; let color: Color; var strong = false
    }

    private var metaBits: [Bit] {
        var out: [Bit] = []
        if task.priority == .high { out.append(Bit(symbol: "flag.fill", text: "High", color: Theme.secondary, strong: true)) }
        if let r = task.remindAt {
            let overdue = r < Date() && !task.done
            out.append(Bit(symbol: "bell", text: r.formatted(date: .omitted, time: .shortened), color: overdue ? Theme.danger : Theme.secondary))
        }
        if let p = store.engine.project(id: task.projectID) { out.append(Bit(symbol: "number", text: p.name, color: Theme.secondary)) }
        if let d = task.deadline {
            let late = d < store.today
            out.append(Bit(symbol: "flag", text: "due " + shortDay(d), color: late ? Theme.danger : Theme.secondary))
        }
        if let rule = task.repeatRule { out.append(Bit(symbol: "repeat", text: rule.description.replacingOccurrences(of: "every ", with: ""), color: Theme.secondary)) }
        if let m = task.minutes { out.append(Bit(symbol: "timer", text: "\(m)m", color: Theme.secondary)) }
        if !task.steps.isEmpty { out.append(Bit(symbol: "list.bullet", text: "\(task.steps.filter(\.done).count)/\(task.steps.count)", color: Theme.secondary)) }
        if let c = task.carriedFrom { out.append(Bit(symbol: "arrow.uturn.right", text: "from " + shortDay(c), color: Theme.tertiary)) }
        return out
    }

    func shortDay(_ d: DayKey) -> String { d.date().formatted(.dateTime.month(.abbreviated).day()) }

    @ViewBuilder private var menu: some View {
        if !task.done {
            Button("Start focusing") { store.apply { try $0.startTimer(task: task.id.uuidString, minutes: nil) } }
            Button("Set Time Limit…") { model.detailsTaskID = task.id }
            Divider()
            Button("Move to Tomorrow") { move(.day(store.today.adding(days: 1))) }
            Button("Move to Inbox") { move(.inbox) }
            if task.day != store.today { Button("Move to Today") { move(.day(store.today)) } }
            Divider()
            Menu("Priority") {
                ForEach(TaskPriority.allCases.reversed(), id: \.self) { p in
                    Button(p == .none ? "None" : p.rawValue.capitalized) { store.updateTask(task.id) { $0.priority = p } }
                }
            }
        }
        Button("Rename") { draft = task.title; editing = true }
        Button("Details…") { model.detailsTaskID = task.id }
        Divider()
        Button("Delete", role: .destructive) { delete() }
    }

    /// Tick: the circle fills at once, then the row fades in place while the rows below slide up (`Motion.row`).
    func toggle() {
        if task.done { Motion.animate(Motion.row) { _ = store.apply { try $0.reopen(task.id.uuidString) } }; return }
        ticked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.reduceMotion ? 0 : 0.14)) {
            Motion.animate(Motion.row) {
                if task.day == store.today { store.apply { try $0.complete(task.id.uuidString) } }
                else { store.updateTask(task.id) { $0.done = true; $0.completedAt = Date() } }
            }
            ticked = false
        }
    }

    func move(_ to: DayRef) {
        store.apply { try $0.move(task.id.uuidString, from: task.day.map { .day($0) } ?? .inbox, to: to) }
    }

    func delete() { store.apply { try $0.delete(task.id.uuidString, on: task.day.map { .day($0) } ?? .inbox) } }

    func commitRename() {
        editing = false
        guard draft != task.title else { return }
        store.apply { try $0.rename(task.id.uuidString, on: task.day.map { .day($0) } ?? .inbox, to: draft) }
    }
}

/// Text field + mic. Enter adds; multi-line paste adds one task per line.
struct TaskComposer: View {
    let day: DayRef
    var placeholder = "Add a task"
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var services: Services
    @EnvironmentObject var model: NotchModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondary)
            // Prompt drawn by Perch. AppKit draws a TextField's own placeholder in the system placeholder
            // colour (≈ 2.4:1 resting, 1.6:1 focused on the input fill) and ignores `prompt:` foreground styles on
            // macOS. `Theme.text` is the only ink token that clears 4.5:1 on both the 8 % and 12 % fill.
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(Theme.body)
                .lineLimit(1...4)
                .truncationMode(.tail)
                .background(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .focused($focused)
                .accessibilityLabel("Add a task")
                .accessibilityHint(placeholder)
                .accessibilityIdentifier("task-capture")
                .onSubmit(add)
            if !text.isEmpty, let preview = preview {
                Text(preview).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent).lineLimit(1)
            }
            VoiceButton { spoken in
                store.apply { try $0.addTasks([spoken], on: day) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(focused ? Theme.inputFillFocused : Theme.inputFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? Theme.accent.opacity(0.65) : .clear, lineWidth: 1.5))
        .task(id: model.captureFocusRequest) {
            // Explicit openings focus capture; hover and drag previews must not steal typing.
            focused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = model.captureFocusRequest != nil && model.expanded && model.page == .home
        }
    }

    /// Live hint of what the parser read: "Tomorrow 5:00 PM · High".
    var preview: String? {
        let c = TaskCapture().parse(text)
        var bits: [String] = []
        if c.inbox { bits.append("Inbox") }
        if let d = c.day, d != DayKey(Date()) { bits.append(d.date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) }
        if let r = c.remindAt { bits.append(r.formatted(date: .omitted, time: .shortened)) }
        if c.priority != .none { bits.append(c.priority.rawValue.capitalized) }
        if let p = c.projectName { bits.append("#" + p) }
        if let r = c.repeatRule { bits.append(r.description) }
        if let m = c.minutes { bits.append("\(m)m") }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    func add() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Insert is opacity only into reserved space; other rows stay put.
        if let added = Motion.animate(Motion.row, { store.apply({ try $0.addTasks([t], on: day) }) }) {
            text = ""
            AISorter.sort(added.map(\.id), store: store)
        }
        focused = true
    }
}

struct VoiceButton: View {
    let onText: (String) -> Void
    @EnvironmentObject var services: Services
    var body: some View { VoiceButtonBody(voice: services.voice, onText: onText) }
}

private struct VoiceButtonBody: View {
    @ObservedObject var voice: VoiceCapture
    let onText: (String) -> Void

    var body: some View {
        let listening = voice.state == .listening
        Button { voice.toggle(onFinish: onText) } label: {
            ZStack {
                // A static listening state: no perpetual pulse.
                if listening { Circle().fill(Theme.fillStrong).frame(width: 24, height: 24) }
                Image(systemName: listening ? "waveform" : "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(listening ? Theme.accent : Theme.secondary)
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help("Say a task. Speech is recognized on this Mac.")
        .popover(isPresented: Binding(get: { if case .error = voice.state { return true }; return false },
                                      set: { if !$0 { voice.state = .idle } })) {
            if case .error(let m) = voice.state { Text(m).font(.system(size: 12)).padding(12).frame(width: 260) }
        }
    }
}
