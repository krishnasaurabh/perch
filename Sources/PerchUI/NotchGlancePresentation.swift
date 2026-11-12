import Foundation
import PlannerCore

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
