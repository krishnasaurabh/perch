import PerchUI
import PlannerCore
import SwiftUI

struct YourWeekView: View {
    static func subtitle(store: PlannerStore) -> String {
        let value = YourWeekModel(engine: store.engine)
        let calendar = store.engine.calendar
        let start = value.weekStart.date(calendar: calendar).formatted(.dateTime.month(.abbreviated).day())
        let endDate = value.weekEnd.date(calendar: calendar)
        let sameMonth = calendar.isDate(
            value.weekStart.date(calendar: calendar), equalTo: endDate, toGranularity: .month)
        let end =
            sameMonth ? endDate.formatted(.dateTime.day()) : endDate.formatted(.dateTime.month(.abbreviated).day())
        if value.done < value.previousDone {
            return AppL10n.format(
                "%@ to %@. %lld things done, a quieter week than the last one.", start, end, value.done)
        }
        return AppL10n.format("%@ to %@. %lld things done this week.", start, end, value.done)
    }

    var body: some View { YourWeekContent() }
}

/// The shared dashboard supplies the sheet, title, subtitle and scrolling boundary.
struct YourWeekContent: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var drafts = ["", "", ""]
    @State private var added: [Int: UUID] = [:]
    @State private var kept = Set<UUID>()
    @FocusState private var draftFocus: Int?

    private var model: YourWeekModel { YourWeekModel(engine: store.engine) }
    private var prompts: [String] {
        [AppL10n.text("First thing"), AppL10n.text("Second thing"), AppL10n.text("Third thing")]
    }

    var body: some View {
        let value = model
        let waiting = value.stillWaiting.filter { !kept.contains($0.id) }
        VStack(alignment: .leading, spacing: Theme.Size.cardGap.value) {
            ReviewColumns(weights: [1.5, 1, 1], stacked: textSize.isAccessibilitySize) {
                Card(.mint) {
                    VStack(alignment: .leading, spacing: SurfaceMetrics.gap) {
                        Text("Done each day").perchFont(.stripTitle)
                        YourWeekBars(days: value.days, calendar: store.engine.calendar)
                    }
                }
                metric(
                    "Time set aside", value: AppL10n.format("%lldh %lldm", value.blockHours, value.blockMinutes),
                    detail: AppL10n.text("spent inside blocks this week"), surface: .blush)
                metric(
                    "Kept going", value: AppL10n.format("%lld days", value.keptGoing),
                    detail: AppL10n.text("in a row with something done. A day off doesn't reset it."), surface: .butter)
            }
            ReviewColumns(weights: [1.5, 1], stacked: textSize.isAccessibilitySize) {
                Card(.apricot) {
                    VStack(alignment: .leading, spacing: SurfaceMetrics.gap) {
                        Text("Still waiting").perchFont(.stripTitle)
                        Text("Keep what matters, or let it go.").perchFont(.detail).foregroundStyle(Theme.ink2)
                        if waiting.isEmpty {
                            Text("Nothing kept moving.").foregroundStyle(Theme.ink2)
                                .frame(minHeight: Theme.Size.taskRowHeight.value, alignment: .leading)
                        }
                        ForEach(waiting) { task in waitingRow(task) }
                        Spacer(minLength: .zero)
                    }
                    .frame(minHeight: ReviewMetrics.lowerContentHeight, alignment: .topLeading)
                }
                Card(.paper) {
                    VStack(alignment: .leading, spacing: SurfaceMetrics.gap) {
                        Text("Next week").perchFont(.stripTitle)
                        Text("Pick up to three things that matter most.").perchFont(.detail).foregroundStyle(Theme.ink2)
                        ForEach(prompts.indices, id: \.self) { index in
                            nextWeekLine(index, day: value.nextWeekStart)
                        }
                        Spacer(minLength: .zero)
                    }
                    .frame(minHeight: ReviewMetrics.lowerContentHeight, alignment: .topLeading)
                }
            }
        }
        .perchFont(.body)
        .onChange(of: value.nextWeekStart) { _, _ in
            added = [:]
            kept = []
        }
    }

    private func metric(_ title: String, value: String, detail: String, surface: PerchSurface) -> some View {
        Card(surface) {
            VStack(alignment: .leading, spacing: SurfaceMetrics.gap / 2) {
                Text(AppL10n.text(title)).perchFont(.stripTitle)
                Spacer(minLength: SurfaceMetrics.gap)
                Text(value).perchFont(.timer)
                Text(detail).perchFont(.body).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: ReviewMetrics.upperContentHeight, alignment: .topLeading)
        }
    }

    private func waitingRow(_ task: PlanTask) -> some View {
        HStack(spacing: .zero) {
            Text(task.title).perchFont(.body).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            PerchButton("Keep", kind: .soft, size: .small) {
                // Acknowledging keeps the task and all its carry history unchanged.
                kept.insert(task.id)
            }
            .accessibilityLabel(AppL10n.format("Keep %@", task.title))
            PerchButton("Let go", kind: .quiet, size: .small) {
                store.apply { try $0.delete(task.id, on: task.day.map(DayRef.day) ?? .inbox) }
            }
            .accessibilityLabel(AppL10n.format("Let go of %@", task.title))
        }
        .padding(.leading, SurfaceMetrics.textInset)
        .padding(.vertical, Theme.Size.checkboxStroke.value)
        .background(RoundedRectangle(cornerRadius: SurfaceMetrics.fieldRadius).fill(Theme.paper))
        .environment(\.designSurface, .paper)
    }

    @ViewBuilder private func nextWeekLine(_ index: Int, day: DayKey) -> some View {
        if let id = added[index], let task = store.planner.tasks.first(where: { $0.id == id }) {
            Label(task.title, systemImage: "checkmark")
                .foregroundStyle(Theme.doneText)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.stripButtonHeight.value, alignment: .leading)
                .accessibilityLabel(AppL10n.format("Added to next week: %@", task.title))
        } else {
            TextField(AppL10n.text(prompts[index]), text: $drafts[index])
                .textFieldStyle(.plain)
                .perchFont(.body)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, SurfaceMetrics.textInset)
                .frame(minHeight: Theme.Size.stripButtonHeight.value)
                .focused($draftFocus, equals: index)
                .focusEffectDisabled()
                .overlay {
                    RoundedRectangle(cornerRadius: SurfaceMetrics.fieldRadius)
                        .strokeBorder(
                            Theme.ink2,
                            style: StrokeStyle(
                                lineWidth: Theme.Size.cardEdge.value,
                                dash: [SurfaceMetrics.gap / 2])
                        )
                        .allowsHitTesting(false)
                }
                .overlay(
                    FocusRing(
                        shape: RoundedRectangle(cornerRadius: SurfaceMetrics.fieldRadius),
                        focused: draftFocus == index, surface: .paper)
                )
                .accessibilityLabel(AppL10n.format("Next week: %@", AppL10n.text(prompts[index])))
                .onSubmit {
                    let title = drafts[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return }
                    if let tasks = store.apply({ try $0.addTasks([title], on: .day(day), literal: true) }),
                        let task = tasks.first
                    {
                        added[index] = task.id
                        drafts[index] = ""
                        draftFocus = index < prompts.count - 1 ? index + 1 : nil
                    }
                }
        }
    }
}

/// A single completion series, with a common baseline and explicit future-day stubs.
struct YourWeekBars: View {
    let days: [YourWeekModel.Day]
    var calendar: Calendar = .current

    var body: some View {
        let maximum = max(days.map(\.done).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: SurfaceMetrics.gap) {
            ForEach(days, id: \.day) { day in
                VStack(spacing: SurfaceMetrics.gap / 2) {
                    if !day.isFuture {
                        Text(PerchL10n.number(day.done)).perchFont(.detailStrong)
                    }
                    RoundedRectangle(cornerRadius: SurfaceMetrics.gap)
                        .fill(Theme.doneFill)
                        .frame(height: Self.barHeight(done: day.done, maximum: maximum, future: day.isFuture))
                    Text(
                        day.isToday
                            ? AppL10n.text("Today")
                            : day.day.date(calendar: calendar).formatted(.dateTime.weekday(.abbreviated))
                    )
                    .perchFont(day.isToday ? .detailStrong : .detail)
                    .bold(day.isToday)
                    .foregroundStyle(day.isToday ? Theme.ink : Theme.ink2)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    day.isFuture
                        ? AppL10n.format("%@: still to come", day.day.raw)
                        : AppL10n.format("%@: %lld done", day.day.raw, day.done))
            }
        }
        .frame(minHeight: ReviewMetrics.chartHeight, alignment: .bottom)
    }

    static func barHeight(done: Int, maximum: Int, future: Bool) -> CGFloat {
        future || done == 0 ? SurfaceMetrics.gap / 2 : ReviewMetrics.barHeight * Double(done) / Double(max(maximum, 1))
    }
}

private enum ReviewMetrics {
    static let barHeight = Theme.Size.buttonHeight.value * 2
    static let chartHeight = barHeight + Theme.Size.addFieldHeight.value
    static let upperContentHeight = chartHeight + Theme.Size.minimumTarget.value
    static let lowerContentHeight = Theme.Size.taskRowHeight.value * 5 + SurfaceMetrics.gap
}

/// Weighted columns measure each child once. Intrinsic height grows with wrapping and text size.
struct ReviewColumns: Layout {
    let weights: [CGFloat]
    var stacked = false
    var gap: CGFloat = SurfaceMetrics.fieldRadius

    struct Cache {
        var width: CGFloat = .zero
        var vertical = false
        var sizes: [CGSize] = []
    }
    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width: CGFloat = proposal.width ?? CGFloat(Theme.Size.todayWidth.value)
        cache.width = width
        cache.vertical = stacked || width < Theme.Size.stripMaxWidth.value + Theme.Size.cardPadding.value * 6
        let widths =
            cache.vertical
            ? Array(repeating: width, count: subviews.count) : columnWidths(width: width, count: subviews.count)
        cache.sizes = zip(subviews, widths).map { view, width in
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            return CGSize(width: width, height: size.height)
        }
        let height =
            cache.vertical
            ? cache.sizes.reduce(0) { $0 + $1.height } + gap * CGFloat(max(0, subviews.count - 1))
            : cache.sizes.map(\.height).max() ?? .zero
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if cache.width != bounds.width || cache.sizes.count != subviews.count {
            _ = sizeThatFits(
                proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews, cache: &cache)
        }
        var origin = bounds.origin
        for (view, size) in zip(subviews, cache.sizes) {
            view.place(
                at: origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: cache.vertical ? size.height : bounds.height))
            if cache.vertical { origin.y += size.height + gap } else { origin.x += size.width + gap }
        }
    }

    private func columnWidths(width: CGFloat, count: Int) -> [CGFloat] {
        let values = (0..<count).map { $0 < weights.count ? weights[$0] : 1 }
        let available = max(.zero, width - gap * CGFloat(max(0, count - 1)))
        let total = max(values.reduce(0, +), 1)
        return values.map { available * $0 / total }
    }
}
