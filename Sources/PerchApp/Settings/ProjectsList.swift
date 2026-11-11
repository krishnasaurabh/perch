import PlannerCore
import SwiftUI

struct ProjectsList: View {
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.planner.projects.isEmpty {
                Text("No projects yet. Add #project to a new task.").foregroundStyle(Theme.secondary)
            }
            ForEach(store.planner.projects) { p in
                let tasks = store.planner.tasks.filter { $0.projectID == p.id }
                let open = tasks.filter { !$0.done && ($0.day == nil || $0.day! >= store.today) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(Color(hex: p.colorHex)).frame(width: 10, height: 10)
                        Text(p.name).font(Theme.heading)
                        Text(AppL10n.format("%lld open · %lld done", open.count, tasks.filter(\.done).count))
                            .foregroundStyle(Theme.secondary)
                        Spacer()
                        Button("Delete project", role: .destructive) {
                            store.apply { try $0.deleteProject(p.id) }
                        }.buttonStyle(PillStyle())
                    }
                    ForEach(open) { t in DashboardTaskLine(task: t) }
                }
            }
            if !store.planner.projects.isEmpty {
                Text("Deleting a project keeps its tasks, without a project. ⌘Z undoes it.").font(Theme.meta)
                    .foregroundStyle(Theme.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
