import PerchUI
import PlannerCore

@MainActor
extension PlannerStore {
    /// Generate the ordinary scheduling window even if Home/Week have never been visited.
    /// Use the existing command gateway and repeat ledger; never invent a second recurrence engine.
    func renewReminderHorizon() {
        let calendar = engine.calendar
        let days = ReminderSchedule.days(today: today, calendar: calendar)
        var preview = engine
        for day in days { preview.applyRepeats(on: day) }
        guard preview.planner != planner else { return }
        performMutation(origin: .background) { commands in
            for day in days { try commands.execute(.lifecycle(.openDay(day))) }
        }
    }
}
