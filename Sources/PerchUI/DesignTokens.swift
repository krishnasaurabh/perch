/// Appearance-aware product values. Colors are opaque, encoded sRGB; lengths are points.
/// The legacy ThemeTokens palette remains for views not yet using these surface roles.
public enum DesignTokens {
    public enum Appearance: CaseIterable, Sendable { case light, dark }

    public struct AdaptiveColor: Equatable, Sendable {
        public let light: UInt32
        public let dark: UInt32
        public func hex(in appearance: Appearance) -> UInt32 { appearance == .dark ? dark : light }
    }

    public enum ColorToken: String, CaseIterable, Sendable {
        case sheet, paper, paperEdge, butter, butterEdge, blush, blushEdge
        case apricot, apricotEdge, mint, mintEdge, field, band, dot
        case ink, ink2, ink3, brandFill, onBrand, brandText, carried
        case doneText, doneFill, focusRing, onDone, switchOff, white

        public var value: AdaptiveColor {
            switch self {
            case .sheet: return AdaptiveColor(light: 0xFFF6EA, dark: 0x1B1714)
            case .paper: return AdaptiveColor(light: 0xFFFDF9, dark: 0x2A2420)
            case .paperEdge: return AdaptiveColor(light: 0xF0E2CF, dark: 0x3A312A)
            case .butter: return AdaptiveColor(light: 0xFFE7A3, dark: 0x4B3E14)
            case .butterEdge: return AdaptiveColor(light: 0xF2D27A, dark: 0x6A581C)
            case .blush: return AdaptiveColor(light: 0xFFD3C7, dark: 0x4D2A22)
            case .blushEdge: return AdaptiveColor(light: 0xF2BBAC, dark: 0x6B3A2F)
            case .apricot: return AdaptiveColor(light: 0xFFC89A, dark: 0x4A301A)
            case .apricotEdge: return AdaptiveColor(light: 0xF3B37F, dark: 0x6A4526)
            case .mint: return AdaptiveColor(light: 0xCBEBD6, dark: 0x1F3A2B)
            case .mintEdge: return AdaptiveColor(light: 0xB0D9C0, dark: 0x2D5340)
            case .field: return AdaptiveColor(light: 0xFFF1DD, dark: 0x352D27)
            case .band: return AdaptiveColor(light: 0x0E0D0C, dark: 0x0E0D0C)
            case .dot: return AdaptiveColor(light: 0xE0CBB0, dark: 0x3A312A)
            case .ink: return AdaptiveColor(light: 0x2A1B14, dark: 0xF6EDE4)
            case .ink2: return AdaptiveColor(light: 0x5E453A, dark: 0xD2C4B7)
            case .ink3: return AdaptiveColor(light: 0x75594C, dark: 0xC0B1A2)
            case .brandFill: return AdaptiveColor(light: 0xBF4428, dark: 0xF0714F)
            case .onBrand: return AdaptiveColor(light: 0xFFFFFF, dark: 0x1B1714)
            case .brandText: return AdaptiveColor(light: 0xA9391F, dark: 0xFF9B7D)
            case .carried: return AdaptiveColor(light: 0x8A4B12, dark: 0xF0B36B)
            case .doneText: return AdaptiveColor(light: 0x1C6140, dark: 0x8FD9AE)
            case .doneFill: return AdaptiveColor(light: 0x2E7D57, dark: 0x6FCB98)
            case .focusRing: return AdaptiveColor(light: 0x2456C8, dark: 0x7DB8FF)
            case .onDone: return AdaptiveColor(light: 0xFFFFFF, dark: 0xFFFFFF)
            case .switchOff: return AdaptiveColor(light: 0x8F7868, dark: 0x8F7868)
            case .white: return AdaptiveColor(light: 0xFFFFFF, dark: 0xFFFFFF)
            }
        }

        public func hex(in appearance: Appearance) -> UInt32 { value.hex(in: appearance) }

        /// Corrections apply only at the failing adjacency, never to the authored palette.
        public func resolved(on background: ColorToken, in appearance: Appearance) -> UInt32 {
            if self == .onDone && background == .doneFill && appearance == .dark {
                // White is 1.968:1. Nearest neutral gray meeting the 3:1 graphic threshold.
                return 0x646464
            }
            if self == .brandText && background == .apricot && appearance == .light {
                // #A9391F is 4.247:1. Nearest 8-bit sRGB value meeting 4.5:1 (Euclidean RGB).
                return 0xA4351E
            }
            if self == .focusRing && background == .band && appearance == .light {
                // #2456C8 is 2.996:1. A one-step blue increase reaches 3:1 on the band.
                return 0x2456C9
            }
            return hex(in: appearance)
        }
    }

    public enum Surface: String, CaseIterable, Sendable {
        case sheet, paper, butter, blush, apricot, mint, field, band

        public var fill: ColorToken {
            switch self {
            case .sheet: return .sheet
            case .paper: return .paper
            case .butter: return .butter
            case .blush: return .blush
            case .apricot: return .apricot
            case .mint: return .mint
            case .field: return .field
            case .band: return .band
            }
        }

        /// Edges are decorative; meaningful control outlines use ink or the focus ring.
        public var edge: ColorToken? {
            switch self {
            case .paper: return .paperEdge
            case .butter: return .butterEdge
            case .blush: return .blushEdge
            case .apricot: return .apricotEdge
            case .mint: return .mintEdge
            case .sheet, .field, .band: return nil
            }
        }
    }

    public enum Size: String, CaseIterable, Sendable {
        case todayWidth, weekWidth, peekWidth, stripMinWidth, stripMaxWidth
        case sheetPadding, cardGap, cardPadding, cardRadius, currentTaskRadius
        case sheetBottomRadius, taskRowHeight, stepRowHeight, addFieldHeight, addFieldRadius
        case buttonHeight, stripButtonHeight, smallButtonHeight, buttonSidePadding, taskCheckboxSize
        case checkboxStroke, minimumTarget, stepCheckboxSize, stepCheckboxRadius, switchWidth
        case switchHeight, switchKnob, segmentHeight, segmentRadius, segmentItemRadius
        case cardEdge, dotDiameter, dotSpacing, focusGap, focusWidth
        case fieldFocusWidth, pillMinHeight, pillMaxHeight, windowPadding, hoverLift

        public var value: Double {
            switch self {
            case .todayWidth: return 960
            case .weekWidth: return 1280
            case .peekWidth: return 460
            case .stripMinWidth: return 400
            case .stripMaxWidth: return 640
            case .sheetPadding: return 14
            case .cardGap: return 14
            case .cardPadding: return 16
            case .cardRadius: return 20
            case .currentTaskRadius: return 14
            case .sheetBottomRadius: return 24
            case .taskRowHeight: return 38
            case .stepRowHeight: return 30
            case .addFieldHeight: return 44
            case .addFieldRadius: return 14
            case .buttonHeight: return 40
            case .stripButtonHeight: return 36
            case .smallButtonHeight: return 30
            case .buttonSidePadding: return 18
            case .taskCheckboxSize: return 20
            case .checkboxStroke: return 2
            case .minimumTarget: return 28
            case .stepCheckboxSize: return 18
            case .stepCheckboxRadius: return 6
            case .switchWidth: return 42
            case .switchHeight: return 24
            case .switchKnob: return 18
            case .segmentHeight: return 30
            case .segmentRadius: return 10
            case .segmentItemRadius: return 8
            case .cardEdge: return 1.5
            case .dotDiameter: return 1.1
            case .dotSpacing: return 16
            case .focusGap: return 2
            case .focusWidth: return 2.5
            case .fieldFocusWidth: return 2
            case .pillMinHeight: return 22
            case .pillMaxHeight: return 34
            case .windowPadding: return 20
            case .hoverLift: return 1.5
            }
        }
    }

    /// Read the actual display's menu-bar height at the call site, not the artboard's 34 pt example.
    public static func bandHeight(menuBarHeight: Double) -> Double { menuBarHeight }

    public enum Weight: Int, Sendable { case regular = 400, medium = 500, semibold = 600, bold = 700 }
    public enum RelativeStyle: Sendable { case title, title2, headline, body, caption }
    /// Explicit scaling also works in macOS hosts that leave ScaledMetric unchanged.
    public enum TextScale: CaseIterable, Sendable {
        case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
        case accessibility1, accessibility2, accessibility3, accessibility4, accessibility5

        public var multiplier: Double {
            switch self {
            case .xSmall: return 14.0 / 17.0
            case .small: return 15.0 / 17.0
            case .medium: return 16.0 / 17.0
            case .large: return 1
            case .xLarge: return 19.0 / 17.0
            case .xxLarge: return 21.0 / 17.0
            case .xxxLarge: return 23.0 / 17.0
            case .accessibility1: return 28.0 / 17.0
            case .accessibility2: return 33.0 / 17.0
            case .accessibility3: return 40.0 / 17.0
            case .accessibility4: return 47.0 / 17.0
            case .accessibility5: return 53.0 / 17.0
            }
        }
    }

    public struct TypeSpec: Equatable, Sendable {
        public let size: Double
        public let weight: Weight
        public let relativeStyle: RelativeStyle
        public let monospacedDigits: Bool = true

        public func scaledSize(for category: TextScale) -> Double {
            max(TypeRole.detail.spec.size, size * category.multiplier)
        }
    }
    public enum TypeRole: String, CaseIterable, Sendable {
        case windowTitle, cardTitle, currentTask, stripTitle, body, button, detail, detailStrong, timer, pill
        public var spec: TypeSpec {
            switch self {
            case .windowTitle: return TypeSpec(size: 24, weight: .bold, relativeStyle: .title)
            case .cardTitle: return TypeSpec(size: 20, weight: .bold, relativeStyle: .title2)
            case .currentTask: return TypeSpec(size: 16, weight: .semibold, relativeStyle: .headline)
            case .stripTitle: return TypeSpec(size: 16, weight: .bold, relativeStyle: .headline)
            case .body: return TypeSpec(size: 14, weight: .medium, relativeStyle: .body)
            case .button: return TypeSpec(size: 14, weight: .semibold, relativeStyle: .body)
            case .detail: return TypeSpec(size: 12, weight: .medium, relativeStyle: .caption)
            case .detailStrong: return TypeSpec(size: 12, weight: .semibold, relativeStyle: .caption)
            case .timer: return TypeSpec(size: 26, weight: .bold, relativeStyle: .title)
            case .pill: return TypeSpec(size: 13, weight: .medium, relativeStyle: .caption)
            }
        }
    }

    public enum FontResource {
        public static let folder = "Fonts"
        public static let license = "OFL.txt"
        public static let weights = [400, 500, 600, 700]
        /// Original weights plus display companions with centered, equal-advance digits.
        public static let files = [
            "Lexend-Regular.ttf", "Lexend-Medium.ttf", "Lexend-SemiBold.ttf", "Lexend-Bold.ttf",
            "PerchText-Regular.ttf", "PerchText-Medium.ttf", "PerchText-SemiBold.ttf", "PerchText-Bold.ttf",
        ]
        public static func postScriptName(for weight: Weight) -> String {
            switch weight {
            case .regular: return "PerchText-Regular"
            case .medium: return "PerchText-Medium"
            case .semibold: return "PerchText-SemiBold"
            case .bold: return "PerchText-Bold"
            }
        }
    }

    public enum Curve: Equatable, Sendable { case easeOut, spring }
    public struct AnimationPlan: Equatable, Sendable {
        public let duration: Double
        public let curve: Curve
        public let allowsSpatialMotion: Bool
    }
    public enum MotionToken: String, CaseIterable, Sendable {
        case press, hover, pop, time, tickFill, tickDraw, strikeThrough
        public var duration: Double {
            switch self {
            case .press: return 0.07
            case .hover: return 0.16
            case .pop: return 0.3
            case .time: return 0.65
            case .tickFill: return 0.18
            case .tickDraw: return 0.24
            case .strikeThrough: return 0.22
            }
        }
        public func plan(reduceMotion: Bool) -> AnimationPlan {
            AnimationPlan(
                duration: reduceMotion ? Motion.reducedFade : duration,
                curve: reduceMotion || self != .pop ? .easeOut : .spring,
                allowsSpatialMotion: !reduceMotion)
        }
    }
    public enum Motion {
        public struct Spring: Equatable, Sendable {
            public let response: Double
            public let dampingFraction: Double
        }
        public static let spring = Spring(response: 0.3, dampingFraction: 0.78)
        public static let reducedFade: Double = 0.12
        public static let pressScale: Double = 0.96
        public static let tickScale: Double = 1.28
    }
}
