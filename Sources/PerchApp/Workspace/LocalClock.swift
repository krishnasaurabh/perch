import SwiftUI

/// Only this subtree invalidates for clock display updates. Paused/hidden clocks have no timer.
struct LocalClock<Content: View>: View {
    var running: Bool
    var interval: TimeInterval = 1
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        if let date = PreviewClock.date {
            content(date)
        } else if running {
            TimelineView(.periodic(from: .now, by: interval)) { context in content(context.date) }
        } else {
            content(Date())
        }
    }
}
