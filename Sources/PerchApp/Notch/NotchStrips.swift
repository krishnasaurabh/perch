import AppKit
import Combine
import PlannerCore
import PerchUI
import SwiftUI

/// Presentation ownership stays separate from OS delivery. All producers feed the
/// same portable queue, including external agent edits and local deletion Undo.
@MainActor
final class NotchStrips {
    typealias Action = NotchStripAction

    private weak var store: PlannerStore?
    private weak var model: NotchModel?
    private weak var calendar: CalendarService?
    private weak var reminders: ReminderService?
    private let now: () -> Date
    private let agentFloor: Date
    private var subscriptions = Set<AnyCancellable>()
    private var wake: Timer?
    private(set) var nextWake: Date?
    private var queue = NotchStripQueue()
    private var cards: [String: PresentedNotchActivity] = [:]
    private var oneOffs: [String: (NotchStripQueue.Item, PresentedNotchActivity)] = [:]
    private var deletionUndos: [String: NotchDeletionUndo] = [:]
    private var recovery: PlannerRecoveryError?
    private var recoveryBackupDate: Date?
    private var inspectedError: PerchAppError?
    private var waitingReminders = Set<String>()
    private var updating = false
    private var visibleID: UUID?
    private(set) var currentActivity: PresentedNotchActivity?
    private(set) var hasCompletionUndo = false
    private(set) var bounds: CGRect = .zero

    static func install(store: PlannerStore, calendar: CalendarService, reminders: ReminderService, model: NotchModel) {
        model.strips = NotchStrips(store: store, calendar: calendar, reminders: reminders, model: model)
    }

    init(
        store: PlannerStore, calendar: CalendarService? = nil, reminders: ReminderService? = nil,
        model: NotchModel, now: (() -> Date)? = nil
    ) {
        self.store = store; self.calendar = calendar; self.reminders = reminders; self.model = model
        self.now = now ?? { [weak store] in store?.engine.now() ?? Date() }
        self.agentFloor = (now?() ?? store.engine.now()).addingTimeInterval(-NotchStripQueue.Kind.agentChange.timeout!)
        store.stripDidCommit = { [weak self] before, after, origin in self?.committed(before, after, origin: origin) }
        store.stripHistoryChanged = { [weak self] in self?.invalidateDeletionUndo() }
        store.$planner.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        store.$lastError.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        calendar?.$events.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        model.$activity.receive(on: RunLoop.main).sink { [weak self] activity in self?.legacyChanged(activity) }
            .store(in: &subscriptions)
        for centerAndName in [
            (NotificationCenter.default, Notification.Name.NSSystemClockDidChange),
            (NotificationCenter.default, Notification.Name.NSCalendarDayChanged),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
        ] {
            centerAndName.0.publisher(for: centerAndName.1).receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.calendar?.refresh(day: self.now())
                    self.refresh()
                }.store(in: &subscriptions)
        }
        refresh()
    }

    private func invalidateDeletionUndo() {
        oneOffs = oneOffs.filter { $0.value.0.kind != .undo }
        refresh()
    }

    private func committed(_ before: Planner, _ after: Planner, origin: PlannerCommandOrigin) {
        // Never offer a generic Undo for an external deletion or after a newer edit.
        if origin == .user || before.agentActions.sequence != after.agentActions.sequence {
            oneOffs = oneOffs.filter { $0.value.0.kind != .undo }
        }
        if before.agentActions.sequence != after.agentActions.sequence { hasCompletionUndo = false }
        guard origin == .user, before.agentActions.sequence == after.agentActions.sequence else { return }
        let removed = before.tasks.filter { old in !after.tasks.contains { $0.id == old.id } }
        if before != after {
            hasCompletionUndo =
                removed.isEmpty
                && before.tasks.contains { old in
                    after.tasks.contains { $0.id == old.id && $0.done != old.done }
                }
        }
        guard !removed.isEmpty else { return }
        let id = "undo:\(UUID())", date = now()
        let title =
            removed.count == 1
            ? AppL10n.format("Deleted ‘%@’", removed[0].title)
            : AppL10n.format("Deleted %lld tasks", removed.count)
        var card = PresentedNotchActivity(kind: .strip(.undo, id), title: title, subtitle: "", stripID: id)
        card.titles = removed.map(\.title)
        card.affectedTaskIDs = removed.map(\.id)
        oneOffs[id] = (.init(id: id, kind: .undo, createdAt: date), card)
        deletionUndos[id] = NotchDeletionUndo(after: after, taskIDs: card.affectedTaskIDs)
    }

    /// Preserve producer-specific confirmation durations while routing every
    /// activity through the same priority policy. Reminder identity stays per due occurrence.
    func enqueueLegacy(_ activity: PresentedNotchActivity, timeout: TimeInterval? = nil) {
        if case .reminder(let taskID) = activity.kind,
            let task = store?.planner.tasks.first(where: { $0.id == taskID }), task.remindAt != nil
        {
            waitingReminders.insert(ScheduledReminder(task: task).id)
            refresh(); return
        }
        if case .focusDone = activity.kind { refresh(); return }
        let id = "legacy:\(activity.id)"
        var card = activity; card.stripID = id
        oneOffs[id] = (.init(id: id, kind: card.stripKind, createdAt: now(), timeout: timeout), card)
        refresh()
    }

    /// Legacy callers still work, but cannot replace a higher-priority occurrence.
    private func legacyChanged(_ activity: PresentedNotchActivity?) {
        guard !updating, let model else { return }
        if activity?.id == visibleID { return }
        // A deferred publication may describe an older value. Read only the current one.
        guard activity == model.activity else { return }
        if let activity, activity.stripID == nil {
            enqueueLegacy(activity); return
        } else if activity == nil, let id = currentActivity?.stripID {
            queue.answer(id, at: now())
        }
        refresh()
    }

    func refresh() {
        guard !updating, let store, let model else { return }
        updating = true
        defer { updating = false }
        wake?.invalidate(); wake = nil
        let date = now(), planner = store.planner
        var items: [NotchStripQueue.Item] = []
        var content: [String: PresentedNotchActivity] = [:]
        var boundaries: [Date] = []
        func add(_ item: NotchStripQueue.Item, _ original: PresentedNotchActivity) {
            var card = original
            card.stripID = item.id
            card.id = cards[item.id]?.id ?? original.id
            items.append(item); content[item.id] = card
        }
        inspectRecovery(in: store)
        if let recovery {
            let id = "data:\(recovery.quarantineURL.path)"
            let count = Set(
                recovery.issues.filter { $0.path.hasPrefix("tasks[") }.map { $0.path.components(separatedBy: "]")[0] }
            ).count
            let title =
                count == 1
                ? AppL10n.text("Perch couldn't read 1 task")
                : (count > 0
                    ? AppL10n.format("Perch couldn't read %lld tasks", count)
                    : AppL10n.text("Perch couldn't read some data"))
            var card = PresentedNotchActivity(
                kind: .strip(.dataProblem, id), title: title,
                subtitle: AppL10n.format(
                    "The original is safe at %@. The readable tasks are here.", recovery.quarantineURL.path))
            card.recoveryCount = count
            let morning =
                recoveryBackupDate.map {
                    store.engine.calendar.isDate($0, inSameDayAs: date)
                        && store.engine.calendar.component(.hour, from: $0) < 12
                } == true
            card.restoreLabel = AppL10n.text(morning ? "Restore this morning's backup" : "Restore latest backup")
            add(.init(id: id, kind: .dataProblem, createdAt: .distantPast), card)
        }
        let reminderTasks = NotchStripPolicy.reminders(
            in: planner, at: date, records: reminders?.records ?? [:], waiting: waitingReminders)
        waitingReminders = Set(reminderTasks.map { ScheduledReminder(task: $0).id })
        for task in reminderTasks {
            let due = task.remindAt!, id = ScheduledReminder(task: task).id
            var card = PresentedNotchActivity(
                kind: .reminder(task.id), title: AppL10n.format("Time for ‘%@’", task.title),
                subtitle: AppL10n.format(
                    "You asked to be reminded at %@.", due.formatted(date: .omitted, time: .shortened)),
                taskID: task.id)
            if NotchReminderPresentation.isMissed(task: task, records: reminders?.records ?? [:], now: date) {
                card.subtitle += " " + AppL10n.text("Delivery was not confirmed.")
            }
            let deadline =
                planner.preferences.persistentReminders
                ? nil : due.addingTimeInterval(NotchActivityTimeline.reminderDuration)
            add(.init(id: id, kind: .reminder, createdAt: due, deadline: deadline), card)
        }
        boundaries += planner.tasks.filter { !$0.done && $0.day != nil }.compactMap(\.remindAt).filter { $0 > date }
        if let focus = planner.focus {
            let task = focus.taskID.flatMap { id in planner.tasks.first { $0.id == id } }
            let sessionID = "\(focus.startedAt.timeIntervalSinceReferenceDate):\(focus.taskID?.uuidString ?? "block")"
            let summary =
                task.map {
                    AppL10n.format(
                        "%@ · %lld of %lld steps done", $0.title, $0.steps.filter(\.done).count, $0.steps.count)
                } ?? ""
            if NotchStripPolicy.showsBlockEnded(in: planner) {
                let id = "ended:\(sessionID):\(focus.limit ?? 0)"
                let endedAt = NotchStripPolicy.blockEndedAt(in: planner) ?? date
                let thoughts = NotchStripPolicy.parkedDuringBlock(in: planner)
                add(
                    .init(id: id, kind: .blockEnded, createdAt: endedAt),
                    .init(
                        kind: .focusDone(focus.taskID), title: AppL10n.text("Time's up on this block"),
                        subtitle: summary,
                        taskID: focus.taskID, titles: thoughts.map(\.text), thoughtIDs: thoughts.map(\.id)))
            }
            if let ends = NotchStripPolicy.headsUp(in: planner, at: date) {
                let id = "heads-up:\(sessionID):\(focus.limit ?? 0):\(planner.preferences.blockHeadsUp.rawValue)"
                add(
                    .init(
                        id: id, kind: .headsUp,
                        createdAt: ends.addingTimeInterval(-Double(planner.preferences.blockHeadsUp.rawValue * 60)),
                        deadline: ends),
                    .init(
                        kind: .strip(.headsUp, id),
                        title: AppL10n.format(
                            "%lld minutes left on this block", planner.preferences.blockHeadsUp.rawValue),
                        subtitle: summary, taskID: focus.taskID))
            }
            if focus.state == .running, let remaining = focus.remaining(at: date) {
                let end = date.addingTimeInterval(remaining)
                boundaries.append(end)
                if planner.preferences.blockHeadsUp != .off {
                    boundaries.append(end.addingTimeInterval(-Double(planner.preferences.blockHeadsUp.rawValue * 60)))
                }
            }
        }
        for event in calendar?.events ?? [] where planner.preferences.showCalendarMeetings && !event.allDay {
            let begins = event.start.addingTimeInterval(-Double(planner.preferences.meetingHeadsUp.rawValue * 60))
            let ends = event.start.addingTimeInterval(NotchActivityTimeline.lateGrace)
            guard ends > date else { continue }
            boundaries += [begins, event.start, ends]
            let id = "meeting:\(event.id):\(event.start.timeIntervalSinceReferenceDate)"
            add(
                .init(id: id, kind: .headsUp, createdAt: begins, deadline: ends),
                .init(
                    kind: .eventSoon(id), title: event.title,
                    subtitle: date < event.start
                        ? NotchTimelineDriver.countdown(to: event.start, now: date) : AppL10n.text("Starting now"),
                    eventStart: event.start))
        }
        for pending in planner.agentActions.pending(at: date) {
            let id = "approval:\(pending.id)"
            add(
                .init(id: id, kind: .agentChange, createdAt: pending.createdAt, deadline: pending.expiresAt),
                .init(
                    kind: .strip(.agentChange, id),
                    title: AppL10n.format("%@ wants to delete ‘%@’", agentName(pending.agentID), pending.task.title),
                    subtitle: AppL10n.text("Keep applies this request. Undo leaves the task unchanged."),
                    titles: [pending.task.title]))
        }
        for change in planner.agentActions.changes where change.undoneAt == nil && change.occurredAt >= agentFloor {
            let id = "agent:\(change.id)"
            let verb: String
            switch change.operation {
            case "add_tasks":
                if change.tasks.allSatisfy({ $0.day == store.today }) {
                    verb =
                        change.tasks.count == 1
                        ? AppL10n.format("%@ added 1 task to today", agentName(change.agentID))
                        : AppL10n.format("%@ added %lld tasks to today", agentName(change.agentID), change.tasks.count)
                } else {
                    verb =
                        change.tasks.count == 1
                        ? AppL10n.format("%@ added 1 task", agentName(change.agentID))
                        : AppL10n.format("%@ added %lld tasks", agentName(change.agentID), change.tasks.count)
                }
            case "delete_task":
                verb =
                    change.tasks.count == 1
                    ? AppL10n.format("%@ deleted 1 task", agentName(change.agentID))
                    : AppL10n.format("%@ deleted %lld tasks", agentName(change.agentID), change.tasks.count)
            default: verb = AppL10n.format("%@ made a change", agentName(change.agentID))
            }
            add(
                .init(id: id, kind: .agentChange, createdAt: change.occurredAt),
                .init(
                    kind: .strip(.agentChange, id), title: verb, subtitle: "", titles: change.tasks.map(\.title)))
            // Keep the source alive while the queue spends its visible-time budget.
        }
        for (id, pair) in oneOffs {
            if pair.0.kind == .undo && deletionUndos[id]?.isValid(in: planner) != true {
                oneOffs[id] = nil
            } else {
                add(pair.0, pair.1)
            }
        }
        if planner.agentActions.pending.contains(where: { $0.expiresAt <= date }) {
            _ = store.performMutation(origin: .background) { try $0.expireAgentActions(at: date) }
        }
        queue.reconcile(items, at: date)
        cards = content
        let pendingIDs = Set(queue.pending.map(\.id))
        oneOffs = oneOffs.filter { pendingIDs.contains($0.key) }
        deletionUndos = deletionUndos.filter { oneOffs[$0.key] != nil }
        let current = queue.current.flatMap { content[$0.id] }
        currentActivity = current
        if current == nil { bounds = .zero }
        visibleID = current?.id
        if model.activity != current { model.showStrip(current) }
        let next = (boundaries + [queue.nextChange].compactMap { $0 }).filter { $0 > date }.min()
        nextWake = next
        if let next, PreviewClock.date == nil {
            let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common); wake = timer
        }
    }

    private func inspectRecovery(in store: PlannerStore) {
        guard store.lastError != inspectedError else { return }
        inspectedError = store.lastError; recovery = nil; recoveryBackupDate = nil
        guard store.lastError != nil else { return }
        do { _ = try store.file.avoidingLockWaits().load() } catch let failure as PlannerRecoveryError {
            recovery = failure
            if let backup = try? store.file.avoidingLockWaits().backupURLs().first {
                recoveryBackupDate = try? backup.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            }
        } catch { /* Non-recovery errors stay in the existing error presentation. */  }
    }

    private func agentName(_ id: String) -> String {
        if id.localizedCaseInsensitiveContains("claude") || id == "sample-agent" { return AppL10n.text("Claude") }
        if id.localizedCaseInsensitiveContains("cursor") { return AppL10n.text("Cursor") }
        return AppL10n.text("An agent")
    }

    func setBounds(_ size: CGSize, geometry: NotchGeometry) {
        let next = CGRect(
            x: geometry.notchRect.midX - size.width / 2, y: geometry.notchRect.maxY - size.height, width: size.width,
            height: size.height)
        guard bounds != next else { return }
        bounds = next
        model?.objectWillChange.send()
    }

    func contains(_ point: CGPoint, on screenID: CGDirectDisplayID) -> Bool? {
        guard let model, model.screenID == screenID, currentActivity != nil else { return nil }
        return NotchLayout.contains(bounds, pointer: point) ? true : (model.expanded ? nil : false)
    }

    func setShelfVisible(_ visible: Bool) {
        let id = "drop-shelf"
        if visible, oneOffs[id] == nil {
            oneOffs[id] = (
                .init(id: id, kind: .dropShelf, createdAt: now()),
                .init(
                    kind: .strip(.dropShelf, id), title: AppL10n.text("Drop it here to keep it handy"), subtitle: "",
                    stripID: id)
            )
        } else if !visible {
            oneOffs[id] = nil
        }
        refresh()
    }

    func fraction(at date: Date) -> Double { queue.remainingFraction(at: date) }

    func answer(_ action: Action, activity: PresentedNotchActivity) -> Bool {
        guard let store, let id = activity.stripID, currentActivity?.stripID == id else { return false }
        let date = now(), originalPlanner = store.planner
        let success: Bool
        var acknowledgedChanges: [UUID] = []
        if action == .notNow || action == .keep && !id.hasPrefix("approval:") {
            success = true
        } else if id.hasPrefix("approval:"), let request = UUID(uuidString: String(id.dropFirst("approval:".count))) {
            let applied = store.apply { commands in
                let previous = Set(commands.planner.agentActions.changes.map(\.id))
                try commands.resolveAgentAction(request, decision: action == .keep ? .keep : .undo, at: date)
                return commands.planner.agentActions.changes.filter { !previous.contains($0.id) }.map(\.id)
            }
            success = applied != nil
            acknowledgedChanges = applied ?? []
        } else if id.hasPrefix("agent:"), let change = UUID(uuidString: String(id.dropFirst("agent:".count))) {
            success = store.apply { try $0.undoAgentChange(change, at: date) } != nil
        } else if action == .undo {
            guard store.flushPendingText() else { return false }
            refresh()
            guard currentActivity?.stripID == id, let offer = deletionUndos[id] else { return false }
            // The pipeline validates the offer and applies only its local inverse
            // under one lock; no separate preflight can race a writer into generic Undo.
            success = store.undoLocalDeletion(offer)
            if !success, store.lastError == nil {
                invalidateDeletionUndo()
                store.reloadFromDisk(external: true)
                refresh()
            }
        } else {
            success = Self.perform(action, taskID: activity.taskID, thoughtIDs: activity.thoughtIDs, in: store)
        }
        if success {
            // A snooze changes remindAt, so acknowledge the occurrence shown before the command.
            if case .reminder = activity.kind { model?.dismissPresentedActivity(in: originalPlanner) }
            for change in acknowledgedChanges { queue.answer("agent:\(change)", at: date) }
            queue.answer(id, at: date)
            oneOffs[id] = nil
            refresh()
        }
        return success
    }

    func showRecoveryFiles() {
        if let recovery {
            NSWorkspace.shared.activateFileViewerSelecting([recovery.quarantineURL, recovery.issuesURL])
        }
    }

    func restoreBackup() -> Bool {
        guard let store, store.flushPendingText() else { return false }
        do {
            try store.restoreLatestBackup()
            inspectedError = nil; recovery = nil
            refresh(); return true
        } catch {
            store.lastError = .planner(error.perchPresentationDetail); return false
        }
    }

    static func blockFinished(store: PlannerStore, model: NotchModel, services: Services) {
        if store.prefs.focusCompletionSound { NSSound(named: "Glass")?.play() }
        model.strips?.refresh()
        guard store.prefs.blockEndAction != .doNothing else { return }
        services.reminders.notify(
            id: "block-ended-\(UUID())",
            title: AppL10n.text(
                store.prefs.blockEndAction == .takeBreak ? "Time for a break." : "Time's up on this block"), body: "")
    }

    @discardableResult
    static func perform(_ action: Action, taskID: UUID?, thoughtIDs: [UUID] = [], in store: PlannerStore) -> Bool {
        store.apply { commands in
            try NotchStripActions.perform(action, taskID: taskID, thoughtIDs: thoughtIDs, commands: commands)
        } != nil
    }
}

@MainActor
extension NotchModel {
    func showStrip(_ card: PresentedNotchActivity?) {
        if let card {
            if case .reminder(let id) = card.kind { closedReminderIDs.insert(id) }
            if activity?.stripID == card.stripID { activity = card } else { show(card) }
        } else if activity != nil {
            dismissActivity()
        }
    }
}

/// Resolve the app's system appearance rather than the fixed-black housing's
/// local environment. KVO is released with the native view; callbacks retain neither.
struct StripAppearanceBridge: NSViewRepresentable {
    let changed: (ColorScheme) -> Void
    func makeNSView(context: Context) -> AppearanceView {
        let view = AppearanceView(); view.changed = changed; return view
    }
    func updateNSView(_ view: AppearanceView, context: Context) { view.changed = changed; view.refresh() }

    @MainActor final class AppearanceView: NSView {
        var changed: ((ColorScheme) -> Void)?
        private var observation: NSKeyValueObservation?
        private var lastScheme: ColorScheme?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if observation == nil {
                observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
            }
            refresh()
        }
        func refresh() {
            let scheme: ColorScheme =
                NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
            guard lastScheme != scheme else { return }; lastScheme = scheme
            Task { @MainActor [weak self] in self?.changed?(scheme) }
        }
    }
}

struct NotchStripClock<Content: View>: View {
    let running: Bool
    var interval: TimeInterval = NotchStripMetrics.clockInterval
    @ViewBuilder var content: @MainActor (Date) -> Content
    var body: some View {
        if running {
            TimelineView(.periodic(from: .now, by: interval)) { context in
                content(PreviewClock.date ?? context.date)
            }
        } else {
            content(PreviewClock.date ?? Date())
        }
    }
}

/// Only the one strip is measured. This layout is never used inside task rows.
private struct NotchStripFittingLayout: Layout {
    let kind: NotchStripQueue.Kind
    func makeCache(subviews: Subviews) -> CGSize { .zero }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CGSize) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(.unspecified)
        let width = NotchStripMetrics.fittedWidth(for: kind, ideal: ideal.width)
        let fitted = content.sizeThatFits(.init(width: width, height: nil))
        cache = CGSize(width: width, height: fitted.height)
        return cache
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CGSize) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading, proposal: .init(width: cache.width, height: cache.height))
    }
}

/// Actual strip surface, including the runtime-height housing band. Its measured
/// size is the controller's pointer region, not an independently guessed frame.
struct NotchStripLayer: View {
    let activity: PresentedNotchActivity
    @EnvironmentObject private var model: NotchModel
    @EnvironmentObject private var screen: NotchScreenState
    @Environment(\.motionPolicy) private var motionPolicy

    var body: some View {
        NotchStripFittingLayout(kind: activity.stripKind) {
            VStack(spacing: .zero) {
                Theme.band.frame(
                    height: DesignTokens.bandHeight(
                        menuBarHeight: max(screen.geometry.screen.menuBarHeight, screen.geometry.notchSize.height)))
                ActivityStrip(activity: activity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(
            UnevenRoundedRectangle(
                bottomLeadingRadius: NotchStripMetrics.bottomRadius,
                bottomTrailingRadius: NotchStripMetrics.bottomRadius)
        )
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear { model.strips?.setBounds(proxy.size, geometry: screen.geometry) }
                    .onChange(of: proxy.size) { _, size in model.strips?.setBounds(size, geometry: screen.geometry) }
                    .onChange(of: screen.geometry) { _, geometry in
                        model.strips?.setBounds(proxy.size, geometry: geometry)
                    }
            }
        )
        .frame(width: screen.geometry.window.width, alignment: .top)
        .offset(
            x: screen.geometry.notchRect.midX - screen.geometry.window.midX,
            y: screen.geometry.window.maxY - screen.geometry.notchRect.maxY
        )
        .transition(
            .asymmetric(
                insertion: motionPolicy.reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity),
                removal: .opacity))
    }
}

/// Shared strip content used in the live notch and the deterministic shot hosts.
struct NotchStripContent: View {
    let activity: PresentedNotchActivity
    let fraction: Double
    let action: (NotchStrips.Action) -> Void
    let showFiles: () -> Void
    let restore: () -> Void
    @EnvironmentObject private var store: PlannerStore

    private var kind: NotchStripQueue.Kind { activity.stripKind }
    private var surface: DesignTokens.Surface { kind.surface }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchStripMetrics.gap) {
            if kind == .undo {
                HStack(spacing: NotchStripMetrics.gap) {
                    Text(activity.title).perchFont(.stripTitle)
                    Spacer(minLength: .zero)
                    NotchUndoAction(action: { action(.undo) })
                    Text("⌘Z").perchFont(.detail).foregroundStyle(Theme.ink2)
                }
                GeometryReader { proxy in
                    Rectangle().fill(Theme.ink2)
                    Rectangle().fill(Theme.brandText).frame(width: proxy.size.width * fraction)
                }.frame(height: NotchStripMetrics.progressHeight).accessibilityHidden(true)
            } else {
                if kind == .headsUp {
                    HStack(spacing: NotchStripMetrics.gap) {
                        heading
                        if case .eventSoon = activity.kind { EmptyView() } else { actions }
                        NotchStripCloseButton { action(.notNow) }
                    }
                } else if kind == .agentChange {
                    HStack(alignment: .top, spacing: NotchStripMetrics.gap) {
                        heading; actions
                    }
                } else {
                    heading
                    actions
                }
                if kind == .blockEnded && !activity.titles.isEmpty {
                    Divider().overlay(Theme.ink2)
                    Text("Parked while you worked").perchFont(.detailStrong)
                    titleChips(surface: .paper)
                    button(
                        AppL10n.text("Make them tasks"), .promoteThoughts, style: .quiet, identifier: "notch.promote")
                }
                if kind == .agentChange { titleChips(surface: .butter) }
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, NotchStripMetrics.inset)
        .padding(.vertical, Theme.Size.sheetPadding.value)
        .background(Theme.fill(surface))
        .accessibilityElement(children: .contain)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Theme.Size.focusGap.value) {
            Text(activity.title).perchFont(.stripTitle)
            if !activity.subtitle.isEmpty { Text(activity.subtitle).perchFont(.detail).foregroundStyle(Theme.ink2) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func titleChips(surface: DesignTokens.Surface) -> some View {
        HStack(spacing: NotchStripMetrics.gap) {
            ForEach(Array(activity.titles.enumerated()), id: \.offset) { _, title in
                Text(title).perchFont(.detail).padding(NotchStripMetrics.gap)
                    .background(Theme.fill(surface), in: Capsule())
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: NotchStripMetrics.gap) {
            switch kind {
            case .dataProblem:
                NotchStripButton(
                    title: activity.recoveryCount == nil || activity.recoveryCount == 2
                        ? AppL10n.text("Show the two") : AppL10n.text("Show saved tasks"), action: showFiles
                )
                .accessibilityIdentifier("notch.showRecovery")
                NotchStripButton(
                    title: activity.restoreLabel ?? AppL10n.text("Restore this morning's backup"), action: restore
                )
                .accessibilityIdentifier("notch.restore")
                button(AppL10n.text("Not now"), .notNow, style: .quiet, identifier: "notch.dismiss")
            case .reminder:
                button(AppL10n.text("Done"), .done, style: .main, identifier: "notch.done")
                button(AppL10n.text("Set time aside now"), .start, identifier: "notch.start")
                button(
                    AppL10n.format("In %lld minutes", store.prefs.snoozeMinutes.rawValue), .snooze,
                    identifier: "notch.snooze")
                button(AppL10n.text("Not today"), .notToday, style: .quiet, identifier: "notch.notToday")
            case .blockEnded:
                button(AppL10n.text("It's done"), .done, style: .main, identifier: "notch.done")
                button(AppL10n.text("+10 min"), .extend, identifier: "notch.extend")
                button(AppL10n.text("Move the last step to later"), .moveLastStep, identifier: "notch.moveStep")
                    .disabled(
                        activity.taskID.flatMap { id in store.planner.tasks.first { $0.id == id } }?.steps.contains {
                            !$0.done
                        } != true)
            case .headsUp:
                button(AppL10n.text("+10 min"), .extend, style: .main, identifier: "notch.extend")
                button(AppL10n.text("Wrap up"), .wrapUp, identifier: "notch.wrapUp")
            case .agentChange:
                if case .message = activity.kind {
                    button(AppL10n.text("Not now"), .notNow, style: .quiet, identifier: "notch.dismiss")
                } else {
                    button(AppL10n.text("Keep"), .keep, identifier: "notch.keep")
                    button(AppL10n.text("Undo"), .undo, style: .quiet, identifier: "notch.undo")
                }
            case .undo, .dropShelf: EmptyView()
            }
        }
    }

    private func button(
        _ title: String, _ choice: NotchStrips.Action, style: PerchButtonKind = .soft, identifier: String
    ) -> some View {
        NotchStripButton(title: title, kind: style, surface: surface) { action(choice) }
            .accessibilityIdentifier(identifier)
    }
}

/// Today owns its keyboard destination even when geometry exists without a strip
/// host, or a higher-priority strip preempts deletion. Completion uses only the
/// viewport mount; the pinned destination does not expire with the six-second strip.
struct NotchUndoFooter: ViewModifier {
    let showsUndo: Bool
    @Binding var reviewingOverdue: Bool
    @EnvironmentObject private var store: PlannerStore
    @EnvironmentObject private var model: NotchModel

    func body(content: Content) -> some View {
        VStack(spacing: .zero) {
            if showsUndo {
                VStack(alignment: .leading, spacing: NotchStripMetrics.gap) {
                    if let activity = inlineActivity {
                        Text(activity.title).perchFont(.stripTitle).foregroundStyle(Theme.ink)
                    }
                    // Keep this mount stable as the optional strip appears/expires.
                    content
                    if inlineActivity != nil {
                        TimelineView(.periodic(from: .now, by: NotchStripMetrics.clockInterval)) { context in
                            GeometryReader { proxy in
                                Rectangle().fill(Theme.ink2)
                                Rectangle().fill(Theme.brandText).frame(
                                    width: proxy.size.width * (model.strips?.fraction(at: context.date) ?? 0))
                            }.frame(height: NotchStripMetrics.progressHeight).accessibilityHidden(true)
                        }
                    }
                }
                .padding(inlineActivity == nil ? .zero : NotchStripMetrics.gap)
                .background {
                    if inlineActivity != nil { Theme.paper }
                }
            } else if !store.engine.overdue().isEmpty {
                Button(AppL10n.format("Still waiting (%lld)", store.engine.overdue().count)) {
                    reviewingOverdue = true
                }
                .buttonStyle(PillStyle()).accessibilityIdentifier("today-review-overdue")
            }
        }
        .onAppear {
            if model.strips == nil { model.strips = NotchStrips(store: store, model: model) }
        }
    }

    private var inlineActivity: PresentedNotchActivity? {
        guard model.geometry == nil, let activity = model.strips?.currentActivity, activity.stripKind == .undo else {
            return nil
        }
        return activity
    }
}

private struct NotchUndoAction: View {
    let action: () -> Void

    var body: some View {
        NotchStripButton(title: AppL10n.text("Undo"), action: action)
            .accessibilityIdentifier("notch.undo")
    }
}

private struct NotchStripCloseButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        PerchButton(kind: .quiet, size: .strip, surface: .blush, action: action) {
            Image(systemName: "xmark").perchFont(.detailStrong)
        }
        .accessibilityLabel(AppL10n.text("Not now"))
        .accessibilityIdentifier("notch.dismiss")
        .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
            guard enabled, press.modifiers.isEmpty else { return .ignored }
            if press.phase == .down { action() }
            return .handled
        }
    }
}

struct NotchStripButton: View {
    let title: String
    var kind: PerchButtonKind = .soft
    var surface: DesignTokens.Surface = .paper
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        PerchButton(title, kind: kind, size: .strip, surface: surface, action: action)
            .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
                guard enabled, press.modifiers.isEmpty else { return .ignored }
                if press.phase == .down { action() }
                return .handled
            }
    }
}

#if DEBUG || PERCH_TESTING
    @MainActor
    enum NotchStripPreview {
        static let windowID = "notch-strip-preview"
        static func show(_ kind: NotchStripQueue.Kind, app: AppDelegate, deleting: Bool = false) {
            let task = app.store.planner.tasks.first
            let title: String
            let subtitle: String
            switch kind {
            case .dataProblem:
                title = "Perch couldn't read 2 tasks";
                subtitle = "They are saved in a separate file. Everything else is here and safe."
            case .reminder:
                title = "Time for ‘Call the bank’";
                subtitle = "You asked to be reminded at 9:30. This stays until you pick one."
            case .blockEnded:
                title = "Time's up on this block"; subtitle = "Draft the test checklist · 3 of 4 steps done"
            case .headsUp:
                title = "5 minutes left on this block"; subtitle = "Draft the test checklist · 3 of 4 steps done"
            case .agentChange:
                title = "Claude added 2 tasks to today";
                subtitle = "Agents can add and edit. They ask before deleting anything."
            case .undo: title = "Deleted ‘Call the bank’"; subtitle = ""
            case .dropShelf: title = "Drop it here to keep it handy"; subtitle = ""
            }
            var card = PresentedNotchActivity(
                kind: .strip(kind, "preview"), title: title, subtitle: subtitle, taskID: task?.id)
            if kind == .agentChange {
                card.titles = ["Outline the Q4 planning note", "Book a room for the review"]
                if deleting {
                    card.title = "Claude wants to delete ‘Call the bank’"
                    card.subtitle = "Keep applies this request. Undo leaves the task unchanged."
                    card.titles = ["Call the bank"]
                }
            }
            if kind == .blockEnded { card.titles = ["Order printer ink", "Reply to the landlord"] }
            let band = app.model.geometry?.screen.menuBarHeight ?? NSStatusBar.system.thickness
            let content = VStack(spacing: .zero) {
                Theme.band.frame(height: band)
                NotchStripContent(activity: card, fraction: 0.6, action: { _ in }, showFiles: {}, restore: {})
            }.frame(width: NotchStripMetrics.width(for: kind)).fixedSize(horizontal: false, vertical: true)
                .environmentObject(app.store).environmentObject(app.model).previewEnvironment()
                .environment(\.colorScheme, PreviewAppearance.scheme ?? .light)
            let height = NSHostingView(rootView: content).fittingSize.height
            WindowHost.show(
                windowID, title: "Perch", size: CGSize(width: NotchStripMetrics.width(for: kind), height: height)
            ) { content }
        }
    }
#endif
