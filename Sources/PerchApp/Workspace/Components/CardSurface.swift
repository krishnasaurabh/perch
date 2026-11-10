import SwiftUI

// MARK: - Surfaces

/// A card's job decides its color: tasks are sage, time and charts lavender, everything else a dark tile.
enum CardTone {
    case tasks, timer, tile
    var fill: Color {
        switch self {
        case .tasks: return Theme.sage
        case .timer: return Theme.lavender
        case .tile: return Theme.tile
        }
    }
    /// Pastel cards carry dark ink, tiles white ink.
    var scheme: ColorScheme { self == .tile ? .dark : .light }
}

/// Padded, full-width, flat. Height follows the content; greedy content (a ScrollView, a Spacer) fills the slot.
struct CardSurface: ViewModifier {
    var tone: CardTone = .tile
    var padding: CGFloat = Theme.cardPadding
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(tone.fill))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
            .foregroundStyle(Theme.text)
            .environment(\.colorScheme, tone.scheme)
    }
}

extension View {
    func card(_ tone: CardTone = .tile, padding: CGFloat = Theme.cardPadding) -> some View {
        modifier(CardSurface(tone: tone, padding: padding))
    }
}
