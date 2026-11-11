import PlannerCore
import PerchUI
import SwiftUI

/// Today: today's tasks with the capture field, and beside them only what matters right now:
/// the focus timer while it runs, today's agenda when there are events, the notepad if turned on.
struct HomePage: View {
    @EnvironmentObject var services: Services
    var body: some View { HomeBody(calendar: services.calendar) }
}

private struct HomeBody: View {
    @ObservedObject var calendar: CalendarService
    @EnvironmentObject var store: PlannerStore

    var body: some View {
        TimelineView(.explicit(calendar.events.map(\.end).sorted())) { context in
            content(at: context.date)
        }
    }

    @ViewBuilder private func content(at now: Date) -> some View {
        let timer = store.planner.focus.map { $0.state != .finished } ?? false
        let events = calendar.hasAccess && calendar.events.contains { $0.end > now }
        let side = HomeLayout.sideCards(store.prefs, timerActive: timer, hasEvents: events)
        VStack(spacing: Theme.gutter) {
            HStack(alignment: .top, spacing: Theme.gutter) {
                TasksCard().frame(maxHeight: .infinity)
                if !side.isEmpty {
                    Group {
                        if side.count == 1, let id = side.first {
                            sideCard(id).frame(maxHeight: .infinity)
                        } else {
                            // Optional cards scroll independently: never squeeze the timer's controls
                            // or move today's capture out of view when all three cards are enabled.
                            ScrollView {
                                VStack(spacing: Theme.gutter) {
                                    ForEach(side, id: \.self) { id in
                                        sideCard(id).frame(minHeight: id == "notepad" ? 160 : nil)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: Theme.sideColumn)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        // Card enter/leave: the timer starting or today's events loading fades a card in while the task card resizes.
        .motion(Motion.card, value: side)
    }

    @ViewBuilder private func sideCard(_ id: String) -> some View {
        switch id {
        case "focus": FocusCard()
        case "events": AgendaCard()
        default: NotepadCard().frame(maxHeight: .infinity)
        }
    }
}
