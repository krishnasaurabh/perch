import Foundation
import PlannerCore

/// One presentation at a time. Visible-time budgets pause behind higher-priority
/// strips; hard deadlines (agent approvals) still expire while hidden.
public struct NotchStripQueue: Equatable, Sendable {
    /// Declaration order is the product's priority table, highest first.
    public enum Kind: String, CaseIterable, Sendable {
        case dataProblem, reminder, blockEnded, headsUp, agentChange, undo, dropShelf

        public var timeout: TimeInterval? {
            switch self {
            case .agentChange: return 10
            case .undo: return 6
            default: return nil
            }
        }
        public var surface: DesignTokens.Surface {
            switch self {
            case .reminder: return .butter
            case .blockEnded, .headsUp: return .blush
            case .dropShelf: return .apricot
            default: return .paper
            }
        }
        fileprivate var priority: Int { Self.allCases.firstIndex(of: self)! }
    }

    public struct Item: Equatable, Identifiable, Sendable {
        public let id: String
        public let kind: Kind
        public let createdAt: Date
        public var deadline: Date?
        public var timeout: TimeInterval?

        public init(id: String, kind: Kind, createdAt: Date, deadline: Date? = nil, timeout: TimeInterval? = nil) {
            self.id = id; self.kind = kind; self.createdAt = createdAt
            self.deadline = deadline; self.timeout = timeout ?? kind.timeout
        }
    }

    private struct Entry: Equatable, Sendable {
        var item: Item
        var remaining: TimeInterval?
    }
    private var entries: [String: Entry] = [:]
    private var answered = Set<String>()
    private var instant: Date?
    public private(set) var current: Item?
    public init() {}

    public var pending: [Item] { entries.values.map(\.item).sorted(by: Self.precedes) }

    /// Repeated observation updates content without renewing a timeout or replaying
    /// an answered occurrence. A changed occurrence must have a new stable identity.
    public mutating func reconcile(_ items: [Item], at date: Date) {
        advance(to: date)
        let live = Set(items.map(\.id))
        answered.formIntersection(live)
        entries = entries.filter { live.contains($0.key) }
        for item in items where !answered.contains(item.id) {
            if var entry = entries[item.id] {
                entry.item = item
                entries[item.id] = entry
            } else {
                entries[item.id] = Entry(item: item, remaining: item.timeout)
            }
        }
        settle()
    }

    public mutating func answer(_ id: String, at date: Date) {
        advance(to: date)
        entries[id] = nil
        answered.insert(id)
        settle()
    }

    /// Also visits intervening boundaries on wake, so a future item is not charged
    /// for time before it became eligible. Backward wall-clock changes spend nothing.
    public mutating func advance(to date: Date) {
        guard let previous = instant else { instant = date; settle(); return }
        let target = max(previous, date)
        while let boundary = nextChange, boundary <= target {
            spend(until: boundary)
            settle()
        }
        spend(until: target)
        settle()
    }

    public var nextChange: Date? {
        guard let instant else { return nil }
        var boundaries = entries.values.flatMap { entry -> [Date] in
            [entry.item.createdAt, entry.item.deadline].compactMap { $0 }.filter { $0 > instant }
        }
        if let id = current?.id, let remaining = entries[id]?.remaining, remaining > 0 {
            boundaries.append(instant.addingTimeInterval(remaining))
        }
        return boundaries.min()
    }

    public func remainingFraction(at date: Date) -> Double {
        guard let id = current?.id, let entry = entries[id], let budget = entry.item.timeout, budget > 0,
            let remaining = entry.remaining, let instant
        else { return 1 }
        return min(1, max(0, remaining - max(0, date.timeIntervalSince(instant))) / budget)
    }

    private mutating func spend(until date: Date) {
        if let id = current?.id, let instant, let remaining = entries[id]?.remaining {
            entries[id]?.remaining = max(0, remaining - date.timeIntervalSince(instant))
        }
        instant = date
    }

    private mutating func settle() {
        guard let instant else { return }
        let expired = entries.values.filter {
            $0.item.deadline.map { $0 <= instant } == true || $0.remaining.map { $0 <= 0 } == true
        }.map(\.item.id)
        for id in expired { entries[id] = nil; answered.insert(id) }
        current = pending.first { $0.createdAt <= instant }
    }

    private static func precedes(_ lhs: Item, _ rhs: Item) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.priority < rhs.kind.priority }
        return lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
    }
}

/// A transient deletion offer is tied to the durable agent ordering at its creation.
/// Keep and timeout only dismiss agent presentation; neither makes older local Undo current again.
public struct NotchDeletionUndo: Equatable, Sendable {
    private let agentSequence: Int
    private let taskIDs: Set<UUID>

    public init(after planner: Planner, taskIDs: [UUID]) {
        agentSequence = planner.agentActions.sequence
        self.taskIDs = Set(taskIDs)
    }

    public func isValid(in planner: Planner) -> Bool {
        planner.agentActions.sequence == agentSequence
            && !planner.tasks.contains { taskIDs.contains($0.id) }
    }
}

/// Live preference policy, independent of the notification-delivery ledger.
public enum NotchStripPolicy {
    public static func reminders(
        in planner: Planner, at now: Date, records: [String: ReminderRecord] = [:], waiting: Set<String> = []
    ) -> [PlanTask] {
        planner.tasks.filter { task in
            guard !task.done, task.day != nil, let due = task.remindAt, due <= now else { return false }
            let liveWindow = now < due.addingTimeInterval(NotchActivityTimeline.reminderDuration)
            guard planner.preferences.persistentReminders else { return liveWindow }
            let request = ScheduledReminder(task: task)
            let accounted = records[request.id].map { $0.date == due && $0.state != .scheduled } == true
            return liveWindow || waiting.contains(request.id) || accounted
        }.sorted { ($0.remindAt!, $0.id.uuidString) < ($1.remindAt!, $1.id.uuidString) }
    }

    public static func headsUp(in planner: Planner, at now: Date) -> Date? {
        guard let focus = planner.focus, focus.state == .running,
            let remaining = focus.remaining(at: now), remaining > 0,
            planner.preferences.blockHeadsUp != .off,
            remaining <= Double(planner.preferences.blockHeadsUp.rawValue * 60)
        else { return nil }
        return now.addingTimeInterval(remaining)
    }

    public static func blockEndedAt(in planner: Planner) -> Date? {
        guard let focus = planner.focus, focus.state == .finished else { return nil }
        return planner.focusSegments.filter { $0.taskID == focus.taskID && $0.start >= focus.startedAt }.map(\.end)
            .max()
            ?? focus.startedAt.addingTimeInterval(focus.banked)
    }

    public static func parkedDuringBlock(in planner: Planner) -> [ParkedThought] {
        guard let focus = planner.focus, let end = blockEndedAt(in: planner) else { return [] }
        return planner.parkedThoughts.filter { $0.createdAt >= focus.startedAt && $0.createdAt <= end }
    }

    public static func showsBlockEnded(in planner: Planner) -> Bool {
        planner.focus?.state == .finished && planner.preferences.blockEndAction == .ask
    }
}

public enum NotchStripAction: Sendable {
    case done, start, snooze, notToday, extend, wrapUp, moveLastStep, promoteThoughts, keep, undo, notNow
}

/// Runs inside the caller's existing locked, undoable command transaction.
public enum NotchStripActions {
    public static func perform(
        _ action: NotchStripAction, taskID: UUID?, thoughtIDs: [UUID] = [], commands: PlannerCommands
    ) throws {
        switch action {
        case .done:
            if let taskID { _ = try commands.complete(taskID) } else { try commands.stopTimer() }
        case .start:
            guard let taskID else { throw PlannerError("Choose a task first.") }
            try commands.setStart(taskID, at: commands.read.now())
            _ = try commands.startTimer(task: taskID, minutes: nil)
        case .snooze:
            guard let taskID else { throw PlannerError("Choose a task first.") }
            _ = try commands.snooze(taskID, minutes: commands.planner.preferences.snoozeMinutes.rawValue)
        case .notToday:
            if let taskID { try commands.updateTask(taskID) { $0.remindAt = nil } }
        case .extend:
            let finished = commands.planner.focus?.state == .finished
            try commands.extendTimer(minutes: 10)
            if finished { try commands.resumeTimer() }
        case .wrapUp: try commands.stopTimer()
        case .moveLastStep:
            guard let taskID, let step = try commands.task(taskID).steps.last(where: { !$0.done }) else {
                throw PlannerError("There are no steps left to move.")
            }
            _ = try commands.addTasks(
                [step.title], on: .day(commands.today.adding(days: 1, calendar: commands.read.calendar)), literal: true)
            try commands.updateTask(taskID) { $0.steps.removeAll { $0.id == step.id } }
        case .promoteThoughts:
            for id in thoughtIDs { _ = try commands.promoteThought(id) }
        case .keep, .undo, .notNow: break
        }
    }
}

/// Strip geometry composes foundation values rather than baking sizes into views.
public enum NotchStripMetrics {
    public static let gap = DesignTokens.Size.segmentItemRadius.value
    public static let inset = DesignTokens.Size.buttonSidePadding.value
    public static let bottomRadius = DesignTokens.Size.currentTaskRadius.value
    public static let progressHeight = DesignTokens.Size.checkboxStroke.value
    public static let clockInterval = DesignTokens.MotionToken.press.duration
    public static let countdownInterval = 60.0

    public static func fittedWidth(for kind: NotchStripQueue.Kind, ideal: Double) -> Double {
        let minimum = width(for: kind)
        return ideal.isFinite ? min(DesignTokens.Size.stripMaxWidth.value, max(minimum, ideal)) : minimum
    }

    public static func width(for kind: NotchStripQueue.Kind) -> Double {
        switch kind {
        case .undo: return DesignTokens.Size.stripMinWidth.value
        case .reminder, .headsUp:
            return (DesignTokens.Size.peekWidth.value + DesignTokens.Size.stripMaxWidth.value) / 2
                - DesignTokens.Size.segmentRadius.value
        case .agentChange: return DesignTokens.Size.stripMaxWidth.value - 2 * DesignTokens.Size.windowPadding.value
        case .dataProblem, .blockEnded:
            return DesignTokens.Size.stripMaxWidth.value - DesignTokens.Size.windowPadding.value
        case .dropShelf: return DesignTokens.Size.stripMaxWidth.value
        }
    }
}
