import SwiftUI

/// Observe the service itself so a remote-only error is visible without a planner mutation.
struct ReminderSyncStatus: View {
    @ObservedObject var sync: RemindersSync
    var body: some View {
        if let error = sync.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
