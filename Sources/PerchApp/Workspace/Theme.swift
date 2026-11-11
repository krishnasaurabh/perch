import PlannerCore
import PerchUI
import SwiftUI

/// Black shell, opaque pastel cards and surface-aware ink. CardSurface supplies the
/// local scheme; native windows use the system scheme. Readable labels are opaque.
@MainActor enum Theme {
    private static func ink(_ key: KeyPath<ThemeTokens.Palette, UInt32>) -> Color {
        Color.dynamic(light: (ThemeTokens.light[keyPath: key], 1), dark: (ThemeTokens.dark[keyPath: key], 1))
    }
    private static func color(_ value: UInt32) -> Color {
        Color(
            .sRGB, red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    static let notchBlack = Color.black
    static let sage = color(ThemeTokens.sage)
    static let lavender = color(ThemeTokens.lavender)
    static let tile = color(ThemeTokens.tile)
    static let tileStrong = color(ThemeTokens.tileStrong)
    static let card = tile
    static let cardStroke = ink(\.cardStroke)
    static let inputStroke = ink(\.inputStroke)
    static let rope = cardStroke

    static let text = ink(\.text)
    static let secondary = ink(\.secondary)
    static let tertiary = ink(\.tertiary)
    static let success = ink(\.success)
    static let done = success
    static let danger = ink(\.danger)
    static let warning = ink(\.warning)
    static let info = ink(\.info)
    static let priorityHigh = warning
    static let accent = ink(\.accent)
    static let owl = Color(hex: "#F19644")
    static let onAccent = ink(\.onAccent)
    static let prominent = accent

    // Opaque fills prevent hover and selection from stacking translucent layers.
    static let fill = ink(\.control)
    static let fillStrong = ink(\.controlHover)
    static let fillPressed = ink(\.controlPressed)
    static let selectedPill = ink(\.selected)
    static let inputFill = Color.dynamic(light: (0x000000, 0.08), dark: (0xFFFFFF, 0.08))
    static let inputFillFocused = Color.dynamic(light: (0x000000, 0.12), dark: (0xFFFFFF, 0.12))
    static let unlit = Color.dynamic(light: (0x000000, 0.07), dark: (0xFFFFFF, 0.05))
    static let chartCompleted = color(ThemeTokens.chartCompleted)
    static let chartPlanned = color(ThemeTokens.chartPlanned)

    static func priority(_ priority: TaskPriority) -> Color {
        switch priority {
        case .high: return warning
        case .medium: return info
        case .low: return tertiary
        case .none: return .clear
        }
    }

    // Four authored sizes; aliases vary weight, not point size.
    static let meta = Font.system(size: ThemeTokens.TypeSize.meta, weight: .medium)
    static let body = Font.system(size: ThemeTokens.TypeSize.body)
    static let title = Font.system(size: ThemeTokens.TypeSize.body, weight: .semibold)
    static let label = Font.system(size: ThemeTokens.TypeSize.meta, weight: .semibold)
    static let heading = Font.system(size: ThemeTokens.TypeSize.heading, weight: .semibold)
    static let display = Font.system(size: ThemeTokens.TypeSize.display, weight: .semibold)
    static let gutter: CGFloat = ThemeTokens.gutter
    static let cardPadding: CGFloat = ThemeTokens.cardPadding
    static let cardRadius: CGFloat = ThemeTokens.cardRadius
    static let controlRadius: CGFloat = ThemeTokens.controlRadius
    static let minimumTarget: CGFloat = ThemeTokens.minimumTarget
    static let primaryHeight: CGFloat = ThemeTokens.primaryHeight
    static let focusWidth: CGFloat = ThemeTokens.focusWidth
    static let focusGap: CGFloat = ThemeTokens.focusGap
    static let sideColumn: CGFloat = 272
}
