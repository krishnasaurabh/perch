import Foundation
import PlannerCore

/// Fixed clock: Monday 2026-11-09 15:00 in Los Angeles.
public enum Fixture {
    public static var calendar: Calendar = {
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
}
