import Foundation
import PlannerCore

extension AgentTools {
    /// Evaluate inside the command transaction, never from a cached UI preference.
    func checkPermissions(_ name: String, commands: PlannerCommands) throws {
        let prefs = commands.planner.preferences
        let timeTools: Set<String> = ["start_timer", "pause_timer", "resume_timer", "stop_timer"]
        if timeTools.contains(name) {
            guard prefs.agentsCanControlTime else {
                throw PlannerError(
                    "Start and stop time blocks is off for agents. Your time block is unchanged. Turn it on in Settings to allow this change."
                )
            }
            return
        }
        if name != "list_tasks" && !Self.isReadOnly(name) && !prefs.agentsCanEditTasks {
            throw PlannerError(
                "Add and edit tasks is off for agents. Your tasks are unchanged. Turn it on in Settings to allow this change."
            )
        }
        // Legacy notes and promotion can expose existing parked text too.
        if ["list_parked_thoughts", "read_notepad", "write_notepad", "promote_parked_thought"].contains(name),
            !prefs.agentsCanReadParkingLot
        {
            throw PlannerError(
                "Read the parking lot is off for agents. Your thoughts are private. Turn it on in Settings to allow access."
            )
        }
    }

    func checkActiveBlock(_ name: String, args: JSON, commands: PlannerCommands) throws {
        guard ["complete_task", "delete_task"].contains(name), !commands.planner.preferences.agentsCanControlTime,
            let active = commands.planner.focus, active.state != .finished
        else { return }
        let day = try DayRef.parse(
            args["date"]?.string, now: now(), resetHour: commands.planner.preferences.resetHour, calendar: calendar)
        let id = try TaskReferenceResolver.resolve(args["task"]!.string!, in: commands.planner, on: day)
        if active.taskID == id {
            throw PlannerError(
                "Start and stop time blocks is off for agents. This task has a time block. Stop it in Perch before changing the task."
            )
        }
    }

    func pendingDelete(_ args: JSON, commands: PlannerCommands, agentID: String) throws -> AgentToolResult {
        let day = try DayRef.parse(
            args["date"]?.string, now: now(), resetHour: commands.planner.preferences.resetHour, calendar: calendar)
        let id = try TaskReferenceResolver.resolve(args["task"]!.string!, in: commands.planner, on: day)
        let action = try commands.requestAgentDeletion(id, agentID: agentID, at: now())
        let expires = ISO8601DateFormatter().string(from: action.expiresAt)
        return AgentToolResult(
            text:
                "Deleting '\(action.task.title)' is waiting for you in Perch. Keep applies it. Undo or a timeout leaves the task unchanged.",
            structuredContent: [
                "task": taskJSON(action.task, commands.read), "status": "pending",
                "pending_action_id": .string(action.id.uuidString.lowercased()), "expires_at": .string(expires),
                "content_trust": "untrusted",
            ])
    }
}
