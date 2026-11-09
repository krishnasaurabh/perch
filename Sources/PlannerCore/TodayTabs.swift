import Foundation

/// The filter pills in the Today card's header.
public enum TodayTab: String, CaseIterable, Sendable {
    case active, completed
}

/// Which Today filter pills to draw, and which one is really selected (review F05, tenets 1 and 5).
/// "Completed" only appears once something is done today, so a first-time user never sees "Completed 0".
/// Once a task is finished, the pill comes back and finished tasks stay one click away.
public enum TodayTabs {
    public static func visible(completedCount: Int) -> [TodayTab] {
        completedCount > 0 ? [.active, .completed] : [.active]
    }

    /// The tab to show. A selection whose pill is hidden (Completed with nothing done, e.g. after reopening the
    /// only finished task) falls back to To do.
    public static func resolved(_ selected: TodayTab, completedCount: Int) -> TodayTab {
        visible(completedCount: completedCount).contains(selected) ? selected : .active
    }
}
