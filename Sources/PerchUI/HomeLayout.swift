import Foundation
import PlannerCore

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

extension HomeLayout {
    public static let padding = CGFloat(DesignTokens.Size.sheetPadding.value)
    public static let gap = CGFloat(DesignTokens.Size.cardGap.value)
    public static let checklistWeight: CGFloat = 1.55
    public static let timeWeight: CGFloat = 0.9
    public static let dayWeight: CGFloat = 1.1
    public static let parkingHeight = CGFloat(
        DesignTokens.Size.addFieldHeight.value + 2 * DesignTokens.Size.cardPadding.value
            + 3 * DesignTokens.Size.sheetPadding.value)

    public struct Columns: Equatable, Sendable {
        public let checklist: CGFloat
        public let time: CGFloat
        public let day: CGFloat
    }

    /// Depends only on the sheet width, never timer/selection/draft state.
    public static func columns(sheetWidth: CGFloat) -> Columns {
        let unit = max(0, sheetWidth - 2 * padding - 2 * gap) / (checklistWeight + timeWeight + dayWeight)
        return Columns(checklist: unit * checklistWeight, time: unit * timeWeight, day: unit * dayWeight)
    }
}
