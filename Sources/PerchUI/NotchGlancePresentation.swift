import Foundation
import PlannerCore

/// A deliberately count-only glance: no task text enters the visible or accessible presentation.
public struct NotchGlancePresentation: Equatable, Sendable {
    public let count: Int
    public var text: String { "\(count > 999 ? "999+" : String(count)) \(count == 1 ? "task" : "tasks")" }
    public var accessibilityLabel: String {
        "\(count) unfinished \(count == 1 ? "task" : "tasks") today. Open Today"
    }

    public init?(planner: Planner, today: DayKey, expanded: Bool = false, activityVisible: Bool = false) {
        guard planner.preferences.notchTaskCount, !expanded, !activityVisible,
            planner.focus == nil || planner.focus?.state == .finished
        else { return nil }
        let count = planner.tasks.lazy.filter { $0.day == today && !$0.done }.count
        guard count > 0 else { return nil }
        self.count = count
    }
}
