import SwiftUI

enum DashboardWindow {
    @MainActor static func show(store: PlannerStore) {
        WindowHost.show("dashboard", title: "Perch", size: CGSize(width: 900, height: 640)) {
            DashboardView().environmentObject(store)
        }
    }

    @MainActor static func show(store: PlannerStore, model: NotchModel, services: Services) {
        WindowHost.show("dashboard", title: "Perch", size: CGSize(width: 900, height: 640)) {
            DashboardView().environmentObject(store).environmentObject(model).environmentObject(services)
        }
    }
}

// MARK: - Dashboard: Today, Upcoming, History, Insights

struct DashboardView: View {
    @EnvironmentObject var store: PlannerStore
    @State private var tab: Tab = .insights
    enum Tab: String, CaseIterable {
        case upcoming = "Upcoming", history = "History", insights = "Insights", projects = "Projects"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Dashboard section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 420).padding(.top, 34).padding(.bottom, 12)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .upcoming: UpcomingList()
                    case .history: HistoryList()
                    case .insights: InsightsDashboard()
                    case .projects: ProjectsList()
                    }
                }.padding(20)
            }
        }
        .font(Theme.body)
        .foregroundStyle(Theme.text)
        .environment(\.controlSurface, Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 520)
    }
}
