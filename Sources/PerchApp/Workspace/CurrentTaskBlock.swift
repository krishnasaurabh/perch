import PlannerCore
import PerchUI
import SwiftUI

/// The current task is always open, independent of the other disclosure rows.
struct CurrentTaskBlock<Completion: View, Title: View, Steps: View>: View {
    let task: PlanTask
    @ViewBuilder var completion: () -> Completion
    @ViewBuilder var title: () -> Title
    @ViewBuilder var steps: () -> Steps
    @EnvironmentObject var store: PlannerStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Size.focusGap.value * 3) {
            HStack(alignment: .top, spacing: Theme.Size.focusGap.value * 3) {
                completion()
                VStack(alignment: .leading, spacing: Theme.Size.cardEdge.value) {
                    title()
                    Text(summary).perchFont(.detail).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PerchPill("Now", surface: .paper, ink: .brandText)
            }
            steps()
        }
        .padding(.vertical, Theme.Size.cardPadding.value - Theme.Size.focusGap.value * 3)
        .padding(.horizontal, Theme.Size.cardPadding.value / 2)
        .background(RoundedRectangle(cornerRadius: Theme.Size.currentTaskRadius.value).fill(Theme.butter))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Size.currentTaskRadius.value)
                .strokeBorder(Theme.edge(.butter), lineWidth: Theme.Size.cardEdge.value)
        )
        .environment(\.designSurface, .butter)
        .accessibilityIdentifier("current-task-block")
    }

    private var summary: String {
        let focus = store.planner.focus.flatMap { $0.taskID == task.id ? $0 : nil }
        let start = focus?.startedAt ?? task.startAt
        var bits: [String] = []
        if let start {
            let duration: Double?
            if let focus { duration = focus.limit } else { duration = task.minutes.map { Double($0) * 60 } }
            if let seconds = duration {
                let end = start.addingTimeInterval(seconds)
                bits.append(
                    start.formatted(date: .omitted, time: .shortened) + " – "
                        + end.formatted(date: .omitted, time: .shortened))
            } else {
                bits.append(start.formatted(date: .omitted, time: .shortened))
            }
        }
        if !task.steps.isEmpty {
            bits.append(AppL10n.format("%lld of %lld steps", task.steps.filter(\.done).count, task.steps.count))
        }
        return bits.joined(separator: " · ")
    }
}
