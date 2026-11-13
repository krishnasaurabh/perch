import SwiftUI

/// Permissions are optional. Only the system's queried state can mark one allowed.
struct WelcomeView: View {
    let done: () -> Void
    @EnvironmentObject var store: PlannerStore
    @EnvironmentObject var services: Services
    @State private var shortcut = ShortcutStore.load().display

    var body: some View {
        VStack(spacing: Theme.cardPadding) {
            ScrollView {
                VStack(spacing: Theme.cardPadding) {
                    OwlMark(size: 56).padding(.top, Theme.cardPadding)
                    Text("Your plan, close at hand.").font(Theme.heading)
                    Text(
                        "Open the notch or press \(shortcut) to type a task. Voice entry and connected features need the optional access below."
                    )
                    .font(Theme.body).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    PermissionPanel(services: services)
                        .padding(Theme.cardPadding)
                        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.fill))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.cardStroke))
                    WelcomeScreenshotConsent(store: store)
                        .padding(Theme.cardPadding)
                        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.fill))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.cardStroke))
                }
                .frame(maxWidth: 460)
                .padding(Theme.cardPadding)
                .frame(maxWidth: .infinity)
            }
            Text("Skip any permission. You can review it later in Settings.")
                .font(Theme.meta).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button("Open workspace", action: done)
                .buttonStyle(PillStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, Theme.cardPadding)
        }
        .foregroundStyle(Theme.text)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.controlSurface, Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.didChange)) { _ in
            shortcut = ShortcutStore.load().display
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.didFail)) { _ in
            shortcut = ShortcutStore.load().display
        }
    }
}

/// Screenshot import is a separate choice, not a system permission or a Welcome completion effect.
struct WelcomeScreenshotConsent: View {
    @ObservedObject var store: PlannerStore

    static let title = "Add new screenshots to Clips"
    static let explanation =
        "While enabled, Perch watches for newly saved screenshots and screen recordings and adds them to Clips. It does not take screenshots."
    static let settingsHint = "Change this anytime in Settings > Workspace > Clips."

    var isEnabled: Binding<Bool> {
        Binding(
            get: { store.prefs.catchScreenshots },
            set: { enabled in store.updatePrefs { $0.catchScreenshots = enabled } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.cardPadding) {
            Toggle(isOn: isEnabled) { Text(verbatim: Self.title) }
                .toggleStyle(.checkbox)
            Text(verbatim: Self.explanation)
                .font(Theme.body).foregroundStyle(Theme.secondary)
            Text(verbatim: Self.settingsHint)
                .font(Theme.meta).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
