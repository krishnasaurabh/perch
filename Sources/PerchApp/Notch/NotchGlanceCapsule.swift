import PerchUI
import SwiftUI

/// No title, icon or hover expansion. Activation uses the same explicit Today route as the menu.
struct NotchGlanceCapsule: View {
    let glance: NotchGlancePresentation
    var openToday: () -> Void

    var body: some View {
        Button(action: openToday) {
            Text(glance.text)
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Capsule(style: .continuous).fill(Theme.notchBlack))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(glance.accessibilityLabel)
        .accessibilityIdentifier("notch.taskCount")
        .help(glance.accessibilityLabel)
    }
}
