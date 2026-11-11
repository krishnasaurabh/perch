import AppKit
import PerchUI
import PlannerCore
import SwiftUI

/// A calendar week. Inbox has its own full-width view, not an eighth day.
struct WeekPage: View {
    @EnvironmentObject var store: PlannerStore
    @State private var anchor = 0
    @State private var showInbox = false
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
                    Text(anchor == 0 ? "This week" : "Week").font(Theme.heading)
                    Text(
                        AppL10n.format(
                            "%@ – %@", label(days[0], format: "MMM d"), label(days[6], format: "MMM d, yyyy"))
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
                    Motion.animate(Motion.page) { showInbox.toggle() }
                }
                .buttonStyle(PillStyle())
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
            if showInbox {
                column(title: "Inbox", subtitle: "Unscheduled", ref: .inbox, isToday: false, past: false)
            } else {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: Theme.gutter) {
                                ForEach(days, id: \.self) { day in
                                    column(
                                        title: label(day, format: "EEE"), subtitle: label(day, format: "MMM d"),
                                        ref: .day(day), isToday: day == store.today, past: day < store.today
                                    )
                                    .frame(width: WeekColumnLayout.columnWidth(available: geometry.size.width))
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
                Text("Scroll across seven days · Drag to reschedule · Only today’s tasks can be checked")
                    .font(Theme.meta).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Register the selected dates, not stale offsets from a previous logical week.
        // Observe only the range so task edits cannot reapply lifecycle mutations after Undo.
        .onChange(of: days, initial: true) { _, value in
            store.materializeRepeats(on: value)
        }
    }

    private func label(_ day: DayKey, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = store.engine.calendar
        formatter.timeZone = store.engine.calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: day.date(calendar: store.engine.calendar))
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
    @State private var bottoms: [UUID: CGFloat] = [:]
    @State private var viewport: CGFloat = 0
    private static let space = "week-day-list"
    private static let fade: CGFloat = 22

    var body: some View {
        let hidden = WeekColumnLayout.hiddenBelow(
            chipBottoms: tasks.compactMap { bottoms[$0.id].map { Double($0) } },
            viewport: Double(viewport))
        VStack(alignment: .leading, spacing: 3) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tasks) { t in
                        WeekChip(task: t, past: past)
                            .background(
                                GeometryReader { g in
                                    Color.clear.preference(
                                        key: ChipBottoms.self, value: [t.id: g.frame(in: .named(Self.space)).maxY])
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
            .onPreferenceChange(ChipBottoms.self) { bottoms = $0 }
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

    private struct ChipBottoms: PreferenceKey {
        static let defaultValue: [UUID: CGFloat] = [:]
        static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
            value.merge(nextValue()) { $1 }
        }
    }
}

struct WeekChip: View {
    let task: PlanTask
    let past: Bool
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var model: NotchModel
    @FocusState private var menuFocused: Bool

    private var completion: PlannerAction? { WeekTaskPolicy.completionAction(for: task, today: store.today) }
    private var checkHint: String {
        past ? WeekColumnLayout.pastHint : "Move this task to today before checking it."
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
            .focused($menuFocused).focusEffectDisabled()
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
            Button(task.done ? "Uncheck task" : "Check off task") { store.send(completion) }
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
