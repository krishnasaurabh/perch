import Foundation
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
    var locale: Locale? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection

    /// macOS does not scale system caption fonts for an injected Dynamic Type size.
    /// Apply the requested size explicitly, including accessibility categories.
    static func pointSize(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 9
        case .small: 10
        case .medium, .large: 11
        case .xLarge: 13
        case .xxLarge: 15
        case .xxxLarge: 17
        case .accessibility1: 20
        case .accessibility2: 23
        case .accessibility3: 26
        case .accessibility4: 29
        case .accessibility5: 32
        @unknown default: 11
        }
    }

    struct LayoutMetrics: Equatable, Sendable {
        let pointSize: CGFloat
        let isRightToLeft: Bool
    }

    struct LayoutMetricsKey: PreferenceKey {
        static var defaultValue: LayoutMetrics? { nil }
        static func reduce(value: inout LayoutMetrics?, nextValue: () -> LayoutMetrics?) {
            value = nextValue() ?? value
        }
    }

    var body: some View {
        Label(AppL10n.text(title, locale: locale), systemImage: tone.symbol)
            .font(.system(size: Self.pointSize(for: dynamicTypeSize), weight: .medium))
            .foregroundStyle(tone.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppL10n.text(title, locale: locale))
            .preference(
                key: LayoutMetricsKey.self,
                value: LayoutMetrics(
                    pointSize: Self.pointSize(for: dynamicTypeSize), isRightToLeft: layoutDirection == .rightToLeft))
    }
}
