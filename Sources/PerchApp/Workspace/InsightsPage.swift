import PerchUI
import PlannerCore
import SwiftUI

/// The breakpoint uses page width, after the workspace's horizontal insets.
enum InsightsPageLayout {
    case stacked, twoColumn

    // Leaves a 460pt chart beside the 272pt momentum card and 8pt gutter.
    static let twoColumnMinimumWidth: CGFloat = 740

    static func resolve(width: CGFloat) -> Self {
        .twoColumn
    }
}

/// Insights lives on its own tab. A seven-day chart on lavender, momentum on sage.
struct InsightsPage: View {
    @EnvironmentObject var store: PlannerStore
    @State private var metric: Metric = .tasks
    enum Metric: Hashable, CaseIterable {
        case tasks, focus

        func title(locale: Locale? = nil) -> String {
            switch self {
            case .tasks: AppL10n.text("Tasks", locale: locale)
            case .focus: AppL10n.text("Focus", locale: locale)
            }
        }
    }

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
            GeometryReader { geometry in
                switch InsightsPageLayout.resolve(width: geometry.size.width) {
                case .stacked:
                    VStack(spacing: Theme.gutter) {
                        chart(i).frame(maxHeight: .infinity)
                        momentum(i).frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .twoColumn:
                    HStack(alignment: .top, spacing: Theme.gutter) {
                        chart(i).frame(maxHeight: .infinity)
                        momentum(i).frame(width: Theme.sideColumn).frame(maxHeight: .infinity)
                    }
                }
            }
            .onAppear {
                // Focus logged but nothing finished this week: open on the chart that has something to show.
                if i.lastSeven.allSatisfy({ $0.completed == 0 && $0.planned == 0 })
                    && i.lastSeven.contains(where: { $0.focusSeconds > 0 })
                {
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
                SegmentPills(
                    items: [(Metric.tasks, Metric.tasks.title()), (Metric.focus, Metric.focus.title())],
                    selection: $metric)
                Spacer()
                Text(
                    AppL10n.format(
                        "%@ – %@", first.formatted(.dateTime.day().month(.abbreviated)),
                        last.formatted(.dateTime.day().month(.abbreviated)))
                )
                .font(Theme.meta).foregroundStyle(Theme.secondary)
            }
            WeekBars(days: days, metric: metric, today: store.today)
                .id(metric)  // switching metric regrows the bars
                .frame(maxHeight: .infinity)
            HStack(spacing: 14) {
                if metric == .tasks {
                    legend(Theme.chartCompleted, AppL10n.text("Completed"))
                    legend(Theme.chartPlanned, AppL10n.text("Planned"))
                } else {
                    legend(Theme.chartCompleted, AppL10n.text("Minutes focused"))
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
            Text(subline(done: done, before: before, focusThisWeek: focus)).font(Theme.body).foregroundStyle(
                Theme.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                stat(PerchL10n.number(done), AppL10n.text("tasks done this week"))
                stat(TimerText.short(focus), AppL10n.text("focused this week"))
                stat(AppL10n.format("%lld days", i.streak), AppL10n.text("streak"))
                stat(AppL10n.format("%lld/%lld", i.today.completed, i.today.planned), AppL10n.text("done today"))
                if i.allTimeCompletedCalendarEvents > 0 {
                    stat(
                        PerchL10n.number(i.today.completedCalendarEvents),
                        AppL10n.text("calendar events checked off today")
                    )
                    .help(
                        AppL10n.format(
                            "Checked off in Perch. %lld all time; Calendar is unchanged.",
                            i.allTimeCompletedCalendarEvents)
                    )
                }
            }
        }
        .card(.tasks)
    }

    private func headline(done: Int, before: Int) -> String {
        if done == 0 { return AppL10n.text("A fresh week") }
        if done > before { return AppL10n.text("Ahead of last week") }
        if done == before { return AppL10n.text("Holding steady") }
        return AppL10n.text("A quieter week")
    }

    private func subline(done: Int, before: Int, focusThisWeek: Double) -> String {
        if done == 0 {
            return AppL10n.text(
                focusThisWeek > 0
                    ? "Focus is logged. Finish a task to fill in the week."
                    : "Finish one task and your week starts here.")
        }
        if before == 0 { return AppL10n.format("%lld tasks done this week.", done) }
        return done > before
            ? AppL10n.format("%lld tasks done, up from %lld the week before.", done, before)
            : AppL10n.format("%lld tasks done, against %lld the week before.", done, before)
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

/// Seven days of bars. Completed (solid) stands in front of Planned (translucent).
///
/// Planned is a stable comparison silhouette: it is at its final height from the first frame and never animates.
/// Only Completed grows from the baseline, left to right: spring R 0.30 ζ 1 with a 130 ms stagger
/// Reduce Motion drops the growth entirely.
///
/// One quiet label in tertiary ink sits on the top line and names the value it stands for ("5 tasks", "1m"),
/// so a short week cannot pass for a big one. The top line and the baseline are single-pixel hairlines; no other
/// gridlines, tick marks, vertical axis or legend.
struct WeekBars: View {
    let days: [Insights.Day]
    let metric: InsightsPage.Metric
    let today: DayKey
    @State private var grown = false
    @Environment(\.motionPolicy) private var policy
    @Environment(\.displayScale) private var displayScale

    enum Series: CaseIterable { case planned, completed }

    /// Height one bar draws at. Planned ignores `grown`; Completed sits on the baseline until the chart appears.
    static func height(_ series: Series, final: CGFloat, grown: Bool) -> CGFloat {
        series == .planned || grown ? max(final, 0) : 0
    }

    /// The growth animation for one bar: none for Planned, none under Reduce Motion, else the bars token + stagger.
    static func growth(_ series: Series, index: Int, policy: MotionPolicy) -> Animation? {
        guard series == .completed else { return nil }
        return policy.animation(Motion.bar.delay(Double(index) * Motion.barStagger))
    }

    /// The value at the top line: "1 task", "5 tasks", or focus time as the momentum card writes it ("1m", "1h 20m").
    static func scaleLabel(top: Double, metric: InsightsPage.Metric) -> String {
        switch metric {
        case .tasks:
            let n = Int(top.rounded())
            return PerchL10n.tasks(count: n)
        case .focus:
            return TimerText.short(top * 60)
        }
    }

    /// Height reserved above the top line for the scale label (one `Theme.meta` line plus a hair of air).
    static let scaleStrip: CGFloat = 16

    var body: some View {
        let values = days.map { metric == .tasks ? Double($0.completed) : $0.focusSeconds / 60 }
        let planned = days.map { metric == .tasks ? Double($0.planned) : 0 }
        let top = max(1, (values + planned).max() ?? 1)
        let empty = values.allSatisfy { $0 == 0 } && planned.allSatisfy { $0 == 0 }
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                // The single scale mark, resting on the top line it names. With no data there is no scale to name.
                if !empty {
                    Text(Self.scaleLabel(top: top, metric: metric))
                        .font(Theme.meta.monospacedDigit()).foregroundStyle(Theme.tertiary)
                        .lineLimit(1).fixedSize()
                        .frame(height: Self.scaleStrip, alignment: .bottom)
                        .padding(.bottom, 2)
                        .accessibilityLabel(
                            AppL10n.format("Chart top line: %@", Self.scaleLabel(top: top, metric: metric)))
                } else {
                    Color.clear.frame(height: Self.scaleStrip + 2)
                }
                plot(values: values, planned: planned, top: top, empty: empty)
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
            if policy.reduceMotion { grown = true } else { DispatchQueue.main.async { grown = true } }
        }
    }

    private func plot(values: [Double], planned: [Double], top: Double, empty: Bool) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                VStack(spacing: 0) {
                    // Only the top line the scale label names, plus the baseline. Unlabeled quarter lines
                    // fell on fractional values and showed through the translucent Planned bars.
                    // With no data only the baseline stays, so the hint never sits on a gridline.
                    // Both are one device pixel, so they guide the eye without framing the plot like a box.
                    let hairline = 1 / max(displayScale, 1)
                    Rectangle().fill(Theme.chartPlanned.opacity(empty ? 0 : 0.35)).frame(height: hairline)
                    Spacer(minLength: 0)
                    Rectangle().fill(Theme.chartPlanned).frame(height: hairline)
                }
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach(days.indices, id: \.self) { i in
                        ZStack(alignment: .bottom) {
                            if planned[i] > 0 {
                                bar(.planned, planned[i] / top * h, color: Theme.chartPlanned, index: i)
                            }
                            // A zero day keeps a 2 pt stub on the baseline so it reads as "none", not missing data.
                            bar(
                                .completed, max(values[i] / top * h, planned[i] > 0 || values[i] > 0 ? 2 : 0),
                                color: Theme.chartCompleted, index: i)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(label(days[i], values[i], planned[i]))
                    }
                }
                if empty {
                    Text(
                        metric == .tasks
                            ? "Your week will fill in as you finish tasks."
                            : "Time a session and your minutes show up here."
                    )
                    .font(Theme.meta).foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    private func bar(_ series: Series, _ height: CGFloat, color: Color, index i: Int) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous)
            .fill(color)
            .frame(height: Self.height(series, final: height, grown: grown))
            .animation(Self.growth(series, index: i, policy: policy), value: grown)
    }

    private func label(_ d: Insights.Day, _ v: Double, _ p: Double) -> String {
        let day = d.day.date().formatted(.dateTime.weekday(.wide).month().day())
        return metric == .tasks
            ? AppL10n.format("%@: %lld of %lld done", day, Int(v), Int(p))
            : AppL10n.format("%@: %lld minutes focused", day, Int(v))
    }
}
