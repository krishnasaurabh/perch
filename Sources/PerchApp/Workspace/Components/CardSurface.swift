import SwiftUI

// MARK: - Surfaces

/// A card's job decides its color: tasks are sage, time and charts lavender, everything else a dark tile.
@MainActor enum CardTone: Sendable {
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
                    .strokeBorder(Theme.cardStroke, lineWidth: Theme.focusWidth / 2)
            )
            .foregroundStyle(Theme.text)
            .environment(\.colorScheme, tone.scheme)
            .environment(\.controlSurface, tone.fill)
            .environment(\.designSurface, nil)
    }
}

extension View {
    func card(_ tone: CardTone = .tile, padding: CGFloat = Theme.cardPadding) -> some View {
        modifier(CardSurface(tone: tone, padding: padding))
    }

    func card(surface: PerchSurface, kind: CardKind = .standard) -> some View {
        Card(surface, kind: kind) { self }
    }
}

enum CardKind {
    case standard, currentTask
}

/// A flat, appearance-aware card. Legacy fixed-tone callers above remain unchanged.
struct Card<Content: View>: View {
    let surface: PerchSurface
    let kind: CardKind
    private let content: Content

    init(
        _ surface: PerchSurface = .paper, kind: CardKind = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.surface = surface
        self.kind = kind
        self.content = content()
    }

    var cornerRadius: CGFloat {
        kind == .currentTask ? Theme.Size.currentTaskRadius.value : Theme.Size.cardRadius.value
    }

    var body: some View {
        content
            .padding(Theme.Size.cardPadding.value)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Theme.fill(surface)))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.edge(surface), lineWidth: Theme.Size.cardEdge.value)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
            .foregroundStyle(Theme.foreground(.ink, on: surface))
            .environment(\.controlSurface, Theme.fill(surface))
            .environment(\.designSurface, surface)
    }
}
