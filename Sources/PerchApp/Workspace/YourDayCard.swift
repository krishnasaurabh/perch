import AppKit
import PlannerCore
import PerchUI
import SwiftUI
import UniformTypeIdentifiers

/// Today's time-ordered schedule. Calendar access remains read-only; task moves use
/// the same command gateway as the checklist, so persistence and Undo are shared.
struct YourDayCard: View {
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var services: Services
    var meetingOverride: [YourDayTimeline.Meeting]?

    var body: some View {
        YourDayBody(calendar: services.calendar, meetingOverride: meetingOverride)
    }
}

private struct YourDayBody: View {
    @ObservedObject var calendar: CalendarService
    var meetingOverride: [YourDayTimeline.Meeting]?
    @State private var scheduleMeetings: [YourDayTimeline.Meeting] = []
    @EnvironmentObject private var store: PlannerStore
    @Environment(TodayHomeState.self) private var home

    var body: some View {
        LocalClock(running: true, interval: 60) { now in
            let timeline = makeTimeline(now: now)
            Card(.mint) {
                VStack(alignment: .leading, spacing: YourDayMetrics.gap) {
                    VStack(alignment: .leading, spacing: YourDayMetrics.detailGap) {
                        CardHeading(AppL10n.text("Your day"))
                        Text(summary(timeline)).perchFont(.detail).foregroundStyle(Theme.ink2)
                    }
                    ScrollView {
                        VStack(spacing: YourDayMetrics.rowGap) {
                            ForEach(timeline.items) { item in
                                YourDayRow(item: item, timeline: timeline)
                            }
                        }
                        .padding(YourDayMetrics.focusInset)
                    }
                    .scrollIndicators(.hidden)
                    if store.prefs.showCalendarMeetings && !calendar.hasAccess && meetingOverride == nil {
                        PerchButton("Show meetings", kind: .quiet, size: .small, surface: .mint) {
                            Task { await calendar.requestAccess() }
                        }
                        .help(AppL10n.text("Allow calendar access to show meetings in Your day."))
                    }
                    Text("Drag a task here to set time aside for it.")
                        .perchFont(.detail).foregroundStyle(Theme.ink2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .accessibilityIdentifier("your-day-card")
        .accessibilityHint(AppL10n.format("%@ and multi-day events stay in Calendar.", AppL10n.text("All day")))
        .task(id: store.today) { refreshCalendar() }
        .onReceive(calendar.$events) { _ in refreshCalendar() }
        .onChange(of: store.prefs.hiddenCalendarIDs) { _, _ in refreshCalendar() }
        .onChange(of: store.prefs.showCalendarMeetings) { _, show in if show { refreshCalendar() } }
    }

    private func refreshCalendar() {
        guard meetingOverride == nil, store.prefs.showCalendarMeetings else { return }
        scheduleMeetings = calendar.yourDayMeetings(
            day: store.today, calendar: store.engine.calendar, hiddenIDs: Set(store.prefs.hiddenCalendarIDs),
            completedIDs: store.planner.completedCalendarEventIDs)
    }

    private func makeTimeline(now: Date) -> YourDayTimeline {
        let meetings = (meetingOverride ?? scheduleMeetings).map {
            YourDayTimeline.Meeting(
                id: $0.id, title: $0.title, start: $0.start, end: $0.end, allDay: $0.allDay,
                done: store.planner.completedCalendarEventIDs.contains($0.id))
        }
        return YourDayTimeline(
            tasks: store.planner.tasks, meetings: store.prefs.showCalendarMeetings ? meetings : [],
            day: store.today, now: now, calendar: store.engine.calendar,
            resetHour: store.prefs.resetHour, defaultMinutes: store.prefs.defaultFocusMinutes,
            focus: store.planner.focus,
            preview: home.captureDraft.map { .init(start: $0.startTime, minutes: $0.minutes) })
    }

    private func summary(_ timeline: YourDayTimeline) -> String {
        if home.editingTaskID != nil { return AppL10n.text("Drag the block to move its time.") }
        let meetings =
            timeline.meetingCount == 1
            ? AppL10n.text("1 meeting")
            : AppL10n.format("%lld meetings", timeline.meetingCount)
        if timeline.blockCount == 0 {
            return timeline.meetingCount == 0
                ? AppL10n.text("The rest of today is open.")
                : AppL10n.format("%@. The rest is open.", meetings)
        }
        let blocks =
            timeline.blockCount == 1
            ? AppL10n.text("1 block set aside")
            : AppL10n.format("%lld blocks set aside", timeline.blockCount)
        return timeline.meetingCount == 0 ? blocks : AppL10n.format("%@, %@", blocks, meetings)
    }
}

private enum YourDayMetrics {
    static let gap = DesignTokens.Size.cardGap.value
    static let rowGap = DesignTokens.Size.cardPadding.value / 2
    static let detailGap = DesignTokens.Size.focusGap.value
    static let inset = DesignTokens.Size.cardPadding.value / 2
    static let radius = DesignTokens.Size.segmentRadius.value
    static let barWidth = DesignTokens.Size.checkboxStroke.value * 2
    static let timeWidth = DesignTokens.Size.buttonHeight.value + DesignTokens.Size.stepCheckboxRadius.value
    static let focusInset = DesignTokens.Size.focusGap.value + DesignTokens.Size.focusWidth.value
}

private struct YourDayRow: View {
    let item: YourDayTimeline.Item
    let timeline: YourDayTimeline
    @EnvironmentObject private var store: PlannerStore
    @Environment(TodayHomeState.self) private var home
    @FocusState private var focused: Bool
    @State private var rowHeight = DesignTokens.Size.minimumTarget.value
    @State private var targeted = false

    private var editing: Bool { item.taskID != nil && home.editingTaskID == item.taskID }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: YourDayMetrics.radius) }

    var body: some View {
        HStack(alignment: .top, spacing: YourDayMetrics.rowGap) {
            Text(time(item.start)).perchFont(item.running || editing ? .detailStrong : .detail)
                .foregroundStyle(item.kind == .preview ? Theme.brandText : Theme.ink2)
                .frame(width: YourDayMetrics.timeWidth, alignment: .trailing)
                .padding(.top, YourDayMetrics.inset)
                .accessibilityHidden(true)
            control
        }
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { rowHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in rowHeight = height }
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: TaskDragItem.self) { items, point in
            guard items.count == 1, let drag = items.first else { return false }
            let start = timeline.dropTime(
                in: item, fraction: point.y / max(1, rowHeight), calendar: store.engine.calendar)
            return YourDayActions.setStart(drag.taskID, at: start, store: store)
        } isTargeted: {
            targeted = $0
        }
    }

    @ViewBuilder private var control: some View {
        if let id = item.taskID {
            Button {
                home.selectedTaskID = id
                home.editingTaskID = id
            } label: {
                pill
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .overlay(FocusRing(shape: shape, focused: focused, surface: .mint))
            .draggable(TaskDragItem(taskID: id))
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(AppL10n.text("Option Up or Option Down moves the block by 15 minutes."))
            .accessibilityIdentifier("your-day-task-\(id)")
            .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { key in
                guard key.modifiers.contains(.option) else { return .ignored }
                move(minutes: key.key == .upArrow ? -YourDayTimeline.snapMinutes : YourDayTimeline.snapMinutes)
                return .handled
            }
            .contextMenu {
                Button("Move 15 minutes earlier") { move(minutes: -YourDayTimeline.snapMinutes) }
                Button("Move 15 minutes later") { move(minutes: YourDayTimeline.snapMinutes) }
            }
            .accessibilityAction(named: Text("Move 15 minutes earlier")) { move(minutes: -YourDayTimeline.snapMinutes) }
            .accessibilityAction(named: Text("Move 15 minutes later")) { move(minutes: YourDayTimeline.snapMinutes) }
        } else if item.kind == .meeting {
            Button(action: toggleMeeting) { pill }
                .buttonStyle(.plain).focusable().focused($focused).focusEffectDisabled()
                .overlay(FocusRing(shape: shape, focused: focused, surface: .mint))
                .accessibilityLabel(accessibilityLabel)
                .help(AppL10n.text("Mark complete in Perch (Calendar is unchanged)"))
                .contextMenu {
                    Button(
                        item.done ? "Mark incomplete in Perch" : "Mark complete in Perch (Calendar is unchanged)",
                        action: toggleMeeting)
                }
        } else {
            pill.accessibilityElement(children: .ignore).accessibilityLabel(accessibilityLabel)
        }
    }

    private var pill: some View {
        HStack(alignment: .center, spacing: YourDayMetrics.detailGap) {
            VStack(alignment: .leading, spacing: YourDayMetrics.detailGap) {
                if item.kind == .task || item.kind == .meeting {
                    Text(item.title).perchFont(.detailStrong)
                        .strikethrough(item.done).foregroundStyle(item.done ? Theme.ink3 : Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(detail).perchFont(.detail)
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
                if item.carried && !item.done {
                    Text("Carried over").perchFont(.detail).foregroundStyle(Theme.carried)
                }
                if item.overlaps {
                    Text("Overlaps another block").perchFont(.detail).foregroundStyle(Theme.ink2)
                }
            }
            Spacer(minLength: .zero)
            if editing {
                Image(systemName: "circle.grid.2x3.fill").foregroundStyle(Theme.brandText)
                    .perchFont(.detailStrong).accessibilityHidden(true)
            }
        }
        .padding(YourDayMetrics.inset)
        .frame(maxWidth: .infinity, minHeight: DesignTokens.Size.minimumTarget.value, alignment: .leading)
        .background(shape.fill(fill))
        .overlay {
            shape.strokeBorder(
                outline,
                style: StrokeStyle(
                    lineWidth: DesignTokens.Size.cardEdge.value,
                    dash: item.kind == .gap || item.kind == .preview
                        ? [YourDayMetrics.barWidth, YourDayMetrics.barWidth] : []))
        }
        .overlay(alignment: .leading) {
            if item.running {
                Rectangle().fill(Theme.brandFill).frame(width: YourDayMetrics.barWidth)
            }
        }
        .clipShape(shape)
    }

    private var fill: Color {
        if editing { return Theme.butter }
        return item.kind == .task && !item.done ? Theme.paper : .clear
    }
    private var outline: Color {
        if editing || targeted || item.kind == .preview { return Theme.brandText }
        if item.kind == .meeting { return Theme.ink }
        return item.kind == .gap ? Theme.ink2 : .clear
    }
    private var detailColor: Color {
        item.running || item.kind == .preview ? Theme.brandText : item.done ? Theme.ink3 : Theme.ink2
    }
    private var detail: String {
        switch item.kind {
        case .gap:
            return item.minutes == YourDayTimeline.snapMinutes
                ? AppL10n.text("Free for 15 min")
                : AppL10n.format("Open until %@", time(item.end))
        case .preview: return AppL10n.format("Will land here, %lld min", item.minutes)
        case .meeting: return AppL10n.format("Meeting, %@", duration)
        case .task:
            if item.running { return AppL10n.format("Now, until %@", time(item.end)) }
            if editing { return AppL10n.format("%@, until %@", duration, time(item.end)) }
            return duration
        }
    }
    private var duration: String {
        item.minutes > 0 && item.minutes % 60 == 0
            ? AppL10n.format("%lld hr", item.minutes / 60)
            : AppL10n.format("%lld min", item.minutes)
    }
    private var accessibilityLabel: String {
        [
            time(item.start), item.title, detail, item.carried ? AppL10n.text("Carried over") : "",
            item.done ? AppL10n.text("Done") : "", item.overlaps ? AppL10n.text("Overlaps another block") : "",
        ]
        .filter { !$0.isEmpty }.joined(separator: ", ")
    }
    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = store.engine.calendar
        formatter.timeZone = store.engine.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        formatter.amSymbol = ""; formatter.pmSymbol = ""
        return formatter.string(from: date).trimmingCharacters(in: .whitespaces)
    }
    private func toggleMeeting() {
        let eventID = String(item.id.dropFirst("meeting:".count))
        store.apply { try $0.setCalendarEventCompleted(eventID, completed: !item.done) }
    }
    private func move(minutes: Int) {
        guard let id = item.taskID else { return }
        let current = store.planner.tasks.first { $0.id == id }?.startAt ?? item.start
        let next = timeline.snapped(current.addingTimeInterval(Double(minutes * 60)), calendar: store.engine.calendar)
        _ = YourDayActions.setStart(id, at: next, store: store)
    }
}

/// The existing service supplies both civil days spanned by a logical planner day.
/// Fetching does not overwrite its ordinary civil-day events used by other features.
extension CalendarService {
    func yourDayMeetings(day: DayKey, calendar: Calendar, hiddenIDs: Set<String>, completedIDs: Set<String>)
        -> [YourDayTimeline.Meeting]
    {
        guard hasAccess else { return [] }
        let selected = source.calendars().filter { !hiddenIDs.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { return [] }
        let first = day.date(calendar: calendar)
        let next = day.adding(days: 1, calendar: calendar).date(calendar: calendar)
        let events = source.events(on: first, calendars: selected) + source.events(on: next, calendars: selected)
        var seen: Set<String> = []
        return events.filter { seen.insert($0.id).inserted }.map {
            YourDayTimeline.Meeting(
                id: $0.id, title: $0.title, start: $0.start, end: $0.end,
                allDay: $0.allDay, done: completedIDs.contains($0.id))
        }
    }
}

/// The legacy checklist still exports text for its reorder and Week drop targets.
/// Add the typed identity alongside it rather than changing those existing contracts.
@MainActor enum YourDayTaskDrag {
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

/// A zero-layout bridge lets the existing capture field publish its parsed schedule
/// without owning a second draft or changing capture behavior on Week and Inbox.
struct YourDayCaptureBridge: View {
    let text: String
    let day: DayRef
    @EnvironmentObject private var store: PlannerStore
    @Environment(TodayHomeState.self) private var home: TodayHomeState?

    var body: some View {
        Color.clear.frame(width: .zero, height: .zero)
            .onAppear(perform: update)
            .onChange(of: text) { _, _ in update() }
            .onChange(of: day) { _, _ in update() }
            .onDisappear { home?.captureDraft = nil }
    }

    private func update() {
        guard let home else { return }
        YourDayCapture.update(text: text, day: day, home: home, store: store)
    }
}

@MainActor enum YourDayCapture {
    static func update(
        text: String, day: DayRef, home: TodayHomeState, store: PlannerStore,
        language: TaskParserLanguage? = .current
    ) {
        guard day == .day(store.today), let language else { home.captureDraft = nil; return }
        let parsed = store.capture.parse(text, language: language)
        guard !parsed.inbox, let start = parsed.startAt,
            DayKey(start, resetHour: store.prefs.resetHour, calendar: store.engine.calendar) == store.today
        else { home.captureDraft = nil; return }
        home.captureDraft = .init(startTime: start, minutes: parsed.minutes ?? store.prefs.defaultFocusMinutes)
    }
}

@MainActor enum YourDayActions {
    @discardableResult static func setStart(_ id: UUID, at start: Date, store: PlannerStore) -> Bool {
        // Do not move history, unscheduled inbox items or a concurrently removed task.
        guard let task = store.planner.tasks.first(where: { $0.id == id }), task.day == store.today,
            DayKey(start, resetHour: store.prefs.resetHour, calendar: store.engine.calendar) == store.today
        else { return false }
        return store.apply { commands in
            try commands.updateTask(id) { $0.startAt = start }
            return true
        } ?? false
    }
}

#if DEBUG || PERCH_TESTING
    @MainActor enum YourDayPreview {
        static func show(app: AppDelegate, editing: Bool = false, capture: Bool = false, overlap: Bool = false) {
            let state = TodayHomeState()
            let day = app.store.today
            let calendar = app.store.engine.calendar
            let base = day.date(calendar: calendar)
            func at(_ hour: Int, _ minute: Int = 0) -> Date {
                calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
            }
            if editing { state.editingTaskID = app.store.planner.tasks.first { $0.minutes == 45 }?.id }
            if capture { state.captureDraft = .init(startTime: at(13, 30), minutes: 20) }
            var meetings = [
                YourDayTimeline.Meeting(id: "preview-review", title: "Design review", start: at(14), end: at(15))
            ]
            if overlap {
                meetings.append(.init(id: "preview-overlap", title: "Planning", start: at(10, 15), end: at(11)))
            }
            let content = DotGridSheet {
                YourDayCard(meetingOverride: meetings)
            }
            .environment(state).environmentObject(app.store).environmentObject(app.services)
            .environment(\.colorScheme, PreviewAppearance.scheme ?? .light)
            let size = CGSize(
                width: HomeLayout.columns(sheetWidth: DesignTokens.Size.todayWidth.value).day
                    + DesignTokens.Size.sheetPadding.value * 2,
                height: WorkspaceLayout.preferredSize(page: .today, menuBarHeight: .zero).height)
            let id = "your-day-preview"
            if let window = WindowHost.windows[id] {
                window.contentView = NSHostingView(rootView: content.previewEnvironment())
                window.setContentSize(size)
            }
            WindowHost.show(id, title: "Your day", size: size) { content }
        }
    }
#endif
