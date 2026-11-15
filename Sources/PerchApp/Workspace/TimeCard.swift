import Foundation
import PlannerCore
import PerchUI
import SwiftUI

/// A read-only projection of the existing focus engine. It owns no clock or timer state.
struct TimeCardPresentation {
    enum State: Hashable { case empty, ready, running, paused }
    let state: State
    let task: PlanTask?
    let start: Date?
    let end: Date?
    let minutes: Int
    let seconds: Double
    let fraction: Double
    let canExtend: Bool

    init(planner: Planner, day: DayKey, now: Date) {
        if let focus = planner.focus, focus.state != .finished {
            let paused = focus.state == .paused
            let remaining = focus.remaining(at: now) ?? focus.elapsed(at: now)
            state = paused ? .paused : .running
            task = planner.tasks.first { $0.id == focus.taskID }
            start = focus.startedAt
            seconds = remaining
            minutes = Int(((focus.limit ?? 0) / 60).rounded(.up))
            fraction = focus.limit.map { $0 > 0 ? min(1, max(0, remaining / $0)) : 0 } ?? 1
            canExtend = focus.limit != nil
            let pausedAt =
                planner.focusSegments.last(where: { $0.taskID == focus.taskID && $0.start >= focus.startedAt })?.end
                ?? focus.startedAt.addingTimeInterval(focus.banked)
            end = focus.limit.map { _ in (paused ? pausedAt : now).addingTimeInterval(remaining) }
        } else {
            let next = planner.tasks.filter { $0.day == day && !$0.done && ($0.startAt.map { $0 >= now } ?? false) }
                .min { $0.startAt! < $1.startAt! }
            let length =
                next?.minutes ?? (next == nil ? Self.suggestedMinutes : planner.preferences.defaultFocusMinutes)
            task = next
            state = next == nil ? .empty : .ready
            start = next?.startAt
            minutes = length
            seconds = Double(length * 60)
            end = next?.startAt?.addingTimeInterval(Double(length * 60))
            fraction = 1
            canExtend = false
        }
    }

    static let suggestedMinutes = 25

    /// Refresh only this display, never the engine. Scheduled idle cards need minute
    /// updates too; paused cards and days with no scheduled blocks stay asleep.
    static func refreshInterval(planner: Planner, day: DayKey) -> TimeInterval? {
        if let focus = planner.focus, focus.state != .finished {
            return focus.state == .running ? 1 : nil
        }
        return planner.tasks.contains { $0.day == day && !$0.done && $0.startAt != nil } ? 60 : nil
    }

    var active: Bool { state == .running || state == .paused }
    var digits: String { active ? TimerText.clock(seconds) : String(minutes) }
    var completedSteps: Int { task?.steps.filter(\.done).count ?? 0 }
    var totalSteps: Int { task?.steps.count ?? 0 }
    var primaryTitle: String {
        switch state {
        case .empty: return AppL10n.text("Set time aside")
        case .ready: return AppL10n.text("Start it now")
        case .running: return AppL10n.text("Pause")
        case .paused: return AppL10n.text("Continue")
        }
    }
    var heading: String {
        switch state {
        case .empty: return AppL10n.text("No time set aside yet")
        case .ready: return AppL10n.text("Nothing running")
        case .running, .paused: return AppL10n.text("Time set aside")
        }
    }
    var ringCaption: String {
        if active { return canExtend ? AppL10n.text("left") : AppL10n.text("elapsed") }
        return state == .empty ? AppL10n.text("min is plenty") : AppL10n.text("min set aside")
    }
    var ringLabel: String {
        guard active else {
            return state == .empty
                ? AppL10n.format("%lld min is plenty", minutes)
                : AppL10n.format("%lld minutes set aside", minutes)
        }
        let totalSeconds = Int(max(0, seconds).rounded(.up))
        if !canExtend {
            return AppL10n.format("%lld minutes %lld seconds elapsed", totalSeconds / 60, totalSeconds % 60)
        }
        if totalSeconds % 60 == 0 {
            return AppL10n.format("%lld minutes left of %lld", totalSeconds / 60, minutes)
        }
        return AppL10n.format("%lld minutes %lld seconds left of %lld", totalSeconds / 60, totalSeconds % 60, minutes)
    }
}

/// Long checklists share a bounded strip while the adjacent label keeps the exact count.
struct TimeCardStepProgress {
    static let maximumPips = 4
    let fractions: [Double]
    let stacked: Bool

    init(completed: Int, total: Int) {
        let total = max(0, total)
        let count = min(total, Self.maximumPips)
        let progress = total > 0 ? Double(min(total, max(0, completed))) / Double(total) : 0
        fractions = (0..<count).map { min(1, max(0, progress * Double(count) - Double($0))) }
        stacked = total > Self.maximumPips
    }
}

/// The time-left arc shares the engine's remaining fraction; it never advances time.
struct TimeRing: View {
    let fraction: Double
    var dashed = false
    var paused = false

    var body: some View {
        ZStack {
            Circle().inset(by: TimeCardMetrics.ringInset)
                .stroke(
                    dashed ? Theme.ink2 : Theme.edge(.blush),
                    style: StrokeStyle(
                        lineWidth: TimeCardMetrics.ringStroke,
                        dash: dashed ? [TimeCardMetrics.dash, TimeCardMetrics.dashGap] : []))
            if !dashed {
                Circle().inset(by: TimeCardMetrics.ringInset)
                    .trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(
                        paused ? Theme.ink2 : Theme.brandFill,
                        style: StrokeStyle(lineWidth: TimeCardMetrics.ringStroke, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .designMotion(.time, value: fraction)
                    .designMotion(.hover, value: paused)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Component metrics derive from the shared foundation scale.
enum TimeCardMetrics {
    static let gap = DesignTokens.Size.segmentItemRadius.value
    static let smallGap = DesignTokens.Size.stepCheckboxRadius.value
    static let pipGap = DesignTokens.Size.checkboxStroke.value * 2
    static let ringDiameter = DesignTokens.Size.cardPadding.value * 8
    static let ringInset = DesignTokens.Size.segmentRadius.value
    static let ringStroke = DesignTokens.TypeRole.detail.spec.size
    static let dash = DesignTokens.Size.stepCheckboxRadius.value / 2
    static let dashGap = DesignTokens.Size.stepCheckboxRadius.value + dash
    static let pipWidth = DesignTokens.Size.sheetPadding.value
    static let pipHeight = DesignTokens.Size.stepCheckboxRadius.value
}

struct TimeCard: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(TodayHomeState.self) private var home
    @Environment(\.motionPolicy) private var motionPolicy

    var body: some View {
        let interval = TimeCardPresentation.refreshInterval(planner: store.planner, day: store.today)
        LocalClock(running: interval != nil, interval: interval ?? 1) { now in
            let presentation = TimeCardPresentation(planner: store.planner, day: store.today, now: now)
            Card(.blush) {
                VStack(spacing: TimeCardMetrics.gap) {
                    header(presentation)
                    ring(presentation)
                    detail(presentation)
                    Spacer(minLength: .zero)
                    controls(presentation)
                }
            }
        }
    }

    private func header(_ value: TimeCardPresentation) -> some View {
        VStack(alignment: .leading, spacing: .zero) {
            Text(AppL10n.text(value.heading)).perchFont(.detailStrong).foregroundStyle(Theme.ink2)
            if value.active, let start = value.start, let end = value.end {
                Text(AppL10n.format("%@ – %@", time(start), time(end))).perchFont(.stripTitle)
            } else if value.active, let start = value.start {
                Text(AppL10n.format("Since %@", time(start))).perchFont(.stripTitle)
            } else if let start = value.start {
                Text(AppL10n.format("Next block at %@", time(start))).perchFont(.stripTitle)
            } else {
                Text("Give one task a block").perchFont(.stripTitle)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ring(_ value: TimeCardPresentation) -> some View {
        ZStack {
            TimeRing(fraction: value.fraction, dashed: !value.active, paused: value.state == .paused)
            VStack(spacing: .zero) {
                Text(value.digits).perchFont(.timer).monospacedDigit()
                    .foregroundStyle(value.state == .paused ? Theme.ink2 : Theme.ink)
                Text(AppL10n.text(value.ringCaption)).perchFont(.detail).foregroundStyle(Theme.ink2)
            }
        }
        .frame(width: TimeCardMetrics.ringDiameter, height: TimeCardMetrics.ringDiameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.ringLabel)
        .accessibilityIdentifier("time-card-ring")
    }

    @ViewBuilder private func detail(_ value: TimeCardPresentation) -> some View {
        if value.active && value.totalSteps > 0 {
            let progress = TimeCardStepProgress(completed: value.completedSteps, total: value.totalSteps)
            let layout =
                progress.stacked
                ? AnyLayout(VStackLayout(spacing: TimeCardMetrics.smallGap))
                : AnyLayout(HStackLayout(spacing: TimeCardMetrics.smallGap))
            layout {
                HStack(spacing: TimeCardMetrics.pipGap) {
                    ForEach(progress.fractions.indices, id: \.self) { index in
                        Capsule().fill(Theme.edge(.blush))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Theme.doneFill)
                                    .frame(width: TimeCardMetrics.pipWidth * progress.fractions[index])
                            }
                            .frame(width: TimeCardMetrics.pipWidth, height: TimeCardMetrics.pipHeight)
                            .designMotion(.tickFill, value: value.completedSteps)
                    }
                }.accessibilityHidden(true)
                Text(AppL10n.format("%lld of %lld steps", value.completedSteps, value.totalSteps))
                    .perchFont(.detail).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !value.active, let task = value.task {
            Text(task.title).perchFont(.button).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else if value.state == .empty {
            Text("Even a short block makes it easier to start.").perchFont(.detail)
                .foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func controls(_ value: TimeCardPresentation) -> some View {
        HStack(spacing: TimeCardMetrics.smallGap) {
            PerchButton(kind: value.state == .empty ? .soft : .main, surface: .blush, action: { activate(value) }) {
                HStack(spacing: TimeCardMetrics.smallGap) {
                    if value.state == .running || value.state == .ready {
                        Image(systemName: value.state == .running ? "pause.fill" : "play.fill").perchFont(.detail)
                    }
                    Text(AppL10n.text(value.primaryTitle))
                }
                .frame(maxWidth: .infinity)
                .id(value.state)
                .transition(
                    motionPolicy.reduceMotion
                        ? .identity
                        : .opacity.combined(with: .scale(scale: DesignTokens.Motion.pressScale)).combined(
                            with: .move(edge: .bottom)))
            }
            .designMotion(.pop, value: value.state)
            .accessibilityIdentifier("time-card-primary")
            if value.canExtend {
                PerchButton("+5 min", kind: .soft, surface: .blush) { store.send(.extendTimer(5)) }
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("time-card-add-five")
            }
        }
    }

    private func activate(_ value: TimeCardPresentation) {
        switch value.state {
        case .running: store.send(.pauseTimer)
        case .paused: store.send(.resumeTimer)
        case .ready: store.send(.startTimer(value.task?.id, minutes: nil))
        case .empty:
            let selected = store.planner.tasks.first {
                $0.id == home.selectedTaskID && !$0.done && $0.day == store.today
            }
            store.send(.startTimer(selected?.id, minutes: TimeCardPresentation.suggestedMinutes))
        }
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = store.engine.calendar
        formatter.timeZone = store.engine.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("HHmm")
        return formatter.string(from: date)
    }
}
