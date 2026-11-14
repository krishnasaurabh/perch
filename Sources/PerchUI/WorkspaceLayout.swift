import Foundation
import PlannerCore

/// Stable first-open geometry. Content never drives the window size (typing and insertion stay in-place).
public enum WorkspaceLayout {
    public static let preferredWidth: CGFloat = 820
    public static let contentHeight: CGFloat = 300
    public static let minimumHeaderHeight: CGFloat = 30
    public static let headerGap: CGFloat = 8
    public static let bottomInset: CGFloat = 13

    public static func headerHeight(notchHeight: CGFloat) -> CGFloat {
        max(minimumHeaderHeight, notchHeight)
    }

    public static func preferredSize(notchHeight: CGFloat = 0) -> CGSize {
        CGSize(
            width: preferredWidth,
            height: contentHeight + headerHeight(notchHeight: notchHeight) + headerGap + bottomInset)
    }

    /// Uses the same screen clamp and menu-bar clearance as drawing, hover and click routing.
    public static func frame(screen: NotchLayout.Screen) -> CGRect {
        NotchLayout.workspaceFrame(
            screen: screen, size: preferredSize(notchHeight: NotchLayout.notch(screen: screen).height))
    }
}

extension WorkspaceLayout {
    public static let sheetHeight: CGFloat = 510
    public static let screenSideMargin: CGFloat = 32
    public static let bandInset = CGFloat(DesignTokens.Size.sheetPadding.value)
    public static let bandGap = CGFloat(DesignTokens.Size.stepCheckboxRadius.value)
    public static let bandTarget = CGFloat(DesignTokens.Size.minimumTarget.value)
    public static let bandControlHeight = CGFloat(DesignTokens.Size.minimumTarget.value)
    public static let minimumComingDayWidth: CGFloat = 140
    public static let pastDayWeight: CGFloat = 0.85
    public static let todayWeight: CGFloat = 1.7
    public static let weekGap = CGFloat(DesignTokens.Size.cardPadding.value / 2)

    public static func bandHeight(menuBarHeight: CGFloat) -> CGFloat {
        CGFloat(DesignTokens.bandHeight(menuBarHeight: Double(max(0, menuBarHeight))))
    }

    public static func preferredSize(page: WorkspacePage, menuBarHeight: CGFloat) -> CGSize {
        CGSize(
            width: page == .week ? DesignTokens.Size.weekWidth.value : DesignTokens.Size.todayWidth.value,
            height: sheetHeight + bandHeight(menuBarHeight: menuBarHeight))
    }

    public static func frame(screen: NotchLayout.Screen, page: WorkspacePage, menuBarHeight: CGFloat? = nil) -> CGRect {
        var size = preferredSize(page: page, menuBarHeight: menuBarHeight ?? screen.menuBarHeight)
        size.width = min(size.width, max(0, screen.frame.width - 2 * screenSideMargin))
        return NotchLayout.workspaceFrame(screen: screen, size: size)
    }

    public static func widthMotion(reduceMotion: Bool) -> DesignTokens.AnimationPlan {
        DesignTokens.MotionToken.pop.plan(reduceMotion: reduceMotion)
    }

    public struct WeekColumns: Equatable, Sendable {
        public let days: [DayKey]
        public let today: DayKey
        public let standardWidth: CGFloat
        public let omittedPastDays: Int
        public let needsHorizontalScroll: Bool
        public var parkingWidth: CGFloat { standardWidth }
        public func width(for day: DayKey) -> CGFloat {
            standardWidth * (day == today ? todayWeight : day < today ? pastDayWeight : 1)
        }
    }

    /// The parking lot consumes one normal column. Drop only the earliest past
    /// days; if today onward cannot fit, keep those days and permit horizontal scrolling.
    public static func weekColumns(days: [DayKey], today: DayKey, available: CGFloat) -> WeekColumns {
        var visible = days
        func unitWidth() -> CGFloat {
            let weight = visible.reduce(CGFloat(1)) {
                $0 + ($1 == today ? todayWeight : $1 < today ? pastDayWeight : 1)
            }
            return max(0, available - CGFloat(visible.count) * weekGap) / weight
        }
        var removed = 0
        while unitWidth() < minimumComingDayWidth, visible.count > 1,
            let first = visible.first, first < today
        {
            visible.removeFirst()
            removed += 1
        }
        let width = unitWidth()
        return WeekColumns(
            days: visible, today: today, standardWidth: max(minimumComingDayWidth, width),
            omittedPastDays: removed, needsHorizontalScroll: width < minimumComingDayWidth)
    }
}
