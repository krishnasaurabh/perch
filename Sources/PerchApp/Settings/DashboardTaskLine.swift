import PlannerCore
import SwiftUI

struct DashboardTaskLine: View {
    let task: PlanTask
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.done ? "checkmark.circle.fill" : "circle").foregroundStyle(
                task.done ? Theme.success : Theme.secondary)
            Text(task.title).strikethrough(task.done)
            if let p = store.engine.project(id: task.projectID) {
                Text("#\(p.name)").foregroundStyle(Color(hex: p.colorHex)).font(Theme.meta)
            }
            if let agent = task.agentID, let name = AgentName.short(agent) {
                Text("via " + name).font(Theme.meta).foregroundStyle(Theme.secondary).help(agent)
            }
            if task.focusedSeconds > 0 {
                Text(TimerText.short(task.focusedSeconds)).font(Theme.meta).foregroundStyle(Theme.secondary)
            }
            if let c = task.carriedFrom {
                Text("carried from \(c.raw)").font(Theme.meta).foregroundStyle(Theme.tertiary)
            }
        }
    }
}
