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
                Text("Planned vs. done, last 7 days").font(.headline)
                Chart {
                    ForEach(i.lastSeven, id: \.day) { d in
                        BarMark(x: .value("Day", d.day.date(), unit: .day), y: .value("Planned", d.planned))
                            .foregroundStyle(.gray.opacity(0.35))
                        BarMark(x: .value("Day", d.day.date(), unit: .day), y: .value("Completed", d.completed))
                            .foregroundStyle(Theme.accent)
                    }
                }.frame(height: 170)
            }
            VStack(alignment: .leading) {
                Text("Minutes focused, last 7 days").font(.headline)
                Chart(i.lastSeven, id: \.day) { d in
                    AreaMark(x: .value("Day", d.day.date(), unit: .day), y: .value("Minutes", d.focusSeconds / 60))
                        .foregroundStyle(Theme.accent.opacity(0.3)).interpolationMethod(.catmullRom)
                    LineMark(x: .value("Day", d.day.date(), unit: .day), y: .value("Minutes", d.focusSeconds / 60))
                        .foregroundStyle(Theme.accent).interpolationMethod(.catmullRom)
                }.frame(height: 150)
            }
            if !i.peakHours.isEmpty {
                Text(
                    "Your peak hours: "
                        + i.peakHours.map {
                            Calendar.current.date(bySettingHour: $0, minute: 0, second: 0, of: Date())!.formatted(
                                date: .omitted, time: .shortened)
                        }.joined(separator: ", ")
                )
                .font(.callout)
            } else {
                Text("No focus sessions yet. Run a timer to see your best hours.").foregroundStyle(.secondary)
            }
        }
    }

    func tile(_ label: String, _ value: String, _ symbol: String, delta: Int? = nil, unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded))
            if let delta {
                Text(
                    delta == 0 ? "same as the week before" : "\(delta > 0 ? "+" : "")\(delta)\(unit) vs the week before"
                )
                .font(.caption2).foregroundStyle(delta >= 0 ? .green : .orange)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}
