import AppKit
import PerchUI
import PlannerCore
import SwiftUI
import UniformTypeIdentifiers

private struct WeekKeyboardFocusKey: FocusedValueKey {
    typealias Value = WeekTaskPolicy.KeyboardFocus
}

private extension FocusedValues {
    var weekKeyboardFocus: WeekTaskPolicy.KeyboardFocus? {
        get { self[WeekKeyboardFocusKey.self] }
        set { self[WeekKeyboardFocusKey.self] = newValue }
    }
}

/// The workspace uses eight columns; legacy direct hosts keep their toolbar.
struct WeekPage: View {
    var workspaceShell = false
    var body: some View {
        if workspaceShell { WeekBoard() } else { LegacyWeekPage() }
    }
}

/// A single layout pass chooses widths. Every day remains in the scroll backing.
struct WeekBoard: View {
    var initiallyExpanded = false
    var initiallyAdding: DayKey?
    @EnvironmentObject private var store: PlannerStore
    @State private var anchor = 0
    @State private var scrollDay: DayKey?
    @FocusedValue(\.weekKeyboardFocus) private var keyboardFocus: WeekTaskPolicy.KeyboardFocus?
    @FocusState private var earlierFocused: Bool
    @FocusState private var focusedDay: DayKey?

    private var days: [DayKey] {
        WeekColumnLayout.days(today: store.today, weekOffset: anchor, calendar: store.engine.calendar)
    }

    var body: some View {
        GeometryReader { geometry in
            scrollingBoard(available: geometry.size.width)
        }
        .foregroundStyle(Theme.ink)
        .onReceive(NotificationCenter.default.publisher(for: .perchWorkspaceWeekChanged)) { note in
            if let value = note.object as? Int { anchor = value; scrollDay = nil }
        }
        .onChange(of: days, initial: true) { _, value in
            store.materializeRepeats(on: value)
        }
        .onChange(of: focusedDay) { _, day in
            if let day { scrollDay = day }
        }
    }

    private func scrollingBoard(available: CGFloat) -> some View {
        let layout = WeekColumnLayout.columns(days: days, today: store.today, available: available)
        return ScrollViewReader { proxy in
            boardColumns(layout: layout)
                .onChange(of: days, initial: true) { _, _ in
                    if let day = scrollDay ?? layout.days.first { proxy.scrollTo(day, anchor: .leading) }
                }
                .onChange(of: available) { _, _ in
                    if let day = scrollDay ?? layout.days.first { proxy.scrollTo(day, anchor: .leading) }
                }
                .onChange(of: scrollDay) { _, day in
                    if let day { proxy.scrollTo(day, anchor: .leading) }
                }
                .overlay(alignment: .bottomLeading) {
                    if layout.omittedPastDays > 0 { earlierDaysButton }
                }
        }
    }

    private func boardColumns(layout: WeekColumnLayout.Columns) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: WeekColumnLayout.gap) {
                ForEach(layout.backingDays, id: \.self) { day in
                    dayColumn(day, layout: layout)
                }
                WeekParkingColumn(days: days)
                    .frame(width: layout.parkingWidth)
            }
            .frame(minHeight: WeekColumnLayout.minimumColumnHeight, alignment: .top)
        }
        .scrollIndicators(layout.needsHorizontalScroll ? .visible : .hidden)
    }

    private func dayColumn(_ day: DayKey, layout: WeekColumnLayout.Columns) -> some View {
        WeekBoardDay(
            day: day, days: days,
            expanded: initiallyExpanded && day == store.today, adding: initiallyAdding == day
        )
        .frame(width: layout.width(for: day))
        .focusable()
        .focused($focusedDay, equals: day)
        .focusedValue(\.weekKeyboardFocus, .day(day))
        .accessibilityIdentifier("week-day-focus-\(day.raw)")
        .focusEffectDisabled()
        .overlay(
            FocusRing(
                shape: RoundedRectangle(cornerRadius: WeekColumnLayout.columnRadius),
                focused: focusedDay == day, surface: day == store.today ? .butter : .paper)
        )
        .onKeyPress(.leftArrow, phases: .down) { key in
            guard key.modifiers.isEmpty else { return .ignored }
            navigate(from: day, by: -1); return .handled
        }
        .onKeyPress(.rightArrow, phases: .down) { key in
            if key.modifiers == .option {
                return pushSelected(from: day) ? .handled : .ignored
            }
            guard key.modifiers.isEmpty else { return .ignored }
            navigate(from: day, by: 1); return .handled
        }
        .onKeyPress(.space, phases: [.down, .repeat, .up]) { key in
            #if WEEK_INBOX_KEYBOARD_PROBE
                FileHandle.standardError.write(
                    Data(
                        "WEEK_ADD column-space day=\(day.raw) phase=\(key.phase) keyboardFocus=\(String(describing: keyboardFocus))\n"
                            .utf8))
            #endif
            guard key.modifiers.isEmpty,
                let action = WeekTaskPolicy.completionAction(
                    focus: keyboardFocus, from: day, tasks: store.planner.tasks, today: store.today)
            else { return .ignored }
            // The checkbox uses a custom focus proxy. Route Space explicitly,
            // and consume the remaining phases without toggling a second time.
            if key.phase == .down { store.send(action) }
            return .handled
        }
        #if WEEK_INBOX_KEYBOARD_PROBE
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("PerchWeekKeyboardProbe"))) { note in
                if note.object as? String == day.raw {
                    FileHandle.standardError.write(
                        Data(
                            "WEEK_ADD column-state day=\(day.raw) tag=\(note.userInfo?["tag"] ?? "nil") keyboardFocus=\(String(describing: keyboardFocus))\n"
                                .utf8))
                }
            }
        #endif
        .id(day)
    }

    private var earlierDaysButton: some View {
        Button {
            scrollDay = days.first
            focusedDay = days.first
        } label: {
            Label(AppL10n.text("Earlier days"), systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        .perchFont(.detailStrong)
        .foregroundStyle(Theme.ink)
        .perchControlFeedback(pressed: false)
        .frame(minHeight: Theme.Size.minimumTarget.value)
        .focused($earlierFocused)
        .overlay(FocusRing(shape: Capsule(), focused: earlierFocused, surface: .sheet))
        .accessibilityIdentifier("week-earlier-days")
    }

    private func navigate(from day: DayKey, by step: Int) {
        let next = day.adding(days: step, calendar: store.engine.calendar)
        if !days.contains(next) {
            anchor += step
            NotificationCenter.default.post(name: .perchWorkspaceWeekChanged, object: anchor)
        }
        scrollDay = next
        focusedDay = next
    }

    private func pushSelected(from day: DayKey) -> Bool {
        #if DEBUG
            FileHandle.standardError.write(
                Data("WEEK_KEY column day=\(day.raw) focus=\(String(describing: keyboardFocus))\n".utf8))
        #endif
        guard day >= store.today,
            let action = WeekTaskPolicy.pushAction(
                focus: keyboardFocus, from: day, tasks: store.planner.tasks,
                today: store.today, calendar: store.engine.calendar),
            case .move(let id, _) = action,
            store.planner.tasks.first(where: { $0.id == id })?.day == day
        else { return false }
        store.send(action)
        return true
    }
}

private struct WeekBoardDay: View {
    let day: DayKey
    let days: [DayKey]
    @EnvironmentObject private var store: PlannerStore
    @State private var expanded = false
    @State private var adding = false
    @State private var draft = ""
    @State private var targeted = false
    @FocusState private var addingFocused: Bool
    @FocusState private var footerFocused: Bool

    init(day: DayKey, days: [DayKey], expanded: Bool = false, adding: Bool = false) {
        self.day = day
        self.days = days
        _expanded = State(initialValue: expanded)
        _adding = State(initialValue: adding)
    }

    private var isToday: Bool { day == store.today }
    private var past: Bool { day < store.today }
    private var surface: DesignTokens.Surface { isToday ? .butter : .paper }
    private var summary: WeekTaskPolicy.Summary {
        WeekTaskPolicy.summary(day: day, today: store.today, tasks: store.planner.tasks, expanded: expanded)
    }
    private var emptyComingDay: Bool { !past && !isToday && summary.tasks.isEmpty }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: WeekColumnLayout.columnRadius) }

    var body: some View {
        VStack(alignment: .leading, spacing: WeekColumnLayout.columnGap) {
            heading
            ScrollView {
                VStack(alignment: .leading, spacing: WeekColumnLayout.columnGap) {
                    ForEach(summary.tasks) { task in
                        WeekBoardTask(task: task, days: days, past: past, surface: surface)
                    }
                    ForEach(summary.carried) { task in
                        VStack(alignment: .leading, spacing: Theme.Size.focusGap.value) {
                            Text(task.title).perchFont(.body).lineLimit(2)
                            Text("Carried to today").perchFont(.detailStrong).foregroundStyle(Theme.carried)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(WeekColumnLayout.gap)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.Size.currentTaskRadius.value))
                    }
                    if emptyComingDay {
                        Text("Nothing planned. A good day to keep clear.")
                            .perchFont(.body).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if past, let more = summary.more {
                        Text(more).perchFont(.detail).foregroundStyle(Theme.ink3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            if !past {
                if isToday, let more = summary.more {
                    Button(more) { expanded = true }
                        .buttonStyle(.plain).perchFont(.detailStrong).underline()
                        .frame(minHeight: Theme.Size.minimumTarget.value)
                        .perchControlFeedback(pressed: false)
                        .focusable()
                        .focused($footerFocused).focusEffectDisabled()
                        .overlay(FocusRing(shape: Capsule(), focused: footerFocused, surface: surface))
                        .accessibilityIdentifier("week-overflow-\(day.raw)")
                } else if !isToday {
                    if adding {
                        TextField(AppL10n.text("Add a task"), text: $draft)
                            .textFieldStyle(.plain).perchFont(.body)
                            .frame(minHeight: Theme.Size.minimumTarget.value)
                            .overlay(
                                FocusRing(
                                    shape: RoundedRectangle(cornerRadius: Theme.Size.focusGap.value),
                                    focused: addingFocused, surface: surface)
                            )
                            .focused($addingFocused)
                            .onSubmit {
                                if store.addTasks([draft], on: .day(day)) != nil { draft = ""; adding = false }
                            }
                            .onExitCommand {
                                draft = ""; adding = false
                            }
                            .accessibilityIdentifier("week-add-field-\(day.raw)")
                    } else {
                        Button("Add a task") { beginAdding() }
                            .buttonStyle(.plain).perchFont(.detailStrong).foregroundStyle(Theme.brandText)
                            .frame(minHeight: Theme.Size.minimumTarget.value)
                            .perchControlFeedback(pressed: false)
                            .focusable()
                            .focused($footerFocused).focusEffectDisabled()
                            .overlay(FocusRing(shape: Capsule(), focused: footerFocused, surface: surface))
                            .onKeyPress(.space, phases: [.down, .repeat, .up]) { key in
                                guard footerFocused, key.modifiers.isEmpty else { return .ignored }
                                // The explicit focus stop uses a SwiftUI KeyViewProxy, which
                                // does not forward Space to the native Button action.
                                if key.phase == .down { beginAdding() }
                                return .handled
                            }
                            .accessibilityIdentifier("week-add-\(day.raw)")
                    }
                }
            }
        }
        .padding(.horizontal, WeekColumnLayout.horizontalPadding)
        .padding(.vertical, WeekColumnLayout.columnPadding)
        .frame(height: WeekColumnLayout.minimumColumnHeight, alignment: .top)
        .background(Theme.fill(surface), in: shape)
        .overlay(
            shape.strokeBorder(
                targeted ? Theme.focusRing : emptyComingDay ? Theme.ink2 : Theme.edge(surface),
                style: StrokeStyle(
                    lineWidth: Theme.Size.cardEdge.value,
                    dash: emptyComingDay ? [WeekColumnLayout.gap / 2] : []))
        )
        .environment(\.controlSurface, Theme.fill(surface))
        .environment(\.designSurface, surface)
        .onDrop(of: [.perchTask, .perchParkedThought], isTargeted: $targeted) { providers in
            guard !past else { return false }
            return WeekDrop.accept(providers, on: day, store: store)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("week-day-\(day.raw)")
        // Fields and footer controls must not inherit the column's first-task shortcut.
        .focusedValue(\.weekKeyboardFocus, .other)
        #if WEEK_INBOX_KEYBOARD_PROBE
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("PerchWeekKeyboardProbe"))) { note in
                if note.object as? String == day.raw {
                    FileHandle.standardError.write(
                        Data(
                            ("WEEK_ADD day-state day=\(day.raw) tag=\(note.userInfo?["tag"] ?? "nil") "
                                + "footerFocused=\(footerFocused) adding=\(adding) addingFocused=\(addingFocused)\n")
                                .utf8))
                }
            }
        #endif
    }

    private func beginAdding() {
        #if WEEK_INBOX_KEYBOARD_PROBE
            FileHandle.standardError.write(Data("WEEK_ADD button-action day=\(day.raw)\n".utf8))
        #endif
        adding = true
        addingFocused = true
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: Theme.Size.focusGap.value) {
            VStack(alignment: .leading, spacing: Theme.Size.focusGap.value) {
                Text(isToday ? AppL10n.text("Today") : dateLabel("EEEd"))
                    .perchFont(.currentTask).foregroundStyle(past ? Theme.ink2 : Theme.ink)
                if isToday { Text(dateLabel("EEEd")).perchFont(.detail).foregroundStyle(Theme.ink2) }
                if !isToday {
                    Text(emptyComingDay ? AppL10n.text("Open") : summary.count)
                        .perchFont(.detailStrong).foregroundStyle(past ? Theme.doneText : Theme.ink2)
                }
            }
            if isToday {
                Spacer(minLength: .zero)
                Text(summary.count).perchFont(.detailStrong).monospacedDigit().foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dateLabel(_ template: String) -> String {
        WeekColumnLayout.dateLabel(
            day, template: template, calendar: store.engine.calendar, locale: .autoupdatingCurrent)
    }
}

private struct WeekBoardTask: View {
    let task: PlanTask
    let days: [DayKey]
    let past: Bool
    let surface: DesignTokens.Surface
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var model: NotchModel
    @FocusedValue(\.weekKeyboardFocus) private var keyboardFocus: WeekTaskPolicy.KeyboardFocus?
    @FocusState private var menuFocused: Bool
    @State private var menuKeyboard = WeekMenuKeyboardTarget()

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Size.focusGap.value) {
            if past {
                Image(systemName: "checkmark.circle")
                    .perchFont(.currentTask).foregroundStyle(Theme.doneText)
                    .accessibilityLabel(AppL10n.text("Done"))
            } else {
                PerchCheckbox(
                    title: task.title,
                    isOn: Binding(
                        get: { task.done },
                        set: { _ in
                            if let action = WeekTaskPolicy.scheduledCompletionAction(for: task, today: store.today) {
                                store.send(action)
                            }
                        }), surface: surface
                )
                .frame(width: Theme.Size.minimumTarget.value, height: Theme.Size.minimumTarget.value)
                .contentShape(Rectangle())
                .accessibilityIdentifier("week-check-\(task.id)")
                .focusedValue(\.weekKeyboardFocus, .checkbox(task.id))
                .disabled(WeekTaskPolicy.scheduledCompletionAction(for: task, today: store.today) == nil)
            }
            if past {
                title
            } else {
                Menu {
                    actions
                } label: {
                    title
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .background(WeekMenuKeyboardAnchor(target: menuKeyboard))
                .focusable().focused($menuFocused).focusEffectDisabled()
                .onKeyPress(.space) { menuKeyboard.open() ? .handled : .ignored }
                .overlay(
                    FocusRing(
                        shape: RoundedRectangle(cornerRadius: Theme.Size.focusGap.value),
                        focused: menuFocused, surface: surface)
                )
                .accessibilityLabel(AppL10n.format("Task actions: %@", task.title))
                .accessibilityIdentifier("week-menu-\(task.id)")
                .draggable(TaskDragItem(taskID: task.id))
                .contextMenu { actions }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(WeekColumnLayout.chipHelp(title: task.title, past: past))
        .onKeyPress(.rightArrow, phases: .down) { key in
            guard key.modifiers == .option else { return .ignored }
            #if DEBUG
                FileHandle.standardError.write(
                    Data("WEEK_KEY row id=\(task.id) focus=\(String(describing: keyboardFocus))\n".utf8))
            #endif
            guard keyboardFocus == .task(task.id) || keyboardFocus == .checkbox(task.id), let day = task.day,
                let action = WeekTaskPolicy.moveAction(
                    id: task.id, to: .day(day.adding(days: 1, calendar: store.engine.calendar)),
                    tasks: store.planner.tasks, today: store.today)
            else { return .ignored }
            store.send(action)
            return .handled
        }
        // Both native checkbox focus and menu focus export this exact row.
        .focusedValue(\.weekKeyboardFocus, .task(task.id))
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: Theme.Size.focusGap.value) {
            Text(task.title).perchFont(.body).strikethrough(task.done)
                .foregroundStyle(task.done ? Theme.ink3 : Theme.ink)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if !task.done && !details.isEmpty {
                Text(details).perchFont(.detail).monospacedDigit().foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var details: String {
        var parts: [String] = []
        if let start = task.startAt { parts.append(WeekColumnLayout.timeLabel(start, calendar: store.engine.calendar)) }
        if !task.steps.isEmpty {
            parts.append(AppL10n.format("%lld of %lld steps", task.steps.filter(\.done).count, task.steps.count))
        }
        if parts.isEmpty, task.day == store.today { parts.append(AppL10n.text("Any time")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        Button("Details…") { model.detailsTaskID = task.id }
        if let completion = WeekTaskPolicy.scheduledCompletionAction(for: task, today: store.today) {
            Button(AppL10n.text(task.done ? "Uncheck task" : "Check off task")) { store.send(completion) }
        }
        if !task.done {
            Button("Push a task a day") {
                guard let day = task.day,
                    let action = WeekTaskPolicy.moveAction(
                        id: task.id,
                        to: .day(day.adding(days: 1, calendar: store.engine.calendar)),
                        tasks: store.planner.tasks, today: store.today)
                else { return }
                store.send(action)
            }
            Menu("Move to day") {
                ForEach(WeekTaskPolicy.moveDestinations(for: task, displayedDays: days, today: store.today), id: \.self)
                { day in
                    Button(WeekColumnLayout.dateLabel(day, template: "EEEd", calendar: store.engine.calendar)) {
                        if let action = WeekTaskPolicy.moveAction(
                            id: task.id, to: .day(day),
                            tasks: store.planner.tasks, today: store.today)
                        {
                            store.send(action)
                        }
                    }
                }
            }
        }
    }
}

struct WeekParkingColumn: View {
    let days: [DayKey]
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        VStack(alignment: .leading, spacing: WeekColumnLayout.gap) {
            VStack(alignment: .leading, spacing: Theme.Size.focusGap.value) {
                Text("Parking lot").perchFont(.currentTask)
                Text("No day yet").perchFont(.detail).foregroundStyle(Theme.ink2)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: WeekColumnLayout.gap) {
                    ForEach(store.planner.parkedThoughts) { thought in
                        WeekThoughtCard(thought: thought, days: days)
                    }
                }
            }
            .scrollIndicators(.hidden)
            Text("Drag one onto a day").perchFont(.detail).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, WeekColumnLayout.horizontalPadding)
        .padding(.vertical, WeekColumnLayout.columnPadding)
        .frame(height: WeekColumnLayout.minimumColumnHeight, alignment: .top)
        .background(Theme.apricot, in: RoundedRectangle(cornerRadius: WeekColumnLayout.columnRadius))
        .overlay(
            RoundedRectangle(cornerRadius: WeekColumnLayout.columnRadius)
                .strokeBorder(Theme.edge(.apricot), lineWidth: Theme.Size.cardEdge.value)
        )
        .environment(\.controlSurface, Theme.apricot)
        .environment(\.designSurface, .apricot)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("week-parking-lot")
    }
}

private struct WeekThoughtCard: View {
    let thought: ParkedThought
    let days: [DayKey]
    @EnvironmentObject private var store: PlannerStore
    @FocusState private var focused: Bool
    @State private var keyboard = WeekMenuKeyboardTarget()

    var body: some View {
        Menu {
            ForEach(days.filter { $0 >= store.today }, id: \.self) { day in
                Button(WeekColumnLayout.dateLabel(day, template: "EEEd", calendar: store.engine.calendar)) {
                    store.send(.promoteThought(thought.id, day: day, agentID: nil))
                }
            }
        } label: {
            Text(thought.text).perchFont(.body).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: Theme.Size.minimumTarget.value)
                .padding(WeekColumnLayout.gap)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Size.currentTaskRadius.value))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .background(WeekMenuKeyboardAnchor(target: keyboard))
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.space) { keyboard.open() ? .handled : .ignored }
        .overlay(
            FocusRing(
                shape: RoundedRectangle(cornerRadius: Theme.Size.currentTaskRadius.value), focused: focused,
                surface: .paper)
        )
        .draggable(ParkedThoughtDragItem(thoughtID: thought.id))
        .accessibilityLabel(AppL10n.format("Make a task: %@", thought.text))
        .accessibilityIdentifier("week-thought-\(thought.id)")
    }
}

/// A single destination accepts both typed representations. Stacked drop destinations
/// compete for the same hit region; decode one identity, then revalidate current storage.
@MainActor
enum WeekDrop {
    static func accept(_ providers: [NSItemProvider], on day: DayKey, store: PlannerStore) -> Bool {
        guard day >= store.today, providers.count == 1, let provider = providers.first else { return false }
        let task = provider.hasItemConformingToTypeIdentifier(UTType.perchTask.identifier)
        let type = task ? UTType.perchTask : UTType.perchParkedThought
        guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in
                if task {
                    guard let item = try? JSONDecoder().decode(TaskDragItem.self, from: data),
                        let action = WeekTaskPolicy.moveAction(
                            id: item.taskID, to: .day(day), tasks: store.planner.tasks, today: store.today)
                    else { return }
                    store.send(action)
                } else {
                    guard day >= store.today,
                        let item = try? JSONDecoder().decode(ParkedThoughtDragItem.self, from: data),
                        store.planner.parkedThoughts.contains(where: { $0.id == item.thoughtID })
                    else { return }
                    store.send(.promoteThought(item.thoughtID, day: day, agentID: nil))
                }
            }
        }
        return true
    }
}

/// Compatibility host for older callers; the workspace uses the Week board.
struct LegacyWeekPage: View {
    var workspaceShell = false
    @EnvironmentObject var store: PlannerStore
    @Environment(\.isEnabled) private var enabled
    @State private var anchor = 0
    @State private var showInbox = false
    @FocusState private var inboxFocused: Bool
    @State private var target: String?

    private var days: [DayKey] {
        WeekColumnLayout.days(today: store.today, weekOffset: anchor, calendar: store.engine.calendar)
    }

    var body: some View {
        VStack(spacing: Theme.gutter) {
            HStack(spacing: Theme.gutter) {
                GlassButton(symbol: "chevron.left", help: "Previous week") { go(anchor - 1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppL10n.text(anchor == 0 ? "This week" : "Week")).font(Theme.heading)
                    Text(
                        AppL10n.format(
                            "%@ – %@", label(days[0], template: "MMMd"), label(days[6], template: "yMMMd"))
                    )
                    .font(Theme.meta).foregroundStyle(Theme.secondary).fixedSize()
                }
                GlassButton(symbol: "chevron.right", help: "Next week") { go(anchor + 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                if anchor != 0 {
                    Button("Today") { go(0) }.buttonStyle(PillStyle())
                        .keyboardShortcut("t", modifiers: [.command, .option])
                }
                Spacer(minLength: 0)
                Button(
                    showInbox
                        ? AppL10n.text("Back to week")
                        : AppL10n.format("Inbox (%lld)", store.engine.tasks(on: .inbox).count)
                ) {
                    toggleInbox()
                }
                .buttonStyle(PillStyle(focus: $inboxFocused))
                .onKeyPress(.space, phases: .down) { _ in
                    guard inboxFocused, enabled else { return .ignored }
                    toggleInbox()
                    return .handled
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .accessibilityIdentifier("week-inbox")
                .help(
                    showInbox
                        ? "Drag here to reveal the week, then drop onto a day."
                        : "Open Inbox, or drop a task here to unschedule it."
                )
                .dropDestination(for: String.self) { items, _ in
                    guard let payload = items.first,
                        let action = WeekTaskPolicy.moveAction(
                            payload: payload, to: .inbox, tasks: store.planner.tasks, today: store.today)
                    else { return false }
                    return store.send(action) != nil
                } isTargeted: { active in
                    // Reveal the calendar while an Inbox task remains on the drag pasteboard.
                    if active && showInbox { showInbox = false }
                }
            }
            .modifier(WorkspaceHeaderVisibility(hidden: workspaceShell))
            if showInbox {
                column(title: "Inbox", subtitle: "Unscheduled", ref: .inbox, isToday: false, past: false)
            } else {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: Theme.gutter) {
                                ForEach(
                                    workspaceShell
                                        ? WorkspaceLayout.weekColumns(
                                            days: days, today: store.today, available: geometry.size.width
                                        ).backingDays : days, id: \.self
                                ) { day in
                                    column(
                                        title: label(day, template: "EEE"), subtitle: label(day, template: "MMMd"),
                                        ref: .day(day), isToday: day == store.today, past: day < store.today
                                    )
                                    .frame(
                                        width: workspaceShell
                                            ? WorkspaceLayout.weekColumns(
                                                days: days, today: store.today, available: geometry.size.width
                                            ).width(for: day)
                                            : WeekColumnLayout.columnWidth(available: geometry.size.width)
                                    )
                                    .id(day)
                                }
                            }
                            .padding(4)
                            .frame(height: max(0, geometry.size.height - 12))
                        }
                        .scrollIndicators(.visible)
                        .onAppear {
                            proxy.scrollTo(days.contains(store.today) ? store.today : days[0], anchor: .leading)
                        }
                        .onChange(of: days) { _, value in
                            proxy.scrollTo(value.contains(store.today) ? store.today : value[0], anchor: .leading)
                        }
                    }
                }
                Text("Scroll across seven days · Drag to reschedule · Check today and coming days")
                    .font(Theme.meta).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Register the selected dates, not stale offsets from a previous logical week.
        // Observe only the range so task edits cannot reapply lifecycle mutations after Undo.
        .onReceive(NotificationCenter.default.publisher(for: .perchWorkspaceWeekChanged)) {
            if workspaceShell, let value = $0.object as? Int { anchor = value }
        }
        .onChange(of: anchor) { _, value in
            if workspaceShell { NotificationCenter.default.post(name: .perchWorkspaceWeekChanged, object: value) }
        }
        .onChange(of: days, initial: true) { _, value in
            store.materializeRepeats(on: value)
        }
    }

    private func label(_ day: DayKey, template: String) -> String {
        WeekColumnLayout.dateLabel(
            day, template: template, calendar: store.engine.calendar, locale: .autoupdatingCurrent)
    }

    private func toggleInbox() {
        Motion.animate(Motion.page) { showInbox.toggle() }
    }

    private func go(_ week: Int) {
        Motion.animate(Motion.page) {
            anchor = week; showInbox = false
        }
    }

    func column(title: String, subtitle: String, ref: DayRef, isToday: Bool, past: Bool) -> some View {
        let tasks = store.engine.tasks(on: ref)
        let key = ref.key?.raw ?? "inbox"
        return VStack(alignment: .leading, spacing: Theme.gutter) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppL10n.text(title)).font(Theme.heading).foregroundStyle(isToday ? Theme.accent : Theme.text)
                Text(AppL10n.text(subtitle)).font(Theme.meta).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                if isToday { Text("Today").font(Theme.label).foregroundStyle(Theme.accent) }
                if past { Text("Past").font(Theme.label).foregroundStyle(Theme.secondary) }
            }
            Text(AppL10n.format("%lld/%lld done", tasks.filter(\.done).count, tasks.count))
                .font(Theme.meta.monospacedDigit()).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(
                    AppL10n.format("%lld of %lld tasks complete", tasks.filter(\.done).count, tasks.count))
            WeekDayList(tasks: tasks, ref: ref, past: past)
            if !past { MiniComposer(ref: ref) }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius).fill(target == key ? Theme.selectedPill : Theme.card)
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.cardStroke))
        .environment(\.controlSurface, Theme.card)
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first,
                let action = WeekTaskPolicy.moveAction(
                    payload: payload, to: ref, tasks: store.planner.tasks, today: store.today)
            else { return false }
            return store.send(action) != nil
        } isTargeted: { active in
            target = active && !past ? key : (target == key ? nil : target)
        }
    }
}

/// One day's chips. When they overflow, the list fades out at the bottom and "+N more" says how many
/// chips sit below the fold; scrolling to the end clears both.
private struct WeekDayList: View {
    let tasks: [PlanTask]
    let ref: DayRef
    let past: Bool
    @State private var frames: [UUID: ClosedRange<CGFloat>] = [:]
    @State private var viewport: CGFloat = 0
    private static let space = "week-day-list"
    private static let fade: CGFloat = 22

    var body: some View {
        let hidden = WeekColumnLayout.hiddenBelow(
            chips: tasks.compactMap { task in
                frames[task.id].map { (top: Double($0.lowerBound), bottom: Double($0.upperBound)) }
            },
            viewport: Double(viewport), fade: Double(Self.fade))
        VStack(alignment: .leading, spacing: 3) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tasks) { t in
                        WeekChip(task: t)
                            .background(
                                GeometryReader { g in
                                    let f = g.frame(in: .named(Self.space))
                                    Color.clear.preference(key: ChipFrames.self, value: [t.id: f.minY...f.maxY])
                                }
                            )
                            .onDrag { NSItemProvider(object: t.id.uuidString as NSString) }
                            .transition(.opacity)
                    }
                    if tasks.isEmpty {
                        EmptyStateView(
                            past ? "No plans" : ref == .inbox ? "For later" : "Open day",
                            symbol: ref == .inbox ? "tray" : "calendar",
                            compact: true)
                    }
                }
                .motion(Motion.row, value: tasks.map(\.id))
            }
            .coordinateSpace(.named(Self.space))
            .scrollIndicators(.never)
            .onPreferenceChange(ChipFrames.self) { frames = $0 }
            .background(
                GeometryReader { g in
                    Color.clear.onAppear { viewport = g.size.height }.onChange(of: g.size.height) { _, h in viewport = h
                    }
                }
            )
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, hidden > 0 ? .clear : .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fade)
                }
            }
            if let more = WeekColumnLayout.overflowLabel(hidden: hidden) {
                Text(more).font(Theme.label).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel(AppL10n.format("%lld more tasks below", hidden))
                    .transition(.opacity)
            }
        }
        .motion(Motion.row, value: hidden > 0)
    }

    private struct ChipFrames: PreferenceKey {
        static let defaultValue: [UUID: ClosedRange<CGFloat>] = [:]
        static func reduce(value: inout [UUID: ClosedRange<CGFloat>], nextValue: () -> [UUID: ClosedRange<CGFloat>]) {
            value.merge(nextValue()) { $1 }
        }
    }
}

struct WeekChip: View {
    let task: PlanTask
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @FocusState private var menuFocused: Bool
    @State private var menuKeyboard = WeekMenuKeyboardTarget()

    private var past: Bool { task.day.map { $0 < store.today } ?? false }
    private var completion: PlannerAction? { WeekTaskPolicy.scheduledCompletionAction(for: task, today: store.today) }
    private var checkHint: String {
        if past { return WeekColumnLayout.pastHint }
        if task.day == nil { return "Schedule this task before checking it." }
        return AppL10n.text(task.done ? "Uncheck task" : "Check off task")
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.gutter) {
            GlassButton(
                symbol: task.done ? "checkmark.circle.fill" : "circle",
                help: task.done
                    ? AppL10n.format("Uncheck task: %@", task.title)
                    : AppL10n.format("Check off task: %@", task.title),
                tint: task.done
                    ? Theme.success : task.priority == .none ? Theme.secondary : Theme.priority(task.priority),
                disabledReason: checkHint
            ) {
                if let completion { Motion.animate(Motion.row) { _ = store.send(completion) } }
            }
            .disabled(completion == nil)
            .accessibilityValue(AppL10n.text(task.done ? "Complete" : "Incomplete"))
            .accessibilityIdentifier("week-check-\(task.id)")
            title
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .padding(.vertical, 5)
                .onTapGesture(count: 2) { model.detailsTaskID = task.id }
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis").font(Theme.body)
                    .frame(width: Theme.minimumTarget, height: Theme.minimumTarget)
                    .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.fill))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.inputStroke))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .background(WeekMenuKeyboardAnchor(target: menuKeyboard))
            .focusable()
            .focused($menuFocused).focusEffectDisabled()
            .onKeyPress(.space, phases: .down) { _ in
                menuKeyboard.open() ? .handled : .ignored
            }
            .overlay(ControlFocusRing(shape: RoundedRectangle(cornerRadius: Theme.controlRadius), focused: menuFocused))
            .accessibilityLabel(AppL10n.format("Task actions: %@", task.title))
            .accessibilityIdentifier("week-menu-\(task.id)")
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.fill))
        .contextMenu { actions }
        .help(WeekColumnLayout.chipHelp(title: task.title, past: past))
    }

    @ViewBuilder private var actions: some View {
        Button("Details…") { model.detailsTaskID = task.id }
        if let completion {
            Button(AppL10n.text(task.done ? "Uncheck task" : "Check off task")) { store.send(completion) }
        }
        if !past && !task.done {
            if task.day == store.today {
                Button("Start focusing") { store.send(.startTimer(task.id, minutes: nil)) }
            }
            Menu("Move to day") {
                ForEach(WeekColumnLayout.days(today: store.today, calendar: store.engine.calendar), id: \.self) { day in
                    if day >= store.today && day != task.day {
                        Button(day == store.today ? AppL10n.text("Today") : day.raw) { move(.day(day)) }
                    }
                }
                Button("Tomorrow") { move(.day(store.today.adding(days: 1, calendar: store.engine.calendar))) }
                    .disabled(task.day == store.today.adding(days: 1, calendar: store.engine.calendar))
            }
            if task.day != nil { Button("Move to Inbox") { move(.inbox) } }
            Divider()
            Button("Delete", role: .destructive) { store.send(.delete(task.id)) }
        }
    }

    private func move(_ destination: DayRef) {
        if let action = WeekTaskPolicy.moveAction(
            payload: task.id.uuidString, to: destination,
            tasks: store.planner.tasks, today: store.today)
        {
            store.send(action)
        }
    }

    private var title: Text {
        let words = Text(task.title).font(Theme.body)
            .strikethrough(task.done).foregroundStyle(task.done ? Theme.secondary : Theme.text)
        guard task.repeatRule != nil else { return words }
        return Text(Image(systemName: "repeat")).font(Theme.meta).foregroundStyle(Theme.secondary) + Text(" ") + words
    }
}

/// Forward the focus proxy's Space action to the existing native popup. Its
/// SwiftUI menu still owns every item, pointer action and context-menu action.
@MainActor
final class WeekMenuKeyboardTarget {
    weak var anchor: NSView?

    func popup() -> NSPopUpButton? {
        guard let anchor, let root = anchor.window?.contentView else { return nil }
        let rect = anchor.convert(anchor.bounds, to: root)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        @MainActor func candidates(_ view: NSView) -> [NSPopUpButton] {
            let own = (view as? NSPopUpButton).map { [$0] } ?? []
            return own + view.subviews.flatMap(candidates)
        }
        let matches = candidates(root).filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.isEnabled
                && $0.convert($0.bounds, to: root).contains(center)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func open() -> Bool {
        guard let popup = popup() else { return false }
        popup.performClick(nil)
        return true
    }
}

private struct WeekMenuKeyboardAnchor: NSViewRepresentable {
    let target: WeekMenuKeyboardTarget

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        target.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { target.anchor = view }
}

struct MiniComposer: View {
    let ref: DayRef
    @EnvironmentObject var store: PlannerStore
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        let prompt = AppL10n.text(ref == .inbox ? "Add to Inbox" : "Add a task")
        TextField("", text: $text)
            .textFieldStyle(.plain).font(Theme.body)
            .background(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .accessibilityLabel(prompt)
            .padding(.horizontal, Theme.gutter)
            .frame(minHeight: Theme.primaryHeight)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.fill))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.inputStroke, lineWidth: 1))
            .focused($focused).focusEffectDisabled()
            .overlay(ControlFocusRing(shape: RoundedRectangle(cornerRadius: Theme.controlRadius), focused: focused))
            .onSubmit {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                if store.addTasks([text], on: ref) != nil { text = "" }
            }
    }
}
#if DEBUG || PERCH_TESTING
    @MainActor enum WeekBoardPreview {
        static func expanded(_ app: AppDelegate) { show("week-expanded", expanded: true, app: app) }
        static func adding(_ app: AppDelegate) { show("week-adding", adding: true, app: app) }
        static func show(_ id: String, expanded: Bool = false, adding: Bool = false, app: AppDelegate) {
            let model = NotchModel()
            let next = app.store.today.adding(days: 1, calendar: app.store.engine.calendar)
            WindowHost.show(
                id, title: "Week",
                size: CGSize(width: DesignTokens.Size.weekWidth.value, height: WorkspaceLayout.sheetHeight)
            ) {
                DotGridSheet {
                    WeekBoard(initiallyExpanded: expanded, initiallyAdding: adding ? next : nil)
                }
                .environmentObject(app.store).environmentObject(model)
            }
        }
    }
#endif
