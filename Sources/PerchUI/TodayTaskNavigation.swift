import Foundation
import PlannerCore

/// Keyboard movement follows displayed order and never wraps into an unrelated control.
public enum TodayTaskNavigation {
    public static let foldedRowCount = 4

    public static func ordered(_ tasks: [PlanTask], currentID: UUID?) -> [PlanTask] {
        let current = tasks.filter { $0.id == currentID && !$0.done }
        return current + tasks.filter { !$0.done && $0.id != currentID } + tasks.filter(\.done)
    }

    public static func isExpanded(_ tasks: [PlanTask], expanded: Bool, selectedID: UUID?) -> Bool {
        expanded || tasks.dropFirst(foldedRowCount).contains(where: { $0.id == selectedID })
    }

    public static func visible(_ tasks: [PlanTask], expanded: Bool, selectedID: UUID?) -> [PlanTask] {
        if isExpanded(tasks, expanded: expanded, selectedID: selectedID) { return tasks }
        return Array(tasks.prefix(foldedRowCount))
    }

    public static func hiddenCount(_ tasks: [PlanTask], expanded: Bool, selectedID: UUID?) -> Int {
        tasks.count - visible(tasks, expanded: expanded, selectedID: selectedID).count
    }

    /// The fold action shares the checklist's Tab stop and arrow-key cursor.
    public enum Destination: Equatable, Sendable {
        case task(UUID)
        case fold
    }

    public static func move(
        in ids: [UUID], from current: Destination, offset: Int, expanded: Bool
    ) -> Destination? {
        guard !ids.isEmpty, abs(offset) == 1 else { return nil }
        let hasFold = ids.count > foldedRowCount
        switch current {
        case .fold:
            guard hasFold else { return ids.last.map(Destination.task) }
            if offset > 0 { return .fold }
            return (expanded ? ids.last : ids.prefix(foldedRowCount).last).map(Destination.task)
        case .task(let id):
            if hasFold, offset > 0, id == ids.last { return .fold }
            return neighbor(in: ids, from: id, offset: offset).map(Destination.task)
        }
    }

    public static func nextStep(in steps: [Subtask]) -> UUID? { steps.first { !$0.done }?.id }

    public struct Reorder: Equatable, Sendable {
        public let beforeID: UUID?
    }

    /// Only open, non-current tasks have a movable position. A nil beforeID means the end.
    public static func reorder(_ tasks: [PlanTask], currentID: UUID?, selectedID: UUID, offset: Int) -> Reorder? {
        let ids = tasks.filter { !$0.done && $0.id != currentID }.map(\.id)
        guard let index = ids.firstIndex(of: selectedID), abs(offset) == 1,
            ids.indices.contains(index + offset)
        else { return nil }
        let destination = offset < 0 ? ids[index - 1] : (index + 2 < ids.count ? ids[index + 2] : nil)
        return Reorder(beforeID: destination)
    }

    /// Moving out of the checklist is a single undoable transaction, including its removal.
    public static func park(_ id: UUID, commands: PlannerCommands) throws {
        let task = try commands.task(id)
        _ = try commands.parkThought(task.title)
        _ = try commands.delete(id, on: task.day.map { .day($0) } ?? .inbox)
    }

    public static func neighbor(in ids: [UUID], from current: UUID, offset: Int) -> UUID? {
        guard let index = ids.firstIndex(of: current), !ids.isEmpty else { return nil }
        return ids[min(max(0, index + offset), ids.count - 1)]
    }

    /// Completing or deleting a row keeps its position: next row, otherwise the previous row.
    /// No surviving rows returns nil so the caller can focus Undo or capture as appropriate.
    public static func afterRemoval(of current: UUID, previous: [UUID], remaining: [UUID]) -> UUID? {
        guard !remaining.isEmpty else { return nil }
        if remaining.contains(current) { return current }
        guard let index = previous.firstIndex(of: current) else { return remaining.first }
        return remaining[min(index, remaining.count - 1)]
    }
}

/// The add field has one indentation level. A second Tab can leave it normally.
public struct TodayTaskCapture: Equatable, Sendable {
    public var text = ""
    public private(set) var parentID: UUID?
    private struct Recording: Equatable, Sendable {
        let text: String
        let parentID: UUID?
    }
    private var pendingRecordings: [Recording] = []
    public var pendingDictation: String? { pendingRecordings.first?.text }
    public var pendingDictationParentID: UUID? { pendingRecordings.first?.parentID }
    public init() {}

    /// Speech has its own submission buffer. Neither successful insertion nor a
    /// failure can replace text the person entered before or during recording.
    @discardableResult
    public mutating func submitDictation(
        _ spoken: String, parentID: UUID? = nil, using submit: (String) -> Bool
    ) -> Bool {
        let value = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        guard submit(value) else {
            pendingRecordings.append(Recording(text: value, parentID: parentID))
            return false
        }
        return true
    }

    /// Retry only the oldest unsaved recording, keeping its original destination.
    /// A newer recording, even with identical text, never replaces this entry.
    @discardableResult
    public mutating func retryDictation(using submit: (String, UUID?) -> Bool) -> Bool {
        guard let recording = pendingRecordings.first,
            submit(recording.text, recording.parentID)
        else { return false }
        pendingRecordings.removeFirst()
        return true
    }

    /// A single preview must describe a single submitted task, never metadata
    /// combined from different lines. Blank lines and list bullets follow capture.
    public func preview(using parser: TaskCapture, language: TaskParserLanguage) -> CapturedTask? {
        let lines = TaskCapture.splitLines(text)
        guard parentID == nil, lines.count == 1, let line = lines.first else { return nil }
        return parser.parse(line, language: language)
    }
    public mutating func indent(parentID: UUID?) -> Bool {
        guard self.parentID == nil, let parentID else { return false }
        self.parentID = parentID
        return true
    }
    public mutating func outdent() -> Bool {
        guard parentID != nil else { return false }
        parentID = nil
        return true
    }

    @discardableResult
    public static func submit(
        _ text: String, parentID: UUID?, on day: DayRef,
        commands: PlannerCommands, language: TaskParserLanguage = .english
    ) throws -> [PlanTask] {
        let lines = TaskCapture.splitLines(text).filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw PlannerError("Add at least one task title with text.") }
        guard let parentID else { return try commands.addTasks(lines, on: day, language: language) }
        // Resolve first so a stale parent cannot silently turn a step into a task.
        let parent = try commands.task(parentID)
        guard parent.day == day.key, !parent.done else { throw PlannerError("Choose an open task for this step.") }
        try commands.updateTask(parentID) { $0.steps.append(contentsOf: lines.map { Subtask(title: $0) }) }
        return [try commands.task(parentID)]
    }
}
