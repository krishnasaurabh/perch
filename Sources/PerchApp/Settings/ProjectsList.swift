import PlannerCore
import SwiftUI

struct ProjectsList: View {
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.planner.projects.isEmpty {
                Text("No projects yet. Add #project to a new task.").foregroundStyle(.secondary)
            }
            ForEach(store.planner.projects) { p in
                let tasks = store.planner.tasks.filter { $0.projectID == p.id }
                let open = tasks.filter { !$0.done && ($0.day == nil || $0.day! >= store.today) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(Color(hex: p.colorHex)).frame(width: 10, height: 10)
                        Text(p.name).font(.headline)
                        Text("\(open.count) open · \(tasks.filter(\.done).count) done").foregroundStyle(.secondary)
                        Spacer()
                        Button("Delete Project", role: .destructive) {
                            store.apply { e in
                                e.planner.projects.removeAll { $0.id == p.id }
                                for i in e.planner.tasks.indices where e.planner.tasks[i].projectID == p.id {
                                    e.planner.tasks[i].projectID = nil
                                }
                            }
                        }.buttonStyle(.borderless)
                    }
                    ForEach(open) { t in DashboardTaskLine(task: t) }
                }
            }
            if !store.planner.projects.isEmpty {
                Text("Deleting a project keeps its tasks, without a project. ⌘Z undoes it.").font(.caption)
                    .foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
