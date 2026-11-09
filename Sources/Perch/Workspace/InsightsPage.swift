import PlannerCore
import SwiftUI

/// Insights lives on its own tab. A seven-day chart on the lavender card, momentum beside it on sage.
struct InsightsPage: View {
    @EnvironmentObject var store: PlannerStore
    @State private var metric: Metric = .tasks
    enum Metric: Hashable { case tasks, focus }

    var body: some View {
        let i = store.engine.insights()
        if i.allTimeCompleted == 0 && i.allTimeFocusSeconds == 0 {
            // Nothing recorded yet: one warm line instead of an empty chart.
            VStack {
                Spacer(minLength: 0)
                EmptyStateView("Your progress will take shape here.", symbol: "chart.bar")
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .card(.timer)
        } else {
            HStack(alignment: .top, spacing: Theme.gutter) {
                chart(i).frame(maxHeight: .infinity)
                momentum(i).frame(width: Theme.sideColumn).frame(maxHeight: .infinity)
            }
            .onAppear {
                // Focus logged but nothing finished this week: open on the chart that has something to show.
                if i.lastSeven.allSatisfy({ $0.completed == 0 && $0.planned == 0 }) && i.lastSeven.contains(where: { $0.focusSeconds > 0 }) {
                    metric = .focus
                }
            }
        }
    }

    // MARK: Chart

    private func chart(_ i: Insights) -> some View {
        let days = i.lastSeven
        let first = days.first?.day.date() ?? Date(), last = days.last?.day.date() ?? Date()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SegmentPills(items: [(Metric.tasks, "Tasks"), (Metric.focus, "Focus")], selection: $metric)
                Spacer()
                Text("\(first.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated)))")
                    .font(Theme.meta).foregroundStyle(Theme.secondary)
            }
            WeekBars(days: days, metric: metric, today: store.today)
                .id(metric)  // switching metric regrows the bars
                .frame(maxHeight: .infinity)
            HStack(spacing: 14) {
                if metric == .tasks {
                    legend(Theme.chartCompleted, "Completed")
                    legend(Theme.chartPlanned, "Planned")
                } else {
                    legend(Theme.chartCompleted, "Minutes focused")
                }
                Spacer()
            }
        }
        .card(.timer)
    }

    private func legend(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(label).font(Theme.meta).foregroundStyle(Theme.secondary)
        }
    }

    // MARK: Momentum

    private func momentum(_ i: Insights) -> some View {
        let done = i.lastSeven.reduce(0) { $0 + $1.completed }, before = i.previousSeven.reduce(0) { $0 + $1.completed }
        let focus = i.lastSeven.reduce(0) { $0 + $1.focusSeconds }
        return VStack(alignment: .leading, spacing: 12) {
            CardHeading(headline(done: done, before: before))
            Text(subline(done: done, before: before, focusThisWeek: focus)).font(Theme.body).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                stat("\(done)", "tasks done this week")
                stat(TimerText.short(focus), "focused this week")
                stat("\(i.streak) day\(i.streak == 1 ? "" : "s")", "streak")
                stat("\(i.today.completed)/\(i.today.planned)", "done today")
                if i.allTimeCompletedCalendarEvents > 0 {
                    stat("\(i.today.completedCalendarEvents)", "calendar events checked off today")
                        .help("Checked off in Perch. \(i.allTimeCompletedCalendarEvents) all time; Calendar is unchanged.")
                }
            }
        }
        .card(.tasks)
    }

    private func headline(done: Int, before: Int) -> String {
        if done == 0 { return "A fresh week" }
        if done > before { return "Ahead of last week" }
        if done == before { return "Holding steady" }
        return "A quieter week"
    }

    private func subline(done: Int, before: Int, focusThisWeek: Double) -> String {
        if done == 0 { return focusThisWeek > 0 ? "Focus is logged. Finish a task to fill in the week." : "Finish one task and your week starts here." }
        let noun = done == 1 ? "task" : "tasks"
        if before == 0 { return "\(done) \(noun) done this week." }
        return done > before ? "\(done) \(noun) done, up from \(before) the week before." : "\(done) \(noun) done, against \(before) the week before."
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.system(size: 15, weight: .bold).monospacedDigit())
            Text(label).font(Theme.meta).foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Seven days of bars. Completed (solid) stands in front of Planned (translucent). On appear each bar grows from
/// the baseline, left to right: spring R 0.30 ζ 1 with a 130 ms stagger.
struct WeekBars: View {
    let days: [Insights.Day]
    let metric: InsightsPage.Metric
    let today: DayKey
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let values = days.map { metric == .tasks ? Double($0.completed) : $0.focusSeconds / 60 }
        let planned = days.map { metric == .tasks ? Double($0.planned) : 0 }
        let top = max(1, (values + planned).max() ?? 1)
        let empty = values.allSatisfy { $0 == 0 } && planned.allSatisfy { $0 == 0 }
        VStack(spacing: 6) {
            GeometryReader { geo in
                let h = geo.size.height
                ZStack {
                    VStack(spacing: 0) {
                        // With no data only the baseline stays, so the hint never sits on a gridline.
                        ForEach(0..<4, id: \.self) { _ in
                            Rectangle().fill(Theme.chartPlanned.opacity(empty ? 0 : 0.35)).frame(height: 1)
                            Spacer(minLength: 0)
                        }
                        Rectangle().fill(Theme.chartPlanned).frame(height: 1)
                    }
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach(days.indices, id: \.self) { i in
                            ZStack(alignment: .bottom) {
                                if planned[i] > 0 {
                                    bar(planned[i] / top * h, color: Theme.chartPlanned, index: i)
                                }
                                // A zero day keeps a 2 pt stub on the baseline so it reads as "none", not missing data.
                                bar(max(values[i] / top * h, planned[i] > 0 || values[i] > 0 ? 2 : 0), color: Theme.chartCompleted, index: i)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(label(days[i], values[i], planned[i]))
                        }
                    }
                    if empty {
                        Text(metric == .tasks ? "Your week will fill in as you finish tasks." : "Time a session and your minutes show up here.")
                            .font(Theme.meta).foregroundStyle(Theme.secondary)
                    }
                }
            }
            HStack(spacing: 14) {
                ForEach(days, id: \.day) { d in
                    let isToday = d.day == today
                    VStack(spacing: 1) {
                        Text(d.day.date().formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 10.5, weight: isToday ? .bold : .medium))
                        Text(d.day.date().formatted(.dateTime.day()))
                            .font(.system(size: 10, weight: isToday ? .bold : .regular).monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            guard !grown else { return }
            if reduce { grown = true } else { DispatchQueue.main.async { grown = true } }
        }
    }

    private func bar(_ height: CGFloat, color: Color, index i: Int) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous)
            .fill(color)
            .frame(height: grown ? max(height, 0) : 0)
            .animation(reduce ? nil : Motion.bar.delay(Double(i) * Motion.barStagger), value: grown)
    }

    private func label(_ d: Insights.Day, _ v: Double, _ p: Double) -> String {
        let day = d.day.date().formatted(.dateTime.weekday(.wide).month().day())
        return metric == .tasks ? "\(day): \(Int(v)) of \(Int(p)) done" : "\(day): \(Int(v)) minutes focused"
    }
}
