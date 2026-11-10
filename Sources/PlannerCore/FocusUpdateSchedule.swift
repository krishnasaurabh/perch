import Foundation

/// Persistence boundaries are independent of the on-screen seconds display.
public enum FocusUpdateSchedule {
    public static func nextUpdate(for focus: FocusSession?, now: Date) -> Date? {
        guard let focus, focus.state == .running, let start = focus.resumedAt else { return nil }
        let checkpoint = start.addingTimeInterval(PlannerEngine.focusCheckpointInterval)
        let finish = focus.limit.map { start.addingTimeInterval(max(0, $0 - focus.banked)) }
        return max(now, min(checkpoint, finish ?? checkpoint))
    }

    public static func nextDay(for planner: Planner, now: Date, calendar: Calendar = .current) -> Date {
        let today = DayKey(now, resetHour: planner.preferences.resetHour, calendar: calendar)
        return today.adding(days: 1, calendar: calendar).start(
            resetHour: planner.preferences.resetHour, calendar: calendar)
    }
}

/// Metadata only: detects atomic replacement even when size and modification date are preserved.
public struct PlannerFileRevision: Equatable, Sendable {
    public let identity: UInt64
    public let size: UInt64
    public let modified: Date
    public let changed: Date

    public init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let identity = attributes[.systemFileNumber] as? NSNumber,
            let size = attributes[.size] as? NSNumber,
            let modified = attributes[.modificationDate] as? Date
        else { return nil }
        self.identity = identity.uint64Value
        self.size = size.uint64Value
        self.modified = modified
        self.changed = attributes[.creationDate] as? Date ?? modified
    }
}

public struct PlannerStorageBusy: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { "Another process is updating the planner. Please try again." }
}
