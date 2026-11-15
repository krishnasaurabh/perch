import Foundation
import PerchUI
import PlannerCore

/// A short-lived thing the closed notch shows: a reminder nudge, a finished timer, a caught clip.
struct PresentedNotchActivity: Identifiable, Equatable {
    enum Kind: Equatable {
        case reminder(UUID), focusDone(UUID?), eventSoon(String), clip(URL), message, strip(
            NotchStripQueue.Kind, String)
    }
    var id = UUID()
    var kind: Kind
    var title: String
    var subtitle: String
    var stripID: String?
    var taskID: UUID?
    var titles: [String] = []
    var thoughtIDs: [UUID] = []
    var affectedTaskIDs: [UUID] = []

    var stripKind: NotchStripQueue.Kind {
        switch kind {
        case .strip(let kind, _): return kind
        case .reminder: return .reminder
        case .focusDone: return .blockEnded
        case .eventSoon: return .headsUp
        case .clip: return .dropShelf
        case .message: return .agentChange
        }
    }
}

@MainActor
extension NotchModel {
    /// A rejected mutation leaves the reminder and its actions available for retry.
    @discardableResult
    func performActivityAction<T>(in store: PlannerStore, _ action: (PlannerCommands) throws -> T) -> Bool {
        let before = store.planner
        guard store.apply(action) != nil else { return false }
        dismissPresentedActivity(in: before)
        return true
    }
}
