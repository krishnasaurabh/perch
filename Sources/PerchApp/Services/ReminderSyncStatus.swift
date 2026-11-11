import SwiftUI

/// Observe the service itself so a remote-only error is visible without a planner mutation.
struct ReminderSyncStatus: View {
    @ObservedObject var sync: RemindersSync
    @State private var confirmingTwoWay = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sync.twoWayEnabled {
                Text("Experimental two-way sync is enabled.").font(.caption)
                Button("Return to one-way mirroring") { sync.setTwoWayEnabled(false) }
            } else {
                Button("Enable experimental two-way sync…") { confirmingTwoWay = true }
                    .disabled(!sync.store.prefs.remindersSync || !sync.hasAccess)
            }
            Text(
                "Two-way sync keeps linked tasks after day rollover. Completion and reopening still require today; historical edits, unsupported alarms and recurrence stop sync. Deleted identities are never recreated automatically."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let error = sync.lastError {
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Enable two-way sync for the Perch list?", isPresented: $confirmingTwoWay) {
            Button("Cancel", role: .cancel) {}
            Button("Enable two-way sync", role: .destructive) { sync.setTwoWayEnabled(true) }
        } message: {
            Text(
                "Edits and deletions of linked tasks can change both Perch and its Reminders list. Unrelated reminders are ignored. This is experimental; keep a backup. Conflicts stop sync. Real-account and cross-device behavior is not yet verified."
            )
        }
    }
}
