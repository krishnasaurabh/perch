import Foundation
import PerchUI
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
    @Environment(\.designSurface) private var surface

    /// macOS does not scale system caption fonts for an injected Dynamic Type size.
    /// Apply the requested size explicitly, including accessibility categories.
    static func pointSize(for size: DynamicTypeSize) -> CGFloat {
        let scale: DesignTokens.TextScale
        switch size {
        case .xSmall: scale = .xSmall
        case .small: scale = .small
        case .medium: scale = .medium
        case .large: scale = .large
        case .xLarge: scale = .xLarge
        case .xxLarge: scale = .xxLarge
        case .xxxLarge: scale = .xxxLarge
        case .accessibility1: scale = .accessibility1
        case .accessibility2: scale = .accessibility2
        case .accessibility3: scale = .accessibility3
        case .accessibility4: scale = .accessibility4
        case .accessibility5: scale = .accessibility5
        @unknown default: scale = .large
        }
        return DesignTokens.TypeRole.detail.spec.scaledSize(for: scale)
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

    @ViewBuilder private var label: some View {
        let weight = DesignTokens.TypeRole.detail.spec.weight.swiftUI
        if surface != nil {
            Label(AppL10n.text(title, locale: locale), systemImage: tone.symbol).perchFont(.detail)
        } else {
            Label(AppL10n.text(title, locale: locale), systemImage: tone.symbol)
                .font(.system(size: Self.pointSize(for: dynamicTypeSize), weight: weight))
        }
    }

    private var color: Color {
        guard let surface else { return tone.color }
        let token: DesignTokens.ColorToken
        switch tone {
        case .success: token = .doneText
        case .warning: token = .carried
        case .danger: token = .brandText
        case .info: token = .ink2
        }
        return Theme.foreground(token, on: surface)
    }

    var body: some View {
        label
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppL10n.text(title, locale: locale))
            .preference(
                key: LayoutMetricsKey.self,
                value: LayoutMetrics(
                    pointSize: Self.pointSize(for: dynamicTypeSize), isRightToLeft: layoutDirection == .rightToLeft))
    }
}
