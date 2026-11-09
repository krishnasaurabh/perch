import Foundation

extension PlannerEngine {
    /// Marks a calendar occurrence locally, without changing the source calendar or any task.
    /// Setting the same value again is a no-op, including its original completion day.
    public mutating func setCalendarEventCompleted(_ id: String, completed: Bool) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlannerError("Provide a non-empty calendar event ID.")
        }
        if completed {
            if planner.completedCalendarEventIDs.insert(id).inserted {
                planner.completedCalendarEventDays[id] = today
            }
        } else {
            planner.completedCalendarEventIDs.remove(id)
            planner.completedCalendarEventDays.removeValue(forKey: id)
        }
    }
}
