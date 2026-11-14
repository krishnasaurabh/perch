import AppKit
import CoreText
import OSLog
import PlannerCore
import PerchUI
import SwiftUI

/// Black shell, opaque pastel cards and surface-aware ink. CardSurface supplies the
/// local scheme; native windows use the system scheme. Readable labels are opaque.
@MainActor enum Theme {
    typealias Size = DesignTokens.Size

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

    // New components use these surface roles; no forced color scheme is needed.
    static let sheet = Color.token(.sheet)
    static let paper = Color.token(.paper)
    static let butter = Color.token(.butter)
    static let blush = Color.token(.blush)
    static let apricot = Color.token(.apricot)
    static let mint = Color.token(.mint)
    static let field = Color.token(.field)
    static let band = Color.token(.band)
    static let dot = Color.token(.dot)
    static let brandFill = Color.token(.brandFill)
    static let onBrand = Color.token(.onBrand, on: .brandFill)
    static let brandText = Color.token(.brandText)
    static let carried = Color.token(.carried)
    static let doneText = Color.token(.doneText)
    static let doneFill = Color.token(.doneFill)
    static let onDone = Color.token(.onDone, on: .doneFill)
    static let focusRing = Color.token(.focusRing)
    static let ink = Color.token(.ink)
    static let ink2 = Color.token(.ink2)
    static let ink3 = Color.token(.ink3)

    static func fill(_ surface: DesignTokens.Surface) -> Color { .token(surface.fill) }
    static func edge(_ surface: DesignTokens.Surface) -> Color { surface.edge.map { .token($0) } ?? .clear }
    static func foreground(_ token: DesignTokens.ColorToken, on surface: DesignTokens.Surface) -> Color {
        .token(token, on: surface.fill)
    }

    /// Use perchFont in views to supply the environment-scaled size in both font paths.
    static func font(_ role: DesignTokens.TypeRole, scaledSize: CGFloat, useSystemFont: Bool = false) -> Font {
        let spec = role.spec
        let result: Font
        if !useSystemFont && LexendRegistration.shared.isAvailable {
            result = .custom(DesignTokens.FontResource.postScriptName(for: spec.weight), fixedSize: scaledSize)
        } else {
            result = .system(size: scaledSize, weight: spec.weight.swiftUI)
        }
        return result.monospacedDigit()
    }
}

/// Packaged apps register Fonts at launch through ATSApplicationFontsPath. SwiftPM
/// hosts also register explicitly before the first role is used. Never use Bundle.module
/// here: its generated accessor can trap after the executable is relocated.
@MainActor final class LexendRegistration {
    static let shared = LexendRegistration()
    private var attempted = false
    private var available = false
    private static let logger = Logger(subsystem: "app.perch.mac", category: "Typography")

    static func folders(resourceURL: URL?, executableURL: URL?, codeBundleURL: URL? = nil) -> [URL] {
        let roots = [
            resourceURL, executableURL?.deletingLastPathComponent(), codeBundleURL?.deletingLastPathComponent(),
        ].compactMap { $0 }
        return roots.flatMap { root in
            [
                root.appendingPathComponent("Fonts"),
                root.appendingPathComponent("Perch_PerchUI.bundle/Fonts"),
                root.appendingPathComponent("Perch_PerchUI.bundle/Contents/Resources/Fonts"),
            ]
        }
    }

    var isAvailable: Bool {
        register(
            folders: Self.folders(
                resourceURL: Bundle.main.resourceURL, executableURL: Bundle.main.executableURL,
                codeBundleURL: Bundle(for: LexendRegistration.self).bundleURL),
            registerFont: Self.registerFont,
            logFailure: { Self.logger.error("Lexend could not be registered. Using the system font.") })
    }

    /// All weights must register; failure is cached and logged once per instance.
    @discardableResult
    func register(folders: [URL], registerFont: (URL) -> Bool, logFailure: () -> Void) -> Bool {
        guard !attempted else { return available }
        attempted = true
        guard
            let folder = folders.first(where: { root in
                DesignTokens.FontResource.files.allSatisfy {
                    FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
                }
            })
        else {
            logFailure()
            return false
        }
        available = DesignTokens.FontResource.files.map { registerFont(folder.appendingPathComponent($0)) }.allSatisfy {
            $0
        }
        if !available { logFailure() }
        return available
    }

    private static func registerFont(_ url: URL) -> Bool {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        // Launch-time app registration (or a prior host) may already own the font.
        guard let failure = error?.takeRetainedValue() else { return false }
        return CFErrorGetDomain(failure) as String == kCTFontManagerErrorDomain as String
            && CFErrorGetCode(failure) == CTFontManagerError.alreadyRegistered.rawValue
    }
}
