import Foundation
import PlannerCore

/// A short-lived thing the closed notch shows: a reminder nudge, a finished timer, a caught clip.
struct PresentedNotchActivity: Identifiable, Equatable {
    enum Kind: Equatable { case reminder(UUID), focusDone(UUID?), eventSoon(String), clip(URL), message }
    let id = UUID()
    var kind: Kind
    var title: String
    var subtitle: String
}

@MainActor
extension NotchModel {
    /// A rejected mutation leaves the reminder and its actions available for retry.
    @discardableResult
    func performActivityAction<T>(in store: PlannerStore, _ action: (PlannerCommands) throws -> T) -> Bool {
        guard store.apply(action) != nil else { return false }
        dismissActivity()
        return true
    }
}
