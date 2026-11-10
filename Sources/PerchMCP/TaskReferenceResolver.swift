import Foundation
import PlannerCore

/// Human references exist only at the MCP boundary; domain commands receive UUIDs.
public enum TaskReferenceResolver {
    public static func resolve(_ reference: String, in planner: Planner, on day: DayRef) throws -> UUID {
        let text = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PlannerError("Identify the task by id from list_tasks or by title.") }
        if let id = UUID(uuidString: text) {
            guard planner.tasks.contains(where: { $0.id == id }) else { throw PlannerError("Task id not found.") }
            return id
        }
        let lower = text.lowercased()
        if lower.count >= 6 {
            let ids = planner.tasks.filter { $0.id.uuidString.lowercased().hasPrefix(lower) }
            if ids.count == 1 { return ids[0].id }
            if ids.count > 1 { throw PlannerError("Multiple task ids match. Use a full id from list_tasks.") }
        }
        let pool = planner.tasks.filter { day == .inbox ? $0.day == nil : $0.day == day.key }
        let exact = pool.filter { $0.title.caseInsensitiveCompare(text) == .orderedSame }
        let matches = exact.isEmpty ? pool.filter { $0.title.localizedCaseInsensitiveContains(text) } : exact
        if matches.count == 1 { return matches[0].id }
        if matches.count > 1 {
            let names = matches.prefix(5).map { "\"\($0.title)\"" }.joined(separator: ", ")
            throw PlannerError("Multiple tasks match \"\(text)\": \(names). Choose an id from list_tasks.")
        }
        let location = day == .inbox ? "in the Inbox" : "on \(day.key!)"
        throw PlannerError("No task found for \"\(text)\" \(location). Check list_tasks for an id.")
    }
}
