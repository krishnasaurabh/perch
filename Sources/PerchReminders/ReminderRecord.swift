import Foundation
import PlannerCore

/// Only these fields are mirrored. Other remote edits stop reconciliation instead of being overwritten.
public struct ReminderFields: Codable, Equatable, Sendable {
    public var title: String
    public var notes: String?
    public var priority: Int
    public var due: DateComponents?
    public var alarm: Date?
    public var completed: Bool

    public init(title: String, notes: String?, priority: Int, due: DateComponents?, alarm: Date?, completed: Bool) {
        self.title = title; self.notes = notes; self.priority = priority
        self.due = Self.normalized(due); self.alarm = alarm; self.completed = completed
    }

    private static func normalized(_ due: DateComponents?) -> DateComponents? {
        guard let due else { return nil }
        // EventKit can decorate returned components with calendar, era and zero seconds.
        // Compare the supported civil date, not those incidental representations.
        var value = DateComponents()
        value.year = due.year; value.month = due.month; value.day = due.day
        value.hour = due.hour; value.minute = due.minute
        if due.hour != nil { value.timeZone = due.timeZone ?? .current }
        return value
    }

    public init(task: PlanTask, ringOnPhone: Bool, calendar: Calendar = .current) {
        title = task.title
        notes = task.notes.isEmpty ? nil : task.notes
        priority = [.high: 1, .medium: 5, .low: 9, .none: 0][task.priority]!
        completed = task.done
        if let at = task.remindAt {
            due = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: at)
            due?.timeZone = calendar.timeZone
            alarm = ringOnPhone ? at : nil
        } else {
            due = task.day.map { calendar.dateComponents([.year, .month, .day], from: $0.date(calendar: calendar)) }
            alarm = nil
        }
        due = Self.normalized(due)
    }
}

/// A per-task secret-free ownership marker, persisted before the first EventKit write.
public struct ReminderOwner: Codable, Hashable, Sendable {
    public let installation: UUID
    public let task: UUID
    public let token: UUID
    public init(installation: UUID, task: UUID, token: UUID = UUID()) {
        self.installation = installation; self.task = task; self.token = token
    }
    public var url: URL {
        URL(string: "perch-reminder://v1/\(installation.uuidString)/\(task.uuidString)/\(token.uuidString)")!
    }
    public init?(url: URL?) {
        guard let url, url.scheme == "perch-reminder", url.host == "v1", url.query == nil, url.fragment == nil else {
            return nil
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 3, let installation = UUID(uuidString: parts[0]),
            let task = UUID(uuidString: parts[1]), let token = UUID(uuidString: parts[2])
        else { return nil }
        self.init(installation: installation, task: task, token: token)
    }
}

public struct ReminderRecord: Equatable, Sendable {
    public let id: String
    public let calendarID: String
    public let owner: ReminderOwner?
    public let fields: ReminderFields
    public let revision: String
    public let unsupported: Bool
    public init(
        id: String, calendarID: String, owner: ReminderOwner?, fields: ReminderFields, revision: String,
        unsupported: Bool = false
    ) {
        self.id = id; self.calendarID = calendarID; self.owner = owner; self.fields = fields
        self.revision = revision; self.unsupported = unsupported
    }
}

public enum ReminderSyncError: Error, LocalizedError {
    case stopped(String)
    public var errorDescription: String? {
        switch self {
        case .stopped(let message): return message
        }
    }
}

/// Each write must recheck permission, ownership and the entire expected revision immediately before saving.
@MainActor
public protocol ReminderRepository: AnyObject {
    var hasAccess: Bool { get }
    func createCalendar() throws -> String
    func fetch(calendarID: String) async throws -> [ReminderRecord]
    func save(fields: ReminderFields, owner: ReminderOwner, calendarID: String, replacing: ReminderRecord?) throws
        -> ReminderRecord
    func remove(_ expected: ReminderRecord) throws
}
