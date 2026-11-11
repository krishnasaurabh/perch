import Foundation
import PlannerCore

extension AgentTools {
    /// Validate the same JSON Schema that tools/list publishes, before loading or locking storage.
    static func validate(_ name: String, arguments: JSON) throws {
        guard let definition = definitions.first(where: { $0["name"]?.string == name }) else {
            throw MCPServer.MethodNotFound(name: name)
        }
        guard case .object(let values) = arguments else {
            throw PlannerError("Invalid arguments: expected an object.")
        }
        let required = definition["inputSchema"]?["required"]?.array?.compactMap(\.string) ?? []
        for key in required where values[key] == nil {
            throw missingArgument(name: name, key: key)
        }
        guard case .object(let properties)? = definition["inputSchema"]?["properties"] else { return }

        // Validate declared values before rejecting unknown keys so established numeric
        // errors keep their precedence when a request contains both problems.
        for key in properties.keys.sorted() {
            guard let value = values[key], let schema = properties[key] else { continue }
            try validate(value, schema: schema, tool: name, key: key)
        }
        for key in values.keys.sorted() where properties[key] == nil {
            throw PlannerError("Unknown argument '\(key)' for \(name).")
        }
        if name == "update_overdue", values["action"]?.string != "carry", values["date"] != nil {
            throw PlannerError("The date argument is only valid when action is carry.")
        }
    }

    private static func missingArgument(name: String, key: String) -> PlannerError {
        switch (name, key) {
        case ("add_tasks", "titles"):
            return PlannerError("Add at least one task title with text.")
        case (_, "task"):
            return PlannerError("Identify the task by id from list_tasks or by title.")
        case ("rename_task", "title"):
            return PlannerError("Enter replacement title text.")
        case ("move_task", "to"):
            return PlannerError("Set a destination date or use inbox.")
        case ("write_notepad", "text"):
            return PlannerError("Enter note text using 20000 characters or fewer.")
        case ("update_overdue", "tasks"):
            return PlannerError("Select at least one overdue task id from list_overdue.")
        case ("update_overdue", "action"):
            return PlannerError("Choose an overdue action: complete, carry or dismiss.")
        default:
            return PlannerError("Missing required argument '\(key)' for \(name).")
        }
    }

    private static func validate(_ value: JSON, schema: JSON, tool: String, key: String) throws {
        if schema["anyOf"] != nil {
            guard key == "minutes" else { throw invalid(value, schema, tool, key) }
            let choices = schema["anyOf"]?.array ?? []
            let branchType = value.string == nil ? "integer" : "string"
            guard let branch = choices.first(where: { $0["type"]?.string == branchType }) else {
                throw invalid(value, schema, tool, key)
            }
            do {
                try validate(value, schema: branch, tool: tool, key: key)
            } catch {
                // Keep the established minutes error while enforcing the selected branch.
                throw invalid(value, schema, tool, key)
            }
            guard let integer = value.int else { throw invalid(value, schema, tool, key) }
            let range = choices.first { $0["type"]?.string == "integer" }
            let lower = range?["minimum"]?.int ?? Int.min
            let upper = range?["maximum"]?.int ?? Int.max
            guard (lower...upper).contains(integer) else { throw invalid(value, schema, tool, key) }
            return
        }

        switch schema["type"]?.string {
        case "string":
            guard let string = value.string else { throw invalid(value, schema, tool, key) }
            // JSON Schema measures string length in Unicode code points, not grapheme clusters.
            let length = string.unicodeScalars.count
            if let maximum = schema["maxLength"]?.int, length > maximum {
                if tool == "add_tasks", key == "titles" {
                    throw PlannerError(
                        "Invalid argument 'titles': use 1 to 100 titles, each with 2000 characters or fewer.")
                }
                throw PlannerError("Invalid argument '\(key)': enter \(maximum) characters or fewer.")
            }
            if let minimum = schema["minLength"]?.int, length < minimum {
                throw invalid(value, schema, tool, key)
            }
            if let pattern = schema["pattern"]?.string,
                string.range(of: pattern, options: .regularExpression) == nil
            {
                throw invalid(value, schema, tool, key)
            }
            if let allowed = schema["enum"]?.array?.compactMap(\.string), !allowed.contains(string) {
                if key == "priority" { throw PlannerError("Choose priority from: none, low, medium, high.") }
                if key == "mode" { throw PlannerError("Choose note mode: append or replace.") }
                throw PlannerError("Invalid argument '\(key)': choose one of \(allowed.joined(separator: ", ")).")
            }
        case "boolean":
            guard value.bool != nil else { throw invalid(value, schema, tool, key) }
        case "integer":
            guard let integer = value.int else { throw invalid(value, schema, tool, key) }
            if let minimum = schema["minimum"]?.int, integer < minimum { throw invalid(value, schema, tool, key) }
            if let maximum = schema["maximum"]?.int, integer > maximum { throw invalid(value, schema, tool, key) }
        case "array":
            guard let array = value.array else { throw invalid(value, schema, tool, key) }
            let minimum = schema["minItems"]?.int ?? 0
            if array.count < minimum {
                if tool == "add_tasks", key == "titles" {
                    throw PlannerError("Add at least one task title with text.")
                }
                if tool == "update_overdue", key == "tasks" {
                    throw PlannerError("Select at least one overdue task id from list_overdue.")
                }
                throw PlannerError("Invalid argument '\(key)': enter at least \(minimum) items.")
            }
            if let maximum = schema["maxItems"]?.int, array.count > maximum {
                if tool == "add_tasks", key == "titles" {
                    throw PlannerError(
                        "Invalid argument 'titles': use 1 to 100 titles, each with 2000 characters or fewer.")
                }
                throw PlannerError("Invalid argument '\(key)': enter at most \(maximum) items.")
            }
            if let items = schema["items"] {
                for item in array { try validate(item, schema: items, tool: tool, key: key) }
            }
        default:
            throw invalid(value, schema, tool, key)
        }
    }

    private static func invalid(_ value: JSON, _ schema: JSON, _ tool: String, _ key: String) -> PlannerError {
        if key == "minutes" {
            let choices = schema["anyOf"]?.array ?? []
            let range = choices.first { $0["type"]?.string == "integer" }
            let lower = range?["minimum"]?.int ?? 0
            let upper = range?["maximum"]?.int ?? 0
            let bounds = lower == 0 ? "1 to \(upper), or 0 to clear the limit" : "\(lower) to \(upper)"
            return PlannerError("Invalid argument 'minutes': enter an integer from \(bounds).")
        }
        if tool == "add_tasks", key == "titles", value.array == nil {
            return PlannerError("Add at least one task title with text.")
        }
        if tool == "start_timer", key == "task" {
            return PlannerError(
                "Invalid argument 'task': enter a non-empty task id or title, or omit it for a standalone session.")
        }
        if key == "task" { return PlannerError("Identify the task by id from list_tasks or by title.") }
        if tool == "rename_task", key == "title" { return PlannerError("Enter replacement title text.") }
        if tool == "move_task", key == "to" { return PlannerError("Set a destination date or use inbox.") }
        if tool == "write_notepad", key == "text" {
            return PlannerError("Enter note text using 20000 characters or fewer.")
        }
        return PlannerError("Invalid argument '\(key)': expected \(schema["type"]?.string ?? "a valid value").")
    }
}
