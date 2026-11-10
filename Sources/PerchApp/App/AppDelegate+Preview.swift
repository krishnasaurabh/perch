import Foundation
import PlannerCore

extension AppDelegate {
    /// Sample day for screenshots (`--demo`), only into an empty planner.
    func seedDemo() {
        guard store.planner.tasks.isEmpty else { return }
        store.apply { e in
            _ = try e.addTasks([
                "Draft release notes !high #launch for 50 min", "Call the bank at 4pm", "Merge the auth branch #work",
                "Water the plants every 3 days", "Plan team offsite friday", "Renew car registration next monday",
                "Learn piano someday",
            ])
            _ = try e.complete("Merge the auth branch")
            try e.writeNotepad(on: e.today, text: "Try batching email to 11 and 4\nQuestions for the design sync")
            _ = try e.startTimer(task: "Draft release notes", minutes: 50)
            e.planner.preferences.welcomeCompleted = true
        }
    }

    /// Fixed planner states for CI snapshots (`--scenario <name>`), only into an empty planner.
    /// `empty`: nothing yet. `three`: three tasks for today. `timer`: the same with a focus session running.
    /// `insights`: two weeks of finished tasks and focus, for the Insights page.
    func seedScenario(_ name: String) {
        guard store.planner.tasks.isEmpty else { return }
        store.apply { e in
            e.planner.preferences.welcomeCompleted = true
            switch name {
            case "three", "timer":
                let added = try e.addTasks(
                    ["Draft the test checklist !high #work", "Review the release notes", "Choose a desk plant"],
                    on: .day(e.today))
                if name == "timer", let first = added.first {
                    _ = try e.startTimer(task: first.id.uuidString, minutes: 45)
                }
            case "insights":
                let cal = Calendar.current, now = Date()
                let doneByDay = [2, 4, 3, 5, 1, 6, 4, 3, 2, 3, 2, 0, 3, 2]  // index 0 = 13 days ago, 13 = today
                for (i, done) in doneByDay.enumerated() {
                    let ago = doneByDay.count - 1 - i
                    let date = cal.date(byAdding: .day, value: -ago, to: now)!
                    let day = e.dayKey(date)
                    for n in 0..<(done + 1 + i % 2) {
                        let finished = n < done
                        let at = cal.date(bySettingHour: 9 + n, minute: 15, second: 0, of: date) ?? date
                        e.planner.tasks.append(
                            PlanTask(
                                title: "Task \(n + 1)", day: day, done: finished, completedAt: finished ? at : nil,
                                createdAt: date))
                    }
                    if ago > 0, done > 0, let start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: date) {
                        e.planner.focusLog.append(
                            FocusSegment(taskID: nil, start: start, end: start.addingTimeInterval(Double(done) * 600)))
                    }
                }
            default: break
            }
        }
    }
}
