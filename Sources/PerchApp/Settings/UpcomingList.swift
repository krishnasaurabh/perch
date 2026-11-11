import PlannerCore
import SwiftUI

struct UpcomingList: View {
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        let future = store.planner.tasks.filter { ($0.day.map { $0 > store.today } ?? false) }
        let groups = Dictionary(grouping: future, by: { $0.day! }).sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: 16) {
            if groups.isEmpty {
                Text("Nothing planned ahead. Add “tomorrow” or a day to a task.").foregroundStyle(Theme.secondary)
            }
            ForEach(groups, id: \.key) { day, tasks in
                VStack(alignment: .leading, spacing: 4) {
                    Text(day.date().formatted(.dateTime.weekday(.wide).month().day())).font(Theme.heading)
                    ForEach(tasks) { t in DashboardTaskLine(task: t) }
                }
            }
            let inbox = store.engine.tasks(on: .inbox)
            if !inbox.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Inbox").font(Theme.heading)
                    ForEach(inbox) { t in DashboardTaskLine(task: t) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
