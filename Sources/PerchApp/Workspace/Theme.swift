import PlannerCore
import SwiftUI

// MARK: - Color tokens

/// Perch uses a black shell and opaque pastel cards with dark ink,
/// white only on black, one warm accent, and no shadows. Functional boundaries use quiet, accessible strokes.
///
/// Ink tokens are two-faced. They resolve against the SwiftUI `colorScheme` of the subtree that draws them:
/// `.dark` means "on the black shell or a dark tile" (white ink, orange accent), `.light` means "on a pastel card"
/// (near-black ink, monochrome accent). `CardSurface` sets the scheme from its `CardTone`, so a view inside a card
/// picks the right ink without knowing where it sits.
///
/// WCAG contrast against the measured surfaces (sage / lavender / black):
/// text 6.3 / 5.8 / 17.6, secondary 5.0 / 4.7 / 7.8, tertiary 4.0 / 3.7 / 4.4 (hints and finished rows only).
enum Theme {
    /// The camera housing and the expanded shell. Black in every state.
    static let notchBlack = Color.black

    // Surfaces: opaque, flat on the shell.
    /// Task card fill: `#879E8D`.
    static let sage = Color(hex: "#879E8D")
    /// Timer, agenda and chart card fill: `#938EAB`.
    static let lavender = Color(hex: "#938EAB")
    /// Dark tile for white ink (week columns, clips, banners): `#1D1D1D`.
    static let tile = Color(hex: "#1D1D1D")
    /// Highlighted dark tile (today's week column): `#303030`.
    static let tileStrong = Color(hex: "#303030")
    static let card = tile
    /// Functional card edges: >=3:1 against the pastel/card surface; fills stay unchanged.
    static let cardStroke = Color.dynamic(light: (0x2F3D33, 1), dark: (0x858585, 1))
    /// Capture edge remains visible in resting and focused states without darkening its fill.
    static let inputStroke = Color.dynamic(light: (0x29352D, 1), dark: (0x999999, 1))
    /// The clothesline is a boundary, not secondary text with another opacity applied.
    static let rope = Color.dynamic(light: (0x2F3D33, 1), dark: (0x858585, 1))

    static let text = Color.dynamic(light: (0x000000, 0.90), dark: (0xFFFFFF, 0.92))
    static let secondary = Color.dynamic(light: (0x000000, 0.74), dark: (0xFFFFFF, 0.62))
    static let tertiary = Color.dynamic(light: (0x000000, 0.62), dark: (0xFFFFFF, 0.45))

    /// Warm accent on dark surfaces (`#F19644`); dark ink on pastel cards.
    static let accent = Color.dynamic(light: (0x1A1E20, 1), dark: (0xF19644, 1))
    /// The mascot keeps its color on any surface.
    static let owl = Color(hex: "#F19644")
    /// Label on a prominent fill.
    static let onAccent = Color.dynamic(light: (0xFFFFFF, 1), dark: (0x1A1A1A, 1))
    /// Prominent button fill: `#6C687E` on lavender (black 30 % over the card), the accent on black.
    static let prominent = Color.dynamic(light: (0x000000, 0.30), dark: (0xF19644, 1))
    static let done = Color.dynamic(light: (0x17401F, 1), dark: (0x7AD98F, 1))
    static let danger = Color.dynamic(light: (0x5C110B, 1), dark: (0xFF6B6B, 1))
    /// Restrained green-grey priority marker, separate from destructive/overdue red.
    static let priorityHigh = Color.dynamic(light: (0x273D2E, 1), dark: (0xB9C6BA, 1))

    /// Quiet control fill for segment tracks and icon buttons: white 12.5 % on black.
    static let fill = Color.dynamic(light: (0xFFFFFF, 0.20), dark: (0xFFFFFF, 0.125))
    /// Hovered control. Selection has its own opaque token to avoid stacked translucency.
    static let fillStrong = Color.dynamic(light: (0xFFFFFF, 0.32), dark: (0xFFFFFF, 0.20))
    /// Single-layer task-filter selection: sage pill, quiet grey on the shell.
    static let selectedPill = Color.dynamic(light: (0x9DADA1, 1), dark: (0x333333, 1))
    /// The capture field: a slightly darker bar on a card.
    static let inputFill = Color.dynamic(light: (0x000000, 0.08), dark: (0xFFFFFF, 0.08))
    static let inputFillFocused = Color.dynamic(light: (0x000000, 0.12), dark: (0xFFFFFF, 0.12))
    /// Unlit LEDs of the dot-matrix timer.
    static let unlit = Color.dynamic(light: (0x000000, 0.07), dark: (0xFFFFFF, 0.05))
    /// Chart: Completed is a solid fill (`#1A1E20`), Planned a translucent dark layer (`#727085` on lavender).
    static let chartCompleted = Color(hex: "#1A1E20")
    static let chartPlanned = Color.black.opacity(0.22)

    /// Priority shows in the ring and the "High" chip's weight, not a rainbow. Only High gets its own color.
    static func priority(_ p: TaskPriority) -> Color {
        switch p {
        case .high: return priorityHigh
        case .medium, .low: return secondary
        case .none: return .clear
        }
    }

    // MARK: Type (heading 14 bold, task 12.5 semibold, meta 10.5)
    static let heading = Font.system(size: 14, weight: .bold)
    static let title = Font.system(size: 12.5, weight: .semibold)
    static let body = Font.system(size: 12.5)
    static let meta = Font.system(size: 10.5, weight: .medium)
    static let label = Font.system(size: 11, weight: .semibold)

    // MARK: Spacing (8 pt gutter, 14 pt card padding, 13 pt card radius)
    static let gutter: CGFloat = 8
    static let cardPadding: CGFloat = 14
    static let cardRadius: CGFloat = 13
    static let controlRadius: CGFloat = 8
    /// Width of the column beside Today's tasks (focus timer, agenda).
    static let sideColumn: CGFloat = 272
}
