import AppKit
import PerchUI
import SwiftUI

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0x8E8CF5
        self.init(
            red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// Opaque, system-appearance-aware color with optional pair-specific correction.
    static func token(_ token: DesignTokens.ColorToken, on background: DesignTokens.ColorToken? = nil) -> Color {
        func value(_ appearance: DesignTokens.Appearance) -> UInt32 {
            background.map { token.resolved(on: $0, in: appearance) } ?? token.hex(in: appearance)
        }
        return dynamic(light: (value(.light), 1), dark: (value(.dark), 1))
    }

    /// A color that follows the appearance, and so the SwiftUI `colorScheme`, of whatever draws it.
    static func dynamic(light: (UInt32, CGFloat), dark: (UInt32, CGFloat)) -> Color {
        Color(
            nsColor: NSColor(name: nil) { ap in
                let (v, a) = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: a)
            })
    }
}

extension DesignTokens.Weight {
    var swiftUI: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

extension DynamicTypeSize {
    fileprivate var tokenScale: DesignTokens.TextScale {
        switch self {
        case .xSmall: return .xSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .xLarge
        case .xxLarge: return .xxLarge
        case .xxxLarge: return .xxxLarge
        case .accessibility1: return .accessibility1
        case .accessibility2: return .accessibility2
        case .accessibility3: return .accessibility3
        case .accessibility4: return .accessibility4
        case .accessibility5: return .accessibility5
        @unknown default: return .large
        }
    }
}

/// Scales the same authored size for Lexend and the system-font fallback.
private struct PerchFontModifier: ViewModifier {
    let role: DesignTokens.TypeRole
    let useSystemFont: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(
            Theme.font(
                role, scaledSize: role.spec.scaledSize(for: dynamicTypeSize.tokenScale), useSystemFont: useSystemFont))
    }
}

extension View {
    func perchFont(_ role: DesignTokens.TypeRole, useSystemFont: Bool = false) -> some View {
        modifier(PerchFontModifier(role: role, useSystemFont: useSystemFont))
    }
}
