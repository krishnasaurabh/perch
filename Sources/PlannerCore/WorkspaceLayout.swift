import Foundation

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
