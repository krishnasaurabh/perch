import PlannerCore
import PerchUI
import SwiftUI

/// Today reserves capture and Undo below its independently scrolling task viewport.
struct TasksCard: View {
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @State private var tab: TodayTab = .active
    @State private var reviewingOverdue = false
    @FocusState private var focus: TodayFocus?
    @State private var lastFocusedTask: UUID?

    var body: some View {
        let all = store.engine.tasks(on: .day(store.today))
        let open = all.filter { !$0.done }, finished = all.filter(\.done)
        let selection = Binding(
            get: { TodayTabs.resolved(tab, completedCount: finished.count) },
            set: { tab = $0 })
        let shown = selection.wrappedValue == .active ? open : finished
        let ids = shown.map(\.id)
        let pills = TodayTabs.visible(completedCount: finished.count).map {
            (
                $0,
                $0 == .active
                    ? AppL10n.format("To do %lld", open.count)
                    : AppL10n.format("Completed %lld", finished.count)
            )
        }
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                CardHeading(
                    "Today's tasks",
                    trailing: AnyView(
                        HStack(spacing: 8) {
                            startFocus
                            SegmentPills(items: pills, selection: selection)
                        }.fixedSize())
                )
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    CardHeading("Today's tasks", trailing: AnyView(startFocus))
                    SegmentPills(items: pills, selection: selection)
                }
            }
            GeometryReader { viewport in
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(shown) { task in
                                TaskRow(task: task, focus: $focus)
                                    .id(task.id)
                                    .onDrag { NSItemProvider(object: task.id.uuidString as NSString) }
                                    .onDrop(of: [.plainText], isTargeted: nil) { items in
                                        reorder(items, before: task.id); return true
                                    }
                                    .transition(.opacity)
                                if task.id != shown.last?.id { Divider().padding(.horizontal, 7) }
                            }
                            if shown.isEmpty {
                                EmptyStateView(
                                    all.isEmpty ? "Start with one task." : "All clear for today.",
                                    symbol: all.isEmpty ? "square.and.pencil" : "checkmark.circle")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: shown.isEmpty ? viewport.size.height : 0, alignment: .bottom)
                        .motion(Motion.row, value: ids)
                        .background(TasksContinuationObserver())
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: focus) { _, value in
                        if let id = value?.taskID { scroll.scrollTo(id) }
                    }
                }
            }
            .frame(minHeight: 0)
            TaskComposer(day: .day(store.today), placeholder: "What would you like to do?", focus: $focus)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            footer.fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }
        .card(.tasks)
        .onChange(of: finished.count, initial: true) { _, count in
            tab = TodayTabs.resolved(tab, completedCount: count)
        }
        .onChange(of: focus) { _, value in
            if let id = value?.taskID { lastFocusedTask = id } else if value == .capture { lastFocusedTask = nil }
        }
        .onChange(of: ids) { previous, remaining in
            // Row recovery must not override an explicit capture or Undo destination.
            guard focus != .capture && focus != .undo else { return }
            // SwiftUI may clear native focus as the row leaves, before this callback.
            guard let id = focus?.taskID ?? lastFocusedTask, previous.contains(id), !remaining.contains(id) else {
                return
            }
            focus =
                TodayTaskNavigation.afterRemoval(of: id, previous: previous, remaining: remaining)
                .map { .task($0, .complete) } ?? (store.canUndo ? .undo : .capture)
        }
        .onKeyPress(.upArrow) { navigate(ids, offset: -1) }
        .onKeyPress(.downArrow) { navigate(ids, offset: 1) }
        .popover(isPresented: $reviewingOverdue) {
            OverdueReview().environmentObject(store).frame(width: 340).padding(14)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                store.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(PillStyle(disabledReason: "There is no task edit to undo."))
            .disabled(!store.canUndo)
            .focusable(store.canUndo)
            .focused($focus, equals: .undo)
            .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
                guard focus == .undo, store.canUndo, press.modifiers.isEmpty else { return .ignored }
                if press.phase == .down { store.undo() }
                return .handled
            }
            .focusEffectDisabled()
            .overlay(ControlFocusRing(shape: Capsule(), focused: focus == .undo))
            .accessibilityIdentifier("today-undo")
            .help("Undo the last edit, including task deletion (Command-Z)")
            Spacer(minLength: 0)
            if !store.engine.overdue().isEmpty {
                Button(AppL10n.format("Review overdue (%lld)", store.engine.overdue().count)) {
                    reviewingOverdue = true
                }
                .buttonStyle(PillStyle())
                .accessibilityIdentifier("today-review-overdue")
            }
        }
    }

    @ViewBuilder private var startFocus: some View {
        if store.planner.focus.map({ $0.state == .running || $0.state == .paused }) != true {
            Button {
                guard store.planner.focus.map({ $0.state == .running || $0.state == .paused }) != true else { return }
                store.apply { try $0.startTimer(task: nil, minutes: nil) }
            } label: {
                Label("Start focus", systemImage: "play.fill").font(Theme.label).fixedSize()
            }
            .buttonStyle(PillStyle())
            .accessibilityLabel("Start focus")
            .accessibilityHint("Starts a focus session using your default duration")
            .accessibilityIdentifier("today-start-focus")
        }
    }

    private func navigate(_ ids: [UUID], offset: Int) -> KeyPress.Result {
        guard case .task(let id, let action) = focus, action != .rename,
            let next = TodayTaskNavigation.neighbor(in: ids, from: id, offset: offset)
        else { return .ignored }
        focus = .task(next, .complete)
        return .handled
    }

    private func reorder(_ items: [NSItemProvider], before target: UUID) {
        items.first?.loadObject(ofClass: NSString.self) { value, _ in
            guard let string = value as? String, let id = UUID(uuidString: string), id != target else { return }
            Task { @MainActor in store.apply { try $0.reorder(id, before: target) } }
        }
    }
}

/// Review is opt-in; automatic carry behavior remains a Settings preference.
private struct OverdueReview: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let tasks = store.engine.overdue()
        VStack(alignment: .leading, spacing: 12) {
            Text("Unfinished from earlier days").font(Theme.heading)
            Text("Choose what to do with these tasks. Automatic handling can be changed in Settings.")
                .font(Theme.body).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tasks) { task in
                        Text(task.title).font(Theme.body).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 160)
            Button("Bring all to today") { resolve { try $0.carryForward(tasks.map(\.id), to: $0.today) } }
                .buttonStyle(PillStyle())
            Button("Mark all done") { resolve { try $0.completeOverdue(tasks.map(\.id)) } }.buttonStyle(PillStyle())
            Button("Leave all in history") { resolve { try $0.dismissOverdue(tasks.map(\.id)) } }.buttonStyle(
                PillStyle())
            Button("Cancel") { dismiss() }.buttonStyle(PillStyle()).keyboardShortcut(.cancelAction)
        }
    }

    private func resolve(_ action: (PlannerCommands) throws -> Void) {
        if store.apply(action) != nil { dismiss() }
    }
}

/// Observe the native viewport without changing the SwiftUI list's size or scroll insets.
/// The existing AppKit fade draws over hosted rows and never intercepts their clicks.
private struct TasksContinuationObserver: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.attach() }

    final class Marker: NSView {
        private weak var scroll: NSScrollView?
        private let fade = OverflowFadeView(frame: .zero)

        override init(frame: NSRect) {
            super.init(frame: frame)
            fade.identifier = NSUserInterfaceItemIdentifier("today-continuation-fade")
            fade.color = NSColor(CardTone.tasks.fill)
            fade.isHidden = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        override func layout() { super.layout(); attach() }
        deinit { NotificationCenter.default.removeObserver(self) }

        func attach() {
            guard let enclosing = enclosingScrollView else { return }
            if scroll !== enclosing {
                NotificationCenter.default.removeObserver(self)
                fade.removeFromSuperview()
                scroll = enclosing
                enclosing.addSubview(fade, positioned: .above, relativeTo: nil)
                let clip = enclosing.contentView
                clip.postsBoundsChangedNotifications = true
                clip.postsFrameChangedNotifications = true
                enclosing.documentView?.postsFrameChangedNotifications = true
                for (name, view) in [
                    (NSView.boundsDidChangeNotification, clip),
                    (NSView.frameDidChangeNotification, clip),
                    (NSView.frameDidChangeNotification, enclosing.documentView),
                ] {
                    if let view {
                        NotificationCenter.default.addObserver(
                            self, selector: #selector(refresh), name: name, object: view)
                    }
                }
            }
            refresh()
        }

        @objc private func refresh() {
            guard let scroll, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            let viewport = scroll.convert(clip.bounds, from: clip)
            let height = min(CGFloat(20), viewport.height)
            fade.frame = NSRect(
                x: viewport.minX, y: scroll.isFlipped ? viewport.maxY - height : viewport.minY,
                width: viewport.width, height: height)
            let visible = document.convert(clip.bounds, from: clip)
            let offset = document.isFlipped ? visible.minY - document.bounds.minY : document.bounds.maxY - visible.maxY
            fade.isHidden = !EdgeFade.showsBottomFade(
                contentHeight: Double(document.bounds.height),
                visibleOffset: Double(offset), visibleHeight: Double(visible.height))
        }
    }
}

/// Text field + mic. Enter adds; multi-line paste adds one task per line.
struct TaskComposer: View {
    let day: DayRef
    var placeholder = "Add a task"
    var focus: FocusState<TodayFocus?>.Binding? = nil
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var services: Services
    @EnvironmentObject var model: NotchModel
    @State private var text = ""
    @FocusState private var localFocus: TodayFocus?
    private var focusBinding: FocusState<TodayFocus?>.Binding { focus ?? $localFocus }
    private var focused: Bool { focusBinding.wrappedValue == .capture }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            captureField
            if !text.isEmpty, let preview {
                Text(preview).font(Theme.meta).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Task options: \(preview)")
            }
        }
    }

    private var captureField: some View {
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
                        Text(AppL10n.text(placeholder)).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .focused(focusBinding, equals: .capture)
                .accessibilityLabel("Add a task")
                .accessibilityHint(AppL10n.text(placeholder))
                .accessibilityIdentifier("task-capture")
                .onSubmit(add)
                .background(CaptureTextUndo())
            VoiceButton { spoken in
                store.addTasks([spoken], on: day)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(
                focused ? Theme.inputFillFocused : Theme.inputFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.inputStroke, lineWidth: focused ? 2 : 1)
        )
        .task(id: model.captureFocusRequest) {
            // Only explicit openings request focus; hover and drag previews do not steal typing.
            guard model.captureFocusRequest != nil && model.expanded && model.page == .home else {
                if focused { focusBinding.wrappedValue = nil }
                return
            }
            // Closing a panel can end native editing without clearing SwiftUI's focus value.
            // A new explicit request must reacquire the editor even if capture was last focused.
            focusBinding.wrappedValue = nil
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusBinding.wrappedValue = .capture
        }
        .overlay(ControlFocusRing(shape: RoundedRectangle(cornerRadius: 10), focused: focused))
        .help(preview ?? AppL10n.text("Return adds a task. Paste multiple lines to add multiple tasks."))
    }

    /// Live hint of what the parser read: "Tomorrow 5:00 PM · High".
    var preview: String? {
        guard let language = TaskParserLanguage.current else { return nil }
        let c = store.capture.parse(text, language: language)
        var bits: [String] = []
        if c.inbox { bits.append(AppL10n.text("Inbox")) }
        if let d = c.day, d != store.today {
            bits.append(d.date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
        }
        if let r = c.remindAt { bits.append(r.formatted(date: .omitted, time: .shortened)) }
        if c.priority != .none { bits.append(AppL10n.text(c.priority.rawValue.capitalized)) }
        if let p = c.projectName { bits.append("#" + p) }
        if let r = c.repeatRule {
            bits.append(RepeatPickerDraft(original: r, anchor: c.day).summary())
        }
        if let m = c.minutes { bits.append(AppL10n.format("%lldm", m)) }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    func add() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Insert is opacity only into reserved space; other rows stay put.
        if let added = Motion.animate(Motion.row, { store.addTasks([t], on: day) }) {
            text = ""
            AISorter.sort(added.map(\.id), store: store)
        }
        focusBinding.wrappedValue = .capture
    }
}

/// Capture keeps working when the accessory panel has no application Edit menu.
/// Its native text history remains separate from the planner's command history.
struct CaptureTextUndo: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.enableUndo() }
    static func dismantleNSView(_ view: Marker, coordinator: ()) { view.stop() }

    final class Marker: NSView {
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            for name in [NSText.didBeginEditingNotification, NSControl.textDidBeginEditingNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(editingBegan), name: name, object: nil)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // AppKit invokes local monitors on main; only the consumption decision crosses
                // the isolation check. NSEvent itself must remain in the synchronous callback.
                let consumed: Bool = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event) == nil
                }
                return consumed ? nil : event
            }
            enableUndo()
        }
        override func layout() { super.layout(); enableUndo() }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            NotificationCenter.default.removeObserver(self)
        }

        // The background occupies only this capture field. A shared field editor
        // must currently belong to that actual field, not another control/window.
        private var editor: NSTextView? {
            guard let window, let editor = window.firstResponder as? NSTextView,
                editor.isFieldEditor, let field = editor.delegate as? NSTextField,
                field.window === window, field.currentEditor() === editor,
                !isHiddenOrHasHiddenAncestor, field.isEditable,
                !bounds.isEmpty, bounds.intersects(convert(field.bounds, from: field))
            else { return nil }
            return editor
        }

        @objc private func editingBegan(_ notification: Notification) { enableUndo() }
        func enableUndo() { editor?.allowsUndo = true }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window, window?.isKeyWindow == true, let editor else { return event }
            editor.allowsUndo = true
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard event.charactersIgnoringModifiers?.lowercased() == "z",
                flags == .command || flags == [.command, .shift]
            else { return event }
            // Consume empty history and held-key repeats too: neither may reach planner Undo.
            guard !event.isARepeat, let manager = editor.undoManager else { return nil }
            editor.breakUndoCoalescing()
            if flags.contains(.shift) {
                if manager.canRedo { manager.redo() }
            } else if manager.canUndo {
                manager.undo()
            }
            return nil
        }
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
        Button {
            voice.toggle(onFinish: onText)
        } label: {
            ZStack {
                // A static listening state: no perpetual pulse.
                if listening { Circle().fill(Theme.fillStrong).frame(width: 24, height: 24) }
                Image(systemName: listening ? "waveform" : "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(listening ? Theme.accent : Theme.secondary)
            }
            .frame(width: Theme.minimumTarget, height: Theme.minimumTarget)
        }
        .buttonStyle(PillStyle())
        .accessibilityLabel(listening ? "Stop dictation" : "Dictate a task")
        .help("Say a task. Speech is recognized on this Mac.")
        .popover(
            isPresented: Binding(
                get: {
                    if case .error = voice.state { return true }; return false
                },
                set: { if !$0 { voice.state = .idle } })
        ) {
            if case .error(let m) = voice.state { Text(m).font(.system(size: 12)).padding(12).frame(width: 260) }
        }
    }
}
