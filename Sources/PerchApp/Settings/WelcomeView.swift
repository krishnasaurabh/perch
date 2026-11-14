import PerchUI
import PlannerCore
import SwiftUI

/// First-run orientation is informational. Feature access is requested at first use.
struct WelcomeView: View {
    let done: () -> Void
    @EnvironmentObject var store: PlannerStore
    @Environment(\.dynamicTypeSize) private var textSize

    enum Metrics {
        static let padding = Theme.Size.minimumTarget.value
        static let gap = Theme.Size.switchHeight.value
        static let leftWidth = Theme.Size.peekWidth.value
        static let rightWidth = Theme.Size.stripMinWidth.value - Theme.Size.windowPadding.value * 3
        static let height = Theme.Size.stripMaxWidth.value - Theme.Size.windowPadding.value * 3
        static let smallGap = Theme.Size.segmentItemRadius.value
        static let textGap = Theme.Size.cardPadding.value - Theme.Size.windowPadding.value / 2
        static let sectionGap = Theme.Size.switchHeight.value / 2
        static let width = padding * 2 + leftWidth + rightWidth + gap
    }

    static var windowSize: CGSize { CGSize(width: Metrics.width, height: Metrics.height) }

    static func show(store: PlannerStore, done: @escaping () -> Void) {
        WindowHost.show("welcome", title: "Welcome to Perch", size: windowSize) {
            WelcomeView(done: done).environmentObject(store)
        }
    }

    static func complete(store: PlannerStore, openToday: Bool, done: () -> Void) {
        if !store.prefs.welcomeCompleted { store.apply { try $0.updatePreference(.welcomeCompleted(true)) } }
        guard store.prefs.welcomeCompleted else { return }
        if openToday {
            done()
        } else {
            WindowHost.windows["welcome"]?.close()
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                DotGridSheet(.window) {
                    HStack(alignment: .top, spacing: Metrics.gap) {
                        introduction
                            .frame(width: Metrics.leftWidth)
                        VStack(spacing: Metrics.sectionGap) {
                            WelcomeOpeningPreferences(store: store)
                            permissionReasons
                        }
                        .frame(width: Metrics.rightWidth)
                    }
                    .padding(Metrics.padding - Theme.Size.windowPadding.value)
                }
                .frame(minWidth: max(Metrics.width, geometry.size.width), minHeight: geometry.size.height)
            }
        }
        .onDisappear {
            if !store.prefs.welcomeCompleted { store.apply { try $0.updatePreference(.welcomeCompleted(true)) } }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionGap) {
            Text(AppL10n.text("Welcome to Perch"))
                .perchFont(.detailStrong).foregroundStyle(Theme.ink3)
            Text(AppL10n.text("A calmer way through a busy day"))
                .font(
                    Theme.font(
                        .stripTitle,
                        scaledSize: DesignTokens.TypeRole.currentTask.spec.scaledSize(for: textSize.tokenScale) * 2)
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(AppL10n.text("Perch sits in your Mac's notch. Three small habits do most of the work."))
                .perchFont(.body).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Metrics.smallGap) {
                habit(
                    "1", title: AppL10n.text("Write it down"),
                    detail: AppL10n.text("A checklist for today, with small steps inside each task."), surface: .paper)
                habit(
                    "2", title: AppL10n.text("Give it time"),
                    detail: AppL10n.text("Set a block aside for a task and watch the ring empty."), surface: .blush)
                habit(
                    "3", title: AppL10n.text("Park the rest"),
                    detail: AppL10n.text("Stray thoughts go in the parking lot, so they stop interrupting."),
                    surface: .apricot)
            }
            .padding(.top, Metrics.smallGap / 2)
            Spacer(minLength: Metrics.sectionGap)
            HStack(spacing: Metrics.textGap) {
                PerchButton("Start with three things", surface: .sheet) {
                    Self.complete(store: store, openToday: true, done: done)
                }
                .keyboardShortcut(.defaultAction)
                PerchButton("Look around first", kind: .quiet, surface: .sheet) {
                    Self.complete(store: store, openToday: false, done: done)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .frame(minHeight: Metrics.height - Metrics.padding * 2, alignment: .topLeading)
    }

    private func habit(_ number: String, title: String, detail: String, surface: PerchSurface) -> some View {
        HStack(spacing: Theme.Size.cardGap.value) {
            Text(number).perchFont(.button)
                .frame(width: Theme.Size.cardPadding.value * 2, height: Theme.Size.cardPadding.value * 2)
                .background(surface == .paper ? Theme.butter : Theme.paper, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: .zero) {
                Text(AppL10n.text(title)).perchFont(.currentTask)
                Text(AppL10n.text(detail)).perchFont(.detail).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Size.cardPadding.value)
        .padding(.vertical, Metrics.sectionGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill(surface), in: RoundedRectangle(cornerRadius: Theme.Size.cardPadding.value))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Size.cardPadding.value)
                .strokeBorder(Theme.edge(surface), lineWidth: Theme.Size.cardEdge.value)
                .allowsHitTesting(false)
        }
    }

    private var permissionReasons: some View {
        Card(.mint) {
            VStack(alignment: .leading, spacing: Metrics.textGap) {
                VStack(alignment: .leading, spacing: .zero) {
                    Text(AppL10n.text("Nothing to allow yet")).perchFont(.stripTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text(AppL10n.text("Perch asks only when you first use something."))
                        .perchFont(.detail).foregroundStyle(Theme.ink2)
                }
                VStack(spacing: Metrics.smallGap) {
                    permission(AppL10n.text("Calendar"), reason: AppL10n.text("To show your meetings in Your day"))
                    permission(
                        AppL10n.text("Notifications"), reason: AppL10n.text("For reminders when Perch is closed"))
                    permission(AppL10n.text("Microphone"), reason: AppL10n.text("Only if you choose to dictate"))
                }
                Spacer(minLength: Metrics.smallGap)
                Text(AppL10n.text("Your tasks stay on this Mac."))
                    .perchFont(.detail).foregroundStyle(Theme.ink2)
            }
            .frame(
                minHeight: Metrics.height - Metrics.padding * 2 - openingHeight - Metrics.sectionGap
                    - Theme.Size.cardPadding.value * 2, alignment: .topLeading
            )
            .padding(.horizontal, Theme.Size.focusGap.value)
        }
    }

    private var openingHeight: CGFloat { WelcomeOpeningPreferences.minimumHeight }

    private func permission(_ title: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: .zero) {
            Text(AppL10n.text(title)).perchFont(.button)
            Text(AppL10n.text(reason)).perchFont(.detail).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Metrics.smallGap)
        .padding(.horizontal, Metrics.sectionGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Metrics.sectionGap))
    }
}

/// Two independent, persisted choices. Reading the hover choice never rewrites Everything.
struct WelcomeOpeningPreferences: View {
    @ObservedObject var store: PlannerStore
    @State private var shortcut = ShortcutStore.load().display

    static var minimumHeight: CGFloat {
        Theme.Size.cardPadding.value * 2 + Theme.Size.buttonHeight.value * 3
            + Theme.Size.pillMinHeight.value + Theme.Size.segmentItemRadius.value * 3 + Theme.Size.cardEdge.value * 2
    }

    var clickEnabled: Binding<Bool> {
        Binding(
            get: { store.prefs.notchClickToOpen },
            set: { enabled in store.apply { try $0.updatePreference(.notchClickToOpen(enabled)) } })
    }

    var hoverEnabled: Binding<Bool> {
        Binding(
            get: { [.hover, .everything].contains(store.prefs.notchOpenTrigger) },
            set: { enabled in store.apply { try $0.updatePreference(.notchOpenTrigger(enabled ? .hover : .nothing)) } })
    }

    var body: some View {
        Card(.paper) {
            VStack(alignment: .leading, spacing: Theme.Size.segmentItemRadius.value / 2) {
                Text(AppL10n.text("Open it your way")).perchFont(.stripTitle)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: Theme.Size.segmentRadius.value) {
                    Text(shortcut).perchFont(.button)
                        .padding(.horizontal, Theme.Size.segmentRadius.value)
                        .padding(.vertical, Theme.Size.segmentItemRadius.value / 2)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.Size.segmentItemRadius.value))
                    Text(AppL10n.text("from anywhere, ready to type")).perchFont(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: Theme.Size.buttonHeight.value)
                separator
                openingRow(AppL10n.text("Click the notch for everything"), value: clickEnabled)
                separator
                openingRow(AppL10n.text("Hover for a quick peek"), value: hoverEnabled)
            }
            .frame(minHeight: Self.minimumHeight - Theme.Size.cardPadding.value * 2, alignment: .topLeading)
            .padding(.horizontal, Theme.Size.focusGap.value)
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.didChange)) { _ in
            shortcut = ShortcutStore.load().display
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.didFail)) { _ in
            shortcut = ShortcutStore.load().display
        }
    }

    private var separator: some View {
        Rectangle().fill(Theme.edge(.paper)).frame(height: Theme.Size.cardEdge.value)
            .accessibilityHidden(true)
    }

    private func openingRow(_ title: String, value: Binding<Bool>) -> some View {
        HStack(spacing: Theme.Size.segmentRadius.value) {
            Text(AppL10n.text(title)).perchFont(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Spacer(minLength: .zero)
            PerchSwitch(title: title, isOn: value)
        }
        .frame(minHeight: Theme.Size.buttonHeight.value)
    }
}
