import PerchUI
import SwiftUI

/// A count, time, or state. Deliberately has no action, hover, or keyboard stop.
struct PerchPill: View {
    enum Size {
        case small, regular, large

        var height: CGFloat {
            switch self {
            case .small: DesignTokens.Size.pillMinHeight.value
            case .regular: DesignTokens.Size.minimumTarget.value
            case .large: DesignTokens.Size.pillMaxHeight.value
            }
        }
    }

    enum TextSize {
        case detail, standard
        var role: DesignTokens.TypeRole { self == .detail ? .detailStrong : .pill }
    }

    let title: String
    var surface: PerchSurface = .field
    var ink: DesignTokens.ColorToken = .ink2
    var size: Size = .small
    var textSize: TextSize = .detail
    var symbol: String? = nil

    init(
        _ title: String, surface: PerchSurface = .field, ink: DesignTokens.ColorToken = .ink2,
        size: Size = .small, textSize: TextSize = .detail, symbol: String? = nil
    ) {
        self.title = title
        self.surface = surface
        self.ink = ink
        self.size = size
        self.textSize = textSize
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: SurfaceMetrics.compactGap) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(AppL10n.text(title)).fixedSize(horizontal: false, vertical: true)
        }
        .perchFont(textSize.role)
        .padding(.horizontal, SurfaceMetrics.gap)
        .padding(.vertical, Theme.Size.focusGap.value)
        .frame(minHeight: size.height)
        .foregroundStyle(Theme.foreground(ink, on: surface))
        .background(Capsule().fill(Theme.fill(surface)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppL10n.text(title))
    }
}
