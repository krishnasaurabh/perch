import SwiftUI

/// A status is always a named state plus a symbol; hue is supplementary.
struct StatusLabel: View {
    enum Tone: Sendable {
        case success, warning, danger, info

        @MainActor var color: Color {
            switch self {
            case .success: return Theme.success
            case .warning: return Theme.warning
            case .danger: return Theme.danger
            case .info: return Theme.info
            }
        }

        var symbol: String {
            switch self {
            case .success: return "checkmark.circle"
            case .warning: return "exclamationmark.triangle"
            case .danger: return "exclamationmark.circle"
            case .info: return "info.circle"
            }
        }
    }

    let title: String
    let tone: Tone

    var body: some View {
        Label(AppL10n.text(title), systemImage: tone.symbol)
            .font(Theme.meta)
            .foregroundStyle(tone.color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppL10n.text(title))
    }
}
