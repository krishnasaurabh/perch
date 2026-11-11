import Charts
import PlannerCore
import SwiftUI

struct InsightsDashboard: View {
    @EnvironmentObject var store: PlannerStore
    var body: some View {
        let i = store.engine.insights()
        let lastDone = i.lastSeven.reduce(0) { $0 + $1.completed },
            prevDone = i.previousSeven.reduce(0) { $0 + $1.completed }
        let lastFocus = i.lastSeven.reduce(0) { $0 + $1.focusSeconds },
            prevFocus = i.previousSeven.reduce(0) { $0 + $1.focusSeconds }
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                tile("Streak", "\(i.streak) day\(i.streak == 1 ? "" : "s")", "flame.fill")
                tile("Done this week", "\(lastDone)", "checkmark.circle", delta: lastDone - prevDone)
                tile(
                    "Focus this week", TimerText.short(lastFocus), "timer", delta: Int((lastFocus - prevFocus) / 60),
                    unit: "m")
                tile("All time", "\(i.allTimeCompleted) tasks", "trophy")
            }
            VStack(alignment: .leading) {
                Text("Planned vs. done, last 7 days").font(Theme.heading)
                Chart {
                    ForEach(i.lastSeven, id: \.day) { d in
                        BarMark(x: .value("Day", d.day.date(), unit: .day), y: .value("Planned", d.planned))
                            .foregroundStyle(Theme.chartPlanned)
                        BarMark(x: .value("Day", d.day.date(), unit: .day), y: .value("Completed", d.completed))
                            .foregroundStyle(Theme.chartCompleted)
                    }
                }.frame(height: 170)
                HStack {
                    Label("Planned", systemImage: "square").foregroundStyle(Theme.secondary)
                    Label("Completed", systemImage: "square.fill").foregroundStyle(Theme.text)
                }.font(Theme.meta)
            }.card(.timer)
            VStack(alignment: .leading) {
                Text("Minutes focused, last 7 days").font(Theme.heading)
                Chart(i.lastSeven, id: \.day) { d in
                    AreaMark(x: .value("Day", d.day.date(), unit: .day), y: .value("Minutes", d.focusSeconds / 60))
                        .foregroundStyle(Theme.chartPlanned).interpolationMethod(.catmullRom)
                    LineMark(x: .value("Day", d.day.date(), unit: .day), y: .value("Minutes", d.focusSeconds / 60))
                        .foregroundStyle(Theme.chartCompleted).interpolationMethod(.catmullRom)
                }.frame(height: 150)
            }.card(.timer)
            if !i.peakHours.isEmpty {
                Text(
                    "Your peak hours: "
                        + i.peakHours.map {
                            Calendar.current.date(bySettingHour: $0, minute: 0, second: 0, of: Date())!.formatted(
                                date: .omitted, time: .shortened)
                        }.joined(separator: ", ")
                )
                .font(Theme.body)
            } else {
                Text("No focus sessions yet. Run a timer to see your best hours.").foregroundStyle(Theme.secondary)
            }
        }
    }

    func tile(_ label: String, _ value: String, _ symbol: String, delta: Int? = nil, unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol).font(Theme.meta).foregroundStyle(Theme.secondary)
            Text(value).font(Theme.heading)
            if let delta {
                Text(
                    delta == 0 ? "same as the week before" : "\(delta > 0 ? "+" : "")\(delta)\(unit) vs the week before"
                )
                .font(Theme.meta).foregroundStyle(delta >= 0 ? Theme.success : Theme.warning)
            }
        }
        .padding(Theme.cardPadding).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.fill))
    }
}
