import Foundation

/// Copy and overflow rules for a Week day column, kept here so they are testable on Linux.
public enum WeekColumnLayout {
    public static let dragHint = "Drag to move. Double-click for details."
    public static let pastHint = "Older days stay unchanged in your history."

    /// Chip tooltip: the full title first (chips truncate at two lines), then the hint that applies.
    public static func chipHelp(title: String, past: Bool) -> String {
        let hint = past ? pastHint : dragHint
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? hint : "\(t)\n\(hint)"
    }

    /// How many chips end below the visible part of the column. `chipBottoms` are each chip's bottom edge in the
    /// scroll viewport's coordinates (they move up as the column scrolls), `viewport` is the visible height.
    /// Before the first layout pass the viewport is 0, and nothing counts as hidden.
    public static func hiddenBelow(chipBottoms: [Double], viewport: Double) -> Int {
        guard viewport > 0 else { return 0 }
        return chipBottoms.filter { $0 > viewport + 0.5 }.count
    }

    /// Chip title type: the regular size, and the smallest size a chip may step down to so a long word still fits.
    public static let titleSize = 11.0
    public static let minTitleSize = 9.5

    /// How a chip title is set so no word ever breaks across lines. `widestWord` is the widest word's width at
    /// `titleSize`, `available` the width the title gets. Text width scales with point size, so the title steps
    /// down in half points until that word fits; if even `minTitleSize` is too wide it stays at `titleSize` on
    /// one line and truncates at the end instead of wrapping inside the word. Before layout (`available` <= 0)
    /// the regular two-line setting is used.
    public static func titleFit(widestWord: Double, available: Double) -> TitleFit {
        guard available > 0, widestWord > available else { return TitleFit(size: titleSize, lines: 2) }
        let scaled = (titleSize * available / widestWord * 2).rounded(.down) / 2
        return scaled >= minTitleSize ? TitleFit(size: scaled, lines: 2) : TitleFit(size: titleSize, lines: 1)
    }

    public struct TitleFit: Equatable {
        public let size: Double
        public let lines: Int
        public init(size: Double, lines: Int) { self.size = size; self.lines = lines }
    }

    /// The quiet overflow line under a busy column, or nil when everything fits.
    public static func overflowLabel(hidden: Int) -> String? { hidden > 0 ? "+\(hidden) more" : nil }
}
