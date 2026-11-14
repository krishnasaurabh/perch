import Foundation
import PlannerCore

/// The closed indicators never carry task titles. Reminder state comes from the
/// presentation owner rather than a timestamp, so a waiting answer cannot time out.
public struct NotchClosedPresentation: Equatable, Sendable {
    public enum Line: Equatable, Sendable { case none, running, paused }
    public let focus: FocusSession?
    public let line: Line
    public let reminder: Bool
    public var hasBlock: Bool { focus != nil }
    public var isVisible: Bool { line != .none || reminder }

    public init(planner: Planner, reminderWaiting: Bool = false) {
        let current = planner.focus.flatMap { $0.state == .finished ? nil : $0 }
        focus = current
        if planner.preferences.notchProgressLine, let current,
            let limit = current.limit, limit.isFinite, limit > 0
        {
            line = current.state == .paused ? .paused : .running
        } else {
            line = .none
        }
        reminder = planner.preferences.notchReminderDot && reminderWaiting
    }

    /// A nil click count represents keyboard or accessibility activation.
    public static func allowsActivation(trigger: NotchOpenTrigger, clickCount: Int?) -> Bool {
        guard let clickCount else { return true }
        return trigger != .doubleClick || clickCount >= 2
    }

    public func fraction(at now: Date) -> Double {
        guard let focus, let limit = focus.limit, limit.isFinite, limit > 0,
            let remaining = focus.remaining(at: now), remaining.isFinite
        else { return 0 }
        return min(1, max(0, remaining / limit))
    }
}

/// A deliberately count-only glance: no task text enters the visible or accessible presentation.
public struct NotchGlancePresentation: Equatable, Sendable {
    public let count: Int
    public let locale: Locale
    public var text: String { PerchL10n.tasks(count: count, capped: true, locale: locale) }
    public var accessibilityLabel: String {
        PerchL10n.format("%lld unfinished tasks today. Open Today", locale: locale, count)
    }

    public init?(
        planner: Planner, today: DayKey, expanded: Bool = false, activityVisible: Bool = false,
        locale: Locale = .current
    ) {
        guard planner.preferences.notchTaskCount, !expanded, !activityVisible,
            planner.focus == nil || planner.focus?.state == .finished
        else { return nil }
        let count = planner.tasks.lazy.filter { $0.day == today && !$0.done }.count
        guard count > 0 else { return nil }
        self.count = count
        self.locale = locale
    }
}
