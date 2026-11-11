import PlannerCore
import SwiftUI

struct HistoryList: View {
    @EnvironmentObject var store: PlannerStore
    @State private var query = ""
    @State private var agentFilter: String?
    var body: some View {
        let history = store.planner.tasks.filter { ($0.day.map { $0 < store.today } ?? false) }
        let agents = Array(Set(history.compactMap(\.agentID))).sorted()
        let past = history.filter { agentFilter == nil || $0.agentID == agentFilter }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        let groups = Dictionary(grouping: past, by: { $0.day! }).sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("Search history", text: $query).textFieldStyle(.roundedBorder).frame(width: 280)
                Picker("Agent", selection: $agentFilter) {
                    Text("All agents").tag(String?.none)
                    ForEach(agents, id: \.self) { name in
                        Text(AgentName.short(name) ?? name).tag(String?.some(name))
                    }
                }.frame(width: 150)
            }
            if groups.isEmpty {
                Text(query.isEmpty ? "Finished days show up here." : "No matches. Change the search text.")
                    .foregroundStyle(Theme.secondary)
            }
            ForEach(groups, id: \.key) { day, tasks in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(day.date().formatted(.dateTime.weekday(.wide).month().day())).font(Theme.heading)
                        Text(AppL10n.format("%lld/%lld done", tasks.filter(\.done).count, tasks.count)).foregroundStyle(
                            Theme.secondary)
                    }
                    ForEach(tasks) { t in DashboardTaskLine(task: t) }
                    let note = store.engine.notepad(on: day)
                    if !note.isEmpty {
                        Text(note).font(Theme.body).foregroundStyle(Theme.secondary).padding(.leading, 22)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
