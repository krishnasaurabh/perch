import PlannerCore
import SwiftUI

/// Today's tasks with a quick-add composer (typing or voice), swipe to delete, drag to reorder.
struct TasksCard: View {
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @State private var tab: Tab = .active
    enum Tab: String, CaseIterable { case active = "Active", completed = "Completed" }

    var body: some View {
        let all = store.engine.tasks(on: .day(store.today))
        let shown = tab == .active ? all.filter { !$0.done } : all.filter(\.done)
        VStack(alignment: .leading, spacing: 8) {
            CardHeading("Today", symbol: "checklist", trailing: AnyView(
                HStack(spacing: 2) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Button(t.rawValue) { tab = t }.buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(tab == t ? Color.white.opacity(0.12) : .clear))
                            .foregroundStyle(tab == t ? Theme.text : Theme.tertiary)
                    }
                }))
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { t in
                        TaskRow(task: t)
                            .onDrag { NSItemProvider(object: t.id.uuidString as NSString) }
                            .onDrop(of: [.plainText], isTargeted: nil) { items in
                                reorder(items, before: t.id); return true
                            }
                    }
                    if shown.isEmpty { empty(all: all) }
                }
            }
            .scrollIndicators(.never)
            TaskComposer(day: .day(store.today), placeholder: "Add a task, e.g. call mom at 5pm !high")
        }
        .card()
    }

    @ViewBuilder func empty(all: [PlanTask]) -> some View {
        VStack(spacing: 4) {
            if tab == .active {
                Text(all.isEmpty ? "Nothing on today's list." : "All done for today.").font(.system(size: 12.5, weight: .semibold))
                Text(all.isEmpty ? "Type a task in the field below." : "Finished tasks are under Done.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            } else {
                Text("No finished tasks.").font(.system(size: 12.5, weight: .semibold))
                Text("Tasks you check off land here.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 22)
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
                    withAnimation(.spring(response: 0.3)) { offset = 0 }
                })
        }
    }

    private var row: some View {
        HStack(spacing: 9) {
            Button { toggle() } label: {
                ZStack {
                    Circle().strokeBorder(task.done ? Theme.done : (task.priority == .none ? Theme.tertiary : Theme.priority(task.priority)), lineWidth: 1.6)
                    if task.done { Circle().fill(Theme.done).padding(3); Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.black) }
                }
                .frame(width: 17, height: 17)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.done ? "Uncheck task" : "Check off task")

            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("Title", text: $draft, onCommit: commitRename)
                        .textFieldStyle(.plain).font(.system(size: 12.5))
                        .onExitCommand { editing = false }
                } else {
                    Text(task.title).font(.system(size: 12.5, weight: .medium))
                        .strikethrough(task.done, color: Theme.tertiary)
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
        .padding(.horizontal, 7).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { menu }
    }

    @ViewBuilder private var meta: some View {
        let bits = metaBits
        if !bits.isEmpty {
            HStack(spacing: 6) {
                ForEach(bits, id: \.text) { b in
                    HStack(spacing: 3) {
                        if let s = b.symbol { Image(systemName: s).font(.system(size: 8.5, weight: .semibold)) }
                        Text(b.text).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(b.color)
                }
            }
        }
    }

    private struct Bit { let symbol: String?; let text: String; let color: Color }

    private var metaBits: [Bit] {
        var out: [Bit] = []
        if let r = task.remindAt {
            let overdue = r < Date() && !task.done
            out.append(Bit(symbol: "bell", text: r.formatted(date: .omitted, time: .shortened), color: overdue ? Theme.danger : Theme.secondary))
        }
        if let p = store.engine.project(id: task.projectID) { out.append(Bit(symbol: nil, text: "#\(p.name)", color: Color(hex: p.colorHex))) }
        if let d = task.deadline {
            let late = d < store.today
            out.append(Bit(symbol: "flag", text: "due " + shortDay(d), color: late ? Theme.danger : Theme.accent))
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

    func toggle() {
        if task.done { store.apply { try $0.reopen(task.id.uuidString) } } else {
            if task.day == store.today { store.apply { try $0.complete(task.id.uuidString) } }
            else { store.updateTask(task.id) { $0.done = true; $0.completedAt = Date() } }
            Confetti.fire()
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
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondary)
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .lineLimit(1...4)
                .truncationMode(.tail)
                .focused($focused)
                .onSubmit(add)
            if !text.isEmpty, let preview = preview {
                Text(preview).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent).lineLimit(1)
            }
            VoiceButton { spoken in
                store.apply { try $0.addTasks([spoken], on: day) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(focused ? 0.10 : 0.06)))
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
        if let added = store.apply({ try $0.addTasks([t], on: day) }) {
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
                if listening {
                    Circle().fill(Theme.accent.opacity(0.25)).frame(width: 26, height: 26)
                        .scaleEffect(listening ? 1.25 : 1).animation(.easeInOut(duration: 0.6).repeatForever(), value: listening)
                }
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

enum Confetti {
    /// A small particle burst from the notch.
    static func fire() { NotificationCenter.default.post(name: .init("PerchConfetti"), object: nil) }
}
