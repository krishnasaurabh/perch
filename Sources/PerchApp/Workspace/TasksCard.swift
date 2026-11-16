import AppKit
import PlannerCore
import PerchUI
import SwiftUI

/// The list scrolls independently; capture and Undo never leave the card.
struct TasksCard: View {
    var preview: ChecklistPreviewState = .none
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @Environment(TodayHomeState.self) private var sharedHomeState: TodayHomeState?
    @State private var localHomeState = TodayHomeState()
    @State private var expandedTasks: Set<UUID> = []
    @State private var showsLater = false
    @State private var foldSelected = false
    @State private var selectedStepID: UUID?
    @State private var reviewingOverdue = false
    @FocusState private var focus: TodayFocus?

    private var homeState: TodayHomeState { sharedHomeState ?? localHomeState }
    private var currentID: UUID? {
        guard let current = store.planner.focus, current.state == .running || current.state == .paused else {
            return nil
        }
        return current.taskID
    }
    private var ordered: [PlanTask] {
        TodayTaskNavigation.ordered(store.engine.tasks(on: .day(store.today)), currentID: currentID)
    }

    var body: some View {
        let tasks = ordered
        let ids = tasks.map(\.id)
        let selectedSteps = tasks.first { $0.id == homeState.selectedTaskID }?.steps.map(\.id) ?? []
        let shown = TodayTaskNavigation.visible(tasks, expanded: showsLater, selectedID: homeState.selectedTaskID)
        let remaining = tasks.count - shown.count
        VStack(alignment: .leading, spacing: Theme.Size.cardPadding.value / 2) {
            HStack {
                Text("Today").perchFont(.cardTitle)
                Spacer(minLength: .zero)
                PerchPill(
                    countTitle(tasks), surface: tasks.contains(where: \.done) ? .mint : .field,
                    ink: tasks.contains(where: \.done) ? .doneText : .ink2)
            }
            GeometryReader { viewport in
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Size.focusGap.value) {
                            ForEach(shown) { task in
                                TaskRow(
                                    task: task, current: task.id == currentID,
                                    selected: homeState.selectedTaskID == task.id,
                                    keyboardFocused: focus == .checklist && !foldSelected, inChecklist: true,
                                    selectedStepID: selectedStepID,
                                    expanded: Binding(
                                        get: { expandedTasks.contains(task.id) },
                                        set: { value in
                                            if value {
                                                expandedTasks.insert(task.id)
                                            } else {
                                                expandedTasks.remove(task.id)
                                            }
                                        }), onSelect: { select(task.id) }, onEdit: { edit(task.id) }
                                )
                                .id(task.id)
                                .dropDestination(for: TaskDragItem.self) { items, _ in
                                    guard let item = items.first, item.taskID != task.id,
                                        ordered.contains(where: { $0.id == item.taskID && !$0.done }),
                                        !task.done, item.taskID != currentID, task.id != currentID
                                    else { return false }
                                    return store.apply { try $0.reorder(item.taskID, before: task.id) } != nil
                                }
                            }
                            if tasks.count > TodayTaskNavigation.foldedRowCount {
                                Button {
                                    toggleFold(tasks)
                                } label: {
                                    Text(
                                        remaining > 0
                                            ? AppL10n.format("%lld more for later today", remaining)
                                            : AppL10n.text("Show less"))
                                }
                                .buttonStyle(.plain).perchFont(.detailStrong).foregroundStyle(Theme.brandText)
                                .frame(minHeight: Theme.Size.minimumTarget.value).focusable(false)
                                .overlay(
                                    FocusRing(
                                        shape: Capsule(), focused: focus == .checklist && foldSelected, surface: .paper)
                                )
                                .accessibilityAddTraits(foldSelected ? .isSelected : [])
                                .accessibilityIdentifier(remaining > 0 ? "today-show-later" : "today-show-less")
                                .id("today-fold")
                            }
                            if tasks.isEmpty {
                                Text("What has to happen today?").perchFont(.body).foregroundStyle(Theme.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .topLeading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(Theme.paper)
                    }
                    .scrollIndicators(.automatic)
                    .background {
                        TasksContinuationObserver().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .overlay {
                        // The native key view is also the semantic group. No SwiftUI
                        // KeyViewProxy or individual row owns a second checklist stop.
                        ChecklistKeyTarget(
                            onKey: { handle($0, tasks: tasks) },
                            onTab: { backwards in
                                guard !backwards, store.canUndo else { return false }
                                focus = .undo
                                return true
                            }
                        )
                        .focusable(!tasks.isEmpty)
                        .focused($focus, equals: .checklist)
                        .accessibilityIdentifier("today-checklist")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .onChange(of: homeState.selectedTaskID) { _, id in
                        selectedStepID = nil
                        if let id, !foldSelected { scroll.scrollTo(id) }
                    }
                    .onChange(of: selectedStepID) { _, id in
                        ChecklistStepScroll.reveal(id) { scroll.scrollTo($0, anchor: $1) }
                    }
                    .onChange(of: ids) { _, remaining in
                        guard focus == .checklist, !foldSelected,
                            let id = homeState.selectedTaskID, remaining.contains(id)
                        else { return }
                        scroll.scrollTo(selectedStepID ?? id, anchor: .center)
                    }
                    .onChange(of: foldSelected) { _, selected in
                        if selected { scroll.scrollTo("today-fold") }
                    }
                    .onChange(of: showsLater) { _, _ in
                        if foldSelected { scroll.scrollTo("today-fold") }
                    }
                }
                // One stable local keyboard destination for every edit. Its
                // contents consume viewport space without moving pinned capture.
                .safeAreaInset(edge: .bottom, spacing: 8) {
                    footer.modifier(NotchUndoFooter())
                }
            }
            .frame(minHeight: 0, maxHeight: WorkspaceLayout.contentHeight)
            // Keep the bounded scroller in a flexible slot so header changes consume slack,
            // rather than resizing a centered card and moving capture with it.
            .frame(maxHeight: .infinity, alignment: .top)
            // The observer publishes today-task-viewport on the native scroller,
            // not this container, which would override the checklist group identity.
            Spacer(minLength: .zero).layoutPriority(-1)
            TaskComposer(
                day: .day(store.today), placeholder: "Add a task. Tab makes it a step.", focus: $focus,
                homeState: homeState, initialStep: preview == .stepEntry,
                initialText: preview == .multiline ? "Call Sam at 1:30 PM\nWrite notes for 20 min" : nil,
                onStep: {
                    expandedTasks.insert($0); showsLater = true
                }
            )
            .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            overdueFooter.fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }
        .card(.tasks, padding: Theme.Size.cardPadding.value)
        .onAppear {
            #if DEBUG || PERCH_TESTING
                if preview == .expanded { showsLater = true }
                if preview == .steps { expandedTasks = Set(tasks.map(\.id)); showsLater = true }
                if preview == .selected { homeState.selectedTaskID = tasks.first?.id; focus = .checklist }
            #endif
        }
        .onChange(of: focus) { _, value in
            if value == .checklist && !ids.contains(homeState.selectedTaskID ?? UUID()) {
                homeState.selectedTaskID = ids.first
            }
        }
        .onChange(of: selectedSteps) { _, remaining in
            if let selectedStepID, !remaining.contains(selectedStepID) { self.selectedStepID = nil }
        }
        .onChange(of: ids) { previous, remaining in
            if remaining.count <= TodayTaskNavigation.foldedRowCount { foldSelected = false }
            guard let selected = homeState.selectedTaskID, !remaining.contains(selected) else { return }
            homeState.selectedTaskID = TodayTaskNavigation.afterRemoval(
                of: selected, previous: previous, remaining: remaining)
            selectedStepID = nil
            if focus == .checklist && remaining.isEmpty { focus = store.canUndo ? .undo : .capture }
        }
        .popover(isPresented: $reviewingOverdue) {
            OverdueReview().environmentObject(store).frame(width: Theme.Size.peekWidth.value).padding(
                Theme.Size.cardPadding.value)
        }
    }

    private func countTitle(_ tasks: [PlanTask]) -> String {
        guard !tasks.isEmpty else { return AppL10n.text("A fresh page") }
        let done = tasks.filter(\.done).count
        return done == 0
            ? AppL10n.format("%lld to do", tasks.count) : AppL10n.format("%lld of %lld done", done, tasks.count)
    }

    // The viewport keeps its destination mounted across every strip presentation.
    private var showsFooterUndo: Bool {
        store.canUndo
    }

    private var footer: some View {
        HStack(spacing: Theme.Size.cardPadding.value / 2) {
            Button {
                store.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.plain).perchFont(.detailStrong).foregroundStyle(Theme.secondary)
            .frame(minHeight: Theme.Size.minimumTarget.value)
            .disabled(!showsFooterUndo).focusable(store.canUndo).focused($focus, equals: .undo)
            .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
                guard focus == .undo, store.canUndo, press.modifiers.isEmpty else { return .ignored }
                if press.phase == .down { store.undo() }
                return .handled
            }
            .focusEffectDisabled()
            .overlay(FocusRing(shape: Capsule(), focused: focus == .undo, surface: .paper))
            .accessibilityIdentifier("today-undo")
            .help("Undo the last edit, including task deletion (Command-Z)")
            Spacer(minLength: .zero)
        }
    }

    @ViewBuilder private var overdueFooter: some View {
        if !store.engine.bringOverCandidates().isEmpty {
            Button("Bring over") { reviewingOverdue = true }
                .buttonStyle(.plain).perchFont(.detailStrong).foregroundStyle(Theme.secondary)
                .frame(minHeight: Theme.Size.minimumTarget.value)
                .accessibilityIdentifier("today-review-overdue")
        }
    }

    private func select(_ id: UUID) {
        foldSelected = false; homeState.selectedTaskID = id; selectedStepID = nil; focus = .checklist
    }

    private func toggleFold(_ tasks: [PlanTask]) {
        showsLater = !TodayTaskNavigation.isExpanded(tasks, expanded: showsLater, selectedID: homeState.selectedTaskID)
        foldSelected = true; selectedStepID = nil; focus = .checklist
        if !showsLater { homeState.selectedTaskID = tasks.first?.id }
    }

    private func moveChecklist(_ tasks: [PlanTask], offset: Int) {
        guard let id = homeState.selectedTaskID else { return }
        let current: TodayTaskNavigation.Destination = foldSelected ? .fold : .task(id)
        let expanded = TodayTaskNavigation.isExpanded(tasks, expanded: showsLater, selectedID: homeState.selectedTaskID)
        switch TodayTaskNavigation.move(in: tasks.map(\.id), from: current, offset: offset, expanded: expanded) {
        case .fold:
            foldSelected = true; selectedStepID = nil
        case .task(let next):
            if tasks.dropFirst(TodayTaskNavigation.foldedRowCount).contains(where: { $0.id == next }) {
                showsLater = true
            }
            select(next)
        case nil: break
        }
    }
    private func edit(_ id: UUID) { homeState.selectedTaskID = id; homeState.editingTaskID = id }

    private func handle(_ press: ChecklistKeyPress, tasks: [PlanTask]) -> KeyPress.Result {
        guard focus == .checklist else { return .ignored }
        let modifiers = press.modifiers.intersection([.command, .control, .option, .shift])
        let plain = modifiers.isEmpty
        let arrow = press.key == .upArrow || press.key == .downArrow
        if foldSelected {
            guard plain, arrow || press.key == .space || press.key == .return else { return .ignored }
            guard press.phase == .down else { return .handled }
            if arrow {
                moveChecklist(tasks, offset: press.key == .upArrow ? -1 : 1)
            } else {
                toggleFold(tasks)
            }
            return .handled
        }
        guard let id = homeState.selectedTaskID, let task = tasks.first(where: { $0.id == id }) else { return .ignored }
        let reorder = arrow && modifiers == .option
        let park = press.characters.lowercased() == "k" && modifiers == .command
        let start = press.key == .return && modifiers == .command
        let recognized =
            reorder || park || start
            || (plain
                && (arrow || press.key == .space || press.key == .return
                    || press.key == .delete || press.key == .rightArrow || press.key == .leftArrow))
        guard recognized else { return .ignored }
        guard press.phase == .down else { return .handled }
        if reorder {
            if let move = TodayTaskNavigation.reorder(
                tasks, currentID: currentID, selectedID: id,
                offset: press.key == .upArrow ? -1 : 1)
            {
                store.apply { try $0.reorder(id, before: move.beforeID) }
            }
        } else if start {
            if !task.done && store.planner.focus.map({ $0.state == .running || $0.state == .paused }) != true {
                store.apply { try $0.startTimer(task: id, minutes: nil) }
            }
        } else if park {
            store.apply { try TodayTaskNavigation.park(id, commands: $0) }
        } else if arrow, let stepID = selectedStepID {
            selectedStepID = TodayTaskNavigation.neighbor(
                in: task.steps.map(\.id), from: stepID,
                offset: press.key == .upArrow ? -1 : 1)
        } else if arrow {
            moveChecklist(tasks, offset: press.key == .upArrow ? -1 : 1)
        } else if press.key == .space, let stepID = selectedStepID {
            store.updateTask(id) { draft in
                if let index = draft.steps.firstIndex(where: { $0.id == stepID }) { draft.steps[index].done.toggle() }
            }
        } else if press.key == .space {
            if task.done { store.apply { try $0.reopen(id) } } else { store.send(.complete(id)) }
        } else if press.key == .return {
            edit(id)
        } else if press.key == .delete {
            store.apply { try $0.delete(id, on: .day(store.today)) }
        } else if press.key == .rightArrow {
            if id == currentID || expandedTasks.contains(id) { selectedStepID = task.steps.first?.id }
            expandedTasks.insert(id)
        } else if press.key == .leftArrow {
            selectedStepID = nil
            if id != currentID { expandedTasks.remove(id) }
        }
        return .handled
    }
}

/// The native responder and the AX group are deliberately the same object.
/// These concrete modifiers configure AppKit directly instead of adding a SwiftUI focus proxy.
private struct ChecklistKeyTarget: NSViewRepresentable {
    let onKey: (ChecklistKeyPress) -> KeyPress.Result
    let onTab: (Bool) -> Bool
    private var enabled = false
    private var binding: FocusState<TodayFocus?>.Binding?
    private var destination: TodayFocus = .checklist
    private var identifier = ""

    init(onKey: @escaping (ChecklistKeyPress) -> KeyPress.Result, onTab: @escaping (Bool) -> Bool) {
        self.onKey = onKey
        self.onTab = onTab
    }

    func focusable(_ enabled: Bool) -> Self {
        var copy = self; copy.enabled = enabled; return copy
    }

    func focused(_ binding: FocusState<TodayFocus?>.Binding, equals destination: TodayFocus) -> Self {
        var copy = self; copy.binding = binding; copy.destination = destination; return copy
    }

    func accessibilityIdentifier(_ identifier: String) -> Self {
        var copy = self; copy.identifier = identifier; return copy
    }

    func makeNSView(context: Context) -> ChecklistKeyView { ChecklistKeyView() }

    func updateNSView(_ view: ChecklistKeyView, context: Context) {
        let binding = binding, destination = destination
        view.key = onKey
        view.tab = onTab
        view.focusChanged = { focused in
            if focused {
                binding?.wrappedValue = destination
            } else if binding?.wrappedValue == destination {
                binding?.wrappedValue = nil
            }
        }
        view.active = enabled
        view.setAccessibilityIdentifier(identifier)
        // Re-read current intent when the view is attached. A queued old selection must
        // never steal focus back from capture, Undo, another window, or a removed card.
        DispatchQueue.main.async { [weak view] in
            guard let view, binding?.wrappedValue == destination,
                view.window?.isKeyWindow == true, view.acceptsFirstResponder,
                view.window?.firstResponder !== view
            else { return }
            view.window?.makeFirstResponder(view)
        }
    }

    static func dismantleNSView(_ view: ChecklistKeyView, coordinator: ()) {
        view.active = false
        view.focusChanged(false)
        view.focusChanged = { _ in }
        view.key = { _ in .ignored }
        view.tab = { _ in false }
    }
}

/// One actual AppKit key view for the entire checklist, never one per task or step.
final class ChecklistKeyView: NSView {
    var active = false {
        didSet {
            if !active && window?.firstResponder === self { window?.makeFirstResponder(nil) }
            if active != oldValue { window?.recalculateKeyViewLoop() }
        }
    }
    var key: (ChecklistKeyPress) -> KeyPress.Result = { _ in .ignored }
    var tab: (Bool) -> Bool = { _ in false }
    var focusChanged: (Bool) -> Void = { _ in }
    private var keyFrame = NSRect.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(AppL10n.text("The checklist"))
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool {
        active && window != nil && !bounds.isEmpty && !isHiddenOrHasHiddenAncestor
    }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.recalculateKeyViewLoop()
    }

    override func layout() {
        super.layout()
        guard keyFrame != frame else { return }
        keyFrame = frame
        window?.recalculateKeyViewLoop()
    }

    override func becomeFirstResponder() -> Bool {
        guard acceptsFirstResponder, super.becomeFirstResponder() else { return false }
        focusChanged(true)
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        // Emptying the list invalidates this key view before SwiftUI may run its
        // removal observer. Preserve that observer's checklist -> Undo/capture intent.
        if active { focusChanged(false) }
        return true
    }

    override func isAccessibilityEnabled() -> Bool { active }
    override func isAccessibilityFocused() -> Bool {
        acceptsFirstResponder && window?.isKeyWindow == true && window?.firstResponder === self
    }
    override var accessibilityFocusedUIElement: Any? { isAccessibilityFocused() ? self : nil }
    override func setAccessibilityFocused(_ focused: Bool) {
        if focused && acceptsFirstResponder {
            window?.makeFirstResponder(self)
        } else if !focused && window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 48, flags.isEmpty || flags == .shift {
            guard !event.isARepeat else { return }
            let backwards = flags == .shift
            if !tab(backwards) {
                if backwards { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
            }
        } else if !dispatch(event) {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode != 48 && !dispatch(event) { super.keyUp(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        return dispatch(event) || super.performKeyEquivalent(with: event)
    }

    private func dispatch(_ event: NSEvent) -> Bool {
        guard isAccessibilityFocused() else { return false }
        switch key(ChecklistKeyPress(event)) {
        case .handled: return true
        case .ignored: return false
        @unknown default: return false
        }
    }
}

/// Normalize AppKit events once; task/step actions retain their existing phase/modifier rules.
struct ChecklistKeyPress {
    enum Phase: Equatable { case down, `repeat`, up }
    let key: KeyEquivalent
    let characters: String
    let modifiers: EventModifiers
    let phase: Phase

    init(_ event: NSEvent) {
        characters = event.charactersIgnoringModifiers ?? ""
        switch event.keyCode {
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        case 125: key = .downArrow
        case 126: key = .upArrow
        case 36, 76: key = .return
        case 49: key = .space
        case 51: key = .delete
        default: key = KeyEquivalent(characters.first ?? "\0")
        }
        var flags: EventModifiers = []
        if event.modifierFlags.contains(.command) { flags.insert(.command) }
        if event.modifierFlags.contains(.control) { flags.insert(.control) }
        if event.modifierFlags.contains(.option) { flags.insert(.option) }
        if event.modifierFlags.contains(.shift) { flags.insert(.shift) }
        modifiers = flags
        phase = event.type == .keyUp ? .up : (event.isARepeat ? .repeat : .down)
    }
}

/// The scroll proxy stays owned by the checklist, not its individual step rows.
enum ChecklistStepScroll {
    static func reveal(_ id: UUID?, using scrollTo: (UUID, UnitPoint) -> Void) {
        guard let id else { return }
        scrollTo(id, .center)
    }
}

/// Review is opt-in; automatic carry behavior remains a Settings preference.
private struct OverdueReview: View {
    @EnvironmentObject var store: PlannerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let tasks = store.engine.bringOverCandidates()
        VStack(alignment: .leading, spacing: Theme.Size.cardPadding.value) {
            Text("Unfinished from earlier days").perchFont(.cardTitle)
            Text("Choose what to do with these tasks. Automatic handling can be changed in Settings.")
                .perchFont(.body).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Size.cardPadding.value / 2) {
                    ForEach(tasks) { task in
                        Text(task.title).perchFont(.body).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: Theme.Size.taskRowHeight.value * 4)
            PerchButton("Bring all to today", kind: .soft) {
                resolve { _ = try $0.bringOver() }
            }

            PerchButton("Mark all done", kind: .soft) { resolve { try $0.completeOverdue(tasks.map(\.id)) } }
            PerchButton("Leave all in history", kind: .soft) { resolve { try $0.dismissOverdue(tasks.map(\.id)) } }
            PerchButton("Not now", kind: .quiet) { dismiss() }.keyboardShortcut(.cancelAction)
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
    func updateNSView(_ view: Marker, context: Context) {
        view.attach()
        DispatchQueue.main.async { [weak view] in view?.attach() }
    }
    static func dismantleNSView(_ view: Marker, coordinator: ()) { view.detach() }

    // The marker only discovers its enclosing scroller; the fade is drawn there.
    // Never let AppKit's default representable sizing affect the task/capture layout.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Marker, context: Context) -> CGSize? { .zero }

    final class Marker: NSView {
        private weak var scroll: NSScrollView?
        private let fade = OverflowFadeView(frame: .zero)

        override init(frame: NSRect) {
            super.init(frame: frame)
            fade.identifier = NSUserInterfaceItemIdentifier("today-continuation-fade")
            fade.color = NSColor(Theme.paper)
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

        func detach() {
            NotificationCenter.default.removeObserver(self)
            fade.removeFromSuperview()
            scroll = nil
        }

        func attach() {
            guard let enclosing = ChecklistViewportAttachment.resolve(from: self) else {
                detach()
                return
            }
            // Native-only identity must not overwrite the checklist focus proxy or its children.
            enclosing.setAccessibilityIdentifier("today-task-viewport")
            if scroll !== enclosing {
                detach()
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
            let height = min(Theme.Size.windowPadding.value, viewport.height)
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

/// SwiftUI may host a ScrollView background beside, rather than inside, its native scroller.
/// The viewport-sized marker must match exactly one scroll frame in its nearest hosting scope.
@MainActor
enum ChecklistViewportAttachment {
    static func resolve(from marker: NSView) -> NSScrollView? {
        if let enclosing = marker.enclosingScrollView { return enclosing }
        guard marker.window != nil, !marker.bounds.isEmpty, !marker.isHiddenOrHasHiddenAncestor else { return nil }
        var ancestor = marker.superview
        while let container = ancestor {
            let target = marker.convert(marker.bounds, to: container)
            let matches = scrolls(in: container).filter { scroll in
                let frame = scroll.convert(scroll.bounds, to: container)
                return !scroll.isHiddenOrHasHiddenAncestor && scroll.documentView != nil
                    && abs(frame.minX - target.minX) <= 1 && abs(frame.minY - target.minY) <= 1
                    && abs(frame.width - target.width) <= 1 && abs(frame.height - target.height) <= 1
            }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { return nil }
            ancestor = container.superview
        }
        return nil
    }

    private static func scrolls(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { scrolls(in: $0) }
    }
}

/// Parsed task entry and one-level step entry share the same native editor.
struct TaskComposer: View {
    let day: DayRef
    var placeholder = "Add a task"
    var focus: FocusState<TodayFocus?>.Binding? = nil
    var homeState: TodayHomeState? = nil
    var initialStep = false
    var initialText: String? = nil
    var onStep: (UUID) -> Void = { _ in }
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var services: Services
    @EnvironmentObject var model: NotchModel
    @State private var capture = TodayTaskCapture()
    @State private var lastAddedID: UUID?
    @State private var parsed: CapturedTask?
    @FocusState private var localFocus: TodayFocus?
    @FocusState private var fieldFocused: Bool
    private var focusBinding: FocusState<TodayFocus?>.Binding { focus ?? $localFocus }
    private var focused: Bool { focusBinding.wrappedValue == .capture }
    private var text: String { capture.text }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Size.focusGap.value * 3) {
            if let parent = capture.parentID.flatMap({ id in store.planner.tasks.first { $0.id == id } }) {
                Text(AppL10n.format("Step of %@", parent.title)).perchFont(.detail).foregroundStyle(Theme.ink2)
            }
            ChecklistCaptureField(
                voice: services.voice, text: $capture.text, prompt: placeholder,
                focus: $fieldFocused, onSubmit: add, onDictate: dictate
            )
            .background(CaptureTextUndo(onTab: changeIndent))
            if let pending = capture.pendingDictation {
                Text(pending).perchFont(.detail).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                PerchButton("Try adding the dictated task again", kind: .quiet, size: .small) {
                    _ = capture.retryDictation { submit($0, parentID: $1) }
                }
            }
            if !text.isEmpty {
                HStack(spacing: Theme.Size.focusGap.value * 3) {
                    if capture.parentID == nil, let parsed {
                        if let start = parsed.startAt {
                            PerchPill(start.formatted(date: .omitted, time: .shortened), surface: .paper)
                        }
                        if let minutes = parsed.minutes {
                            PerchPill(AppL10n.format("%lld min set aside", minutes), surface: .paper)
                        }
                    }
                    Spacer(minLength: .zero)
                    Text("Return adds it").perchFont(.detail).foregroundStyle(Theme.ink2)
                }
            }
        }
        .onAppear {
            #if DEBUG || PERCH_TESTING
                if initialStep { _ = changeIndent(false); capture.text = "Check the final detail" }
                if let initialText { capture.text = initialText }
            #endif
            updateDraft()
        }
        .onChange(of: capture) { _, _ in updateDraft() }
        .onChange(of: day) { _, _ in updateDraft() }
        .onChange(of: fieldFocused) { _, value in
            if value { focusBinding.wrappedValue = .capture } else if focused { focusBinding.wrappedValue = nil }
        }
        .onChange(of: focused) { _, value in fieldFocused = value }
        .onDisappear { homeState?.captureDraft = nil }
        .task(id: model.captureFocusRequest) {
            guard model.captureFocusRequest != nil && model.expanded && model.page == .home else {
                if focused { focusBinding.wrappedValue = nil; fieldFocused = false }
                return
            }
            focusBinding.wrappedValue = nil
            fieldFocused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusBinding.wrappedValue = .capture
            fieldFocused = true
        }
    }

    private func updateDraft() {
        guard day == .day(store.today), let language = TaskParserLanguage.current else {
            parsed = nil; homeState?.captureDraft = nil; return
        }
        parsed = capture.preview(using: store.capture, language: language)
        if let draft = parsed, let start = draft.startAt, !draft.inbox, draft.day == nil || draft.day == store.today {
            homeState?.captureDraft = TodayHomeState.CaptureDraft(
                startTime: start,
                minutes: draft.minutes ?? store.prefs.defaultFocusMinutes)
        } else if capture.parentID == nil,
            let preview = YourDayTimeline.capturePreview(
                text, using: store.capture, language: language, day: store.today)
        {
            homeState?.captureDraft = TodayHomeState.CaptureDraft(
                startTime: preview.start, minutes: preview.minutes)
        } else {
            homeState?.captureDraft = nil
        }
    }

    private func changeIndent(_ backwards: Bool) -> Bool {
        if backwards { return capture.outdent() }
        let tasks = store.engine.tasks(on: day).filter { !$0.done }
        let parent = tasks.first { $0.id == lastAddedID } ?? tasks.last
        return capture.indent(parentID: parent?.id)
    }

    func add() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard submit(value, parentID: capture.parentID) else { return }
        capture.text = ""
        parsed = nil
        homeState?.captureDraft = nil
        focusBinding.wrappedValue = .capture
        fieldFocused = true
    }

    private func dictate() {
        let parentID = capture.parentID
        services.voice.toggle { spoken in addDictation(spoken, parentID: parentID) }
    }

    private func addDictation(_ spoken: String, parentID: UUID?) {
        // The callback never assigns or clears the live editor, including on failure.
        _ = capture.submitDictation(spoken, parentID: parentID) { submit($0, parentID: parentID) }
    }

    private func submit(_ value: String, parentID: UUID?) -> Bool {
        let result: [PlanTask]?
        if parentID == nil {
            result = store.addTasks([value], on: day)
        } else {
            result = store.apply { commands in
                try TodayTaskCapture.submit(
                    value, parentID: parentID, on: day, commands: commands, language: .english)
            }
        }
        guard let added = result else { return false }
        if let parentID {
            onStep(parentID)
        } else {
            lastAddedID = added.last?.id; AISorter.sort(added.map(\.id), store: store)
        }
        return true
    }
}

/// Observe the voice service itself; its publisher is not forwarded by Services.
struct ChecklistCaptureField: View {
    @ObservedObject var voice: VoiceCapture
    @Binding var text: String
    let prompt: String
    let focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onDictate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Size.focusGap.value) {
            AddField(
                "Add a task", text: $text, prompt: prompt, focus: focus,
                isDictating: voice.state == .listening, onSubmit: onSubmit, onDictate: onDictate)
            switch voice.state {
            case .idle: EmptyView()
            case .listening:
                Text("Listening. Tap the mic to stop.").perchFont(.detail).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("capture-listening")
            case .error(let message):
                Text(message).perchFont(.detail).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("capture-dictation-error")
            }
        }
    }
}

/// Capture keeps working when the accessory panel has no application Edit menu.
/// Its native text history remains separate from the planner's command history.
struct CaptureTextUndo: NSViewRepresentable {
    var onTab: ((Bool) -> Bool)? = nil
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.onTab = onTab; view.enableUndo() }
    static func dismantleNSView(_ view: Marker, coordinator: ()) { view.stop() }

    final class Marker: NSView {
        var onTab: ((Bool) -> Bool)?
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
            if event.keyCode == 48, flags.isEmpty || flags == .shift, !editor.hasMarkedText() {
                if event.isARepeat { return nil }
                if onTab?(flags == .shift) == true { return nil }
            }
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

enum ChecklistPreviewState {
    case none, expanded, steps, selected, stepEntry, completed, dictating, voiceError, multiline
}

#if DEBUG || PERCH_TESTING
    @MainActor enum ChecklistPreview {
        static func show(_ state: ChecklistPreviewState, app: AppDelegate) {
            app.services.voice.state = VoiceCapture.State.idle
            WindowHost.windows["checklist-preview"]?.close()
            if state == .dictating { app.services.voice.state = .listening }
            if state == .voiceError {
                app.services.voice.state = .error(
                    AppL10n.text("Allow Speech Recognition for Perch under System Settings › Privacy & Security."))
            }
            if state == .completed {
                for task in app.store.engine.tasks(on: .day(app.store.today)) where !task.done {
                    app.store.send(.complete(task.id))
                }
            }
            let width = HomeLayout.columns(sheetWidth: Theme.Size.todayWidth.value).checklist
            WindowHost.show(
                "checklist-preview", title: "Today",
                size: CGSize(width: width, height: WorkspaceLayout.sheetHeight - Theme.Size.sheetPadding.value * 2)
            ) {
                TasksCard(preview: state)
                    .environmentObject(app.store).environmentObject(app.model).environmentObject(app.services)
            }
        }
    }
#endif
