import Foundation

/// A short-lived thing the closed notch shows: a reminder nudge, a finished timer, a caught clip.
struct PresentedNotchActivity: Identifiable, Equatable {
    enum Kind: Equatable { case reminder(UUID), focusDone(UUID?), eventSoon(String), clip(URL), message }
    let id = UUID()
    var kind: Kind
    var title: String
    var subtitle: String
}
