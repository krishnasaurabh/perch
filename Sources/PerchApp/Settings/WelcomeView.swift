import SwiftUI

/// First run: what it is, the one shortcut, and optional permissions. Every permission is optional.
struct WelcomeView: View {
    let done: () -> Void
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var services: Services
    @State private var granted: Set<String> = []
    @State private var shortcut = ShortcutStore.load().display

    var body: some View {
        VStack(spacing: 18) {
            OwlMark(size: 64).padding(.top, 34)
            Text("Your plan lives in the notch now.").font(.system(size: 22, weight: .bold))
            Text(
                "Hover over the notch, or press \(shortcut). Type or say what's on your mind and it becomes a sorted task."
            )
            .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(width: 400)
            .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.didChange)) { _ in
                shortcut = ShortcutStore.load().display
            }
            .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.didFail)) { _ in
                shortcut = ShortcutStore.load().display
            }
            VStack(spacing: 8) {
                row("calendar", "Calendar", "Shows today's events next to your list. Perch never edits them.", "cal") {
                    await services.calendar.requestAccess()
                }
                row("bell", "Notifications", "A heads-up when a reminder fires or a timer ends.", "notif") {
                    await services.reminders.requestAuthorization()
                }
                row("mic", "Voice", "Dictate tasks. Speech is processed on this Mac.", "mic") {
                    _ = await withCheckedContinuation { c in
                        SFSpeechRecognizerBridge.request { c.resume(returning: $0) }
                    }
                }
                row("iphone", "Reminders sync", "Mirror your list to iPhone and Apple Watch.", "rem") {
                    if await services.remindersSync.requestAccess() { store.updatePrefs { $0.remindersSync = true } }
                }
            }
            .frame(width: 440)
            Text("Skip any permission for now. You can enable it later in Settings.").font(.caption).foregroundStyle(
                .secondary)
            Button("Open my workspace", action: done).keyboardShortcut(.defaultAction).controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    func row(_ symbol: String, _ title: String, _ detail: String, _ key: String, _ action: @escaping () async -> Void)
        -> some View
    {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted.contains(key) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow") {
                    Task {
                        await action(); granted.insert(key)
                    }
                }
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}
