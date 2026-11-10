import Foundation

/// Stable portable version-1 export. Device preferences are not part of a shared document.
struct PlannerExportDocument: Encodable {
    let planner: Planner
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Planner.CodingKeys.self)
        try c.encode(Planner.currentVersion, forKey: .version)
        try c.encode(planner.tasks, forKey: .tasks)
        try c.encode(planner.projects, forKey: .projects)
        try c.encode(planner.notes, forKey: .notes)
        try c.encode(planner.focusSegments, forKey: .focusSegments)
        try c.encodeIfPresent(planner.focus, forKey: .focus)
        try c.encode(planner.dismissedOverdue, forKey: .dismissedOverdue)
        try c.encode(planner.repeatOccurrences, forKey: .repeatOccurrences)
        try c.encode(planner.completedCalendarEventIDs.sorted(), forKey: .completedCalendarEventIDs)
        try c.encode(planner.completedCalendarEventDays, forKey: .completedCalendarEventDays)
        try c.encode(SharedPlannerPreferences(planner.preferences), forKey: .preferences)
    }
}
