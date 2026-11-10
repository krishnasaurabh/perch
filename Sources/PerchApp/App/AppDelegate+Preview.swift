import Foundation
import PlannerCore

extension AppDelegate {
    /// Sample day for screenshots (`--demo`), only into an empty planner.
    func seedDemo() {
        guard store.planner.tasks.isEmpty else { return }
        store.apply { e in
            let added = try e.addTasks([
                "Draft release notes !high #launch for 50 min", "Call the bank at 4pm", "Merge the auth branch #work",
                "Water the plants every 3 days", "Plan team offsite friday", "Renew car registration next monday",
                "Learn piano someday",
            ])
            _ = try e.complete(added[2].id)
            try e.writeNotepad(on: e.today, text: "Try batching email to 11 and 4\nQuestions for the design sync")
            _ = try e.startTimer(task: added[0].id, minutes: 50)
            try e.updatePrefs { $0.welcomeCompleted = true }
        }
    }

    /// Fixed planner states for CI snapshots (`--scenario <name>`), only into an empty planner.
    /// `empty`: nothing yet. `three`: three tasks for today. `timer`: the same with a focus session running.
    /// `insights`: two weeks of finished tasks and focus, for the Insights page.
    func seedScenario(_ name: String) {
        guard store.planner.tasks.isEmpty else { return }
        let scenario: PlannerPreview
        switch name {
        case "three": scenario = .three
        case "timer": scenario = .timer
        case "insights": scenario = .insights
        default: scenario = .empty
        }
        store.send(.seedPreview(scenario), origin: .background)
    }
}
