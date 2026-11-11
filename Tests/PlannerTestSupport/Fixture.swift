import Foundation
import PlannerCore

/// Fixed clock: Monday 2026-11-09 15:00 in Los Angeles.
public enum Fixture {
    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    public static func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }
    public static let now = date("2026-11-09 15:00")
    public static var capture: TaskCapture { TaskCapture(now: now, calendar: calendar) }
    public static func hm(_ d: Date?) -> String? {
        guard let d else { return nil }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone;
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
    /// Synthetic fixture lookup; production domain APIs accept only UUIDs.
    public static func taskID(_ title: String, in planner: Planner) throws -> UUID {
        let matches = planner.tasks.filter { $0.title.caseInsensitiveCompare(title) == .orderedSame }
        guard let task = matches.first else { throw PlannerError("Fixture task not found.") }
        return task.id
    }
}
