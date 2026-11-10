import Foundation

/// What the Today page shows (design tenet 1: a clean first screen).
/// Today's tasks and the capture field are always there. The side column holds only what matters right now:
/// the focus timer while one runs, today's agenda when there are events, and the notepad if the user turned it on.
/// Insights is never a card on Today; it has its own tab.
public enum HomeLayout {
    /// Card ids the user may show, hide or reorder in Settings. "tasks" is fixed; "insights" is a tab, not a card.
    public static let customizable = ["focus", "events", "notepad"]

    /// The customizable cards in the user's order. Ids missing from an older saved order follow the placed ones;
    /// unknown ids, duplicates, "tasks" and "insights" are dropped.
    public static func ordered(_ order: [String]) -> [String] {
        var seen = Set<String>()
        return (order + customizable).filter { customizable.contains($0) && seen.insert($0).inserted }
    }

    /// The side-column cards to draw, in the user's order.
    public static func sideCards(order: [String], hidden: [String], timerActive: Bool, hasEvents: Bool) -> [String] {
        ordered(order).filter { id in
            guard !hidden.contains(id) else { return false }
            switch id {
            case "focus": return timerActive
            case "events": return hasEvents
            default: return true
            }
        }
    }

    public static func sideCards(_ prefs: Preferences, timerActive: Bool, hasEvents: Bool) -> [String] {
        sideCards(
            order: prefs.workspaceCardOrder, hidden: prefs.hiddenWorkspaceCards, timerActive: timerActive,
            hasEvents: hasEvents)
    }
}
