/// Opaque sRGB values shared by native views and portable contrast tests.
/// Select ink by the containing surface, not by the desktop appearance.
public enum ThemeTokens {
    public struct Palette: Sendable {
        public let text, secondary, tertiary: UInt32
        public let success, danger, warning, info: UInt32
        public let accent, onAccent, cardStroke, inputStroke: UInt32
        public let control, controlHover, controlPressed, selected: UInt32
    }

    public static let light = Palette(
        text: 0x090C0A, secondary: 0x181E1A, tertiary: 0x232924,
        success: 0x0C2B15, danger: 0x4F0D0D, warning: 0x352100, info: 0x09263F,
        accent: 0x1A1E20, onAccent: 0xFFFFFF, cardStroke: 0x2F3D33, inputStroke: 0x29352D,
        control: 0x9DADA1, controlHover: 0xB0BCB3, controlPressed: 0x95A59A, selected: 0x9DADA1)
    public static let dark = Palette(
        text: 0xF5F7F5, secondary: 0xCFD5D0, tertiary: 0xAEB8B0,
        success: 0x7AD98F, danger: 0xFF8585, warning: 0xF2C166, info: 0x90C7FF,
        accent: 0xF19644, onAccent: 0x1A1A1A, cardStroke: 0x858585, inputStroke: 0x999999,
        control: 0x242424, controlHover: 0x3A3A3A, controlPressed: 0x303030, selected: 0x333333)

    public static let sage: UInt32 = 0x879E8D
    public static let lavender: UInt32 = 0x938EAB
    public static let tile: UInt32 = 0x1D1D1D
    public static let tileStrong: UInt32 = 0x303030
    public static let chartCompleted: UInt32 = 0x1A1E20
    public static let chartPlanned: UInt32 = 0x423F50

    public enum TypeSize {
        public static let meta: Double = 11
        public static let body: Double = 13
        public static let heading: Double = 15
        public static let display: Double = 32
    }

    public static let cardRadius: Double = 13
    public static let controlRadius: Double = 8
    public static let cardPadding: Double = 14
    public static let gutter: Double = 8
    public static let focusWidth: Double = 2
    public static let focusGap: Double = 2
    public static let minimumTarget: Double = 28
    public static let primaryHeight: Double = 32
}
