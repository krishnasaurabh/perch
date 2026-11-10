import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Pure notch geometry, so every frame the app draws or hit-tests can be unit tested on any platform.
///
/// All rects are in AppKit global coordinates (origin at the bottom-left of the primary display, y up), in points,
/// except `Window.bounds`, which uses CoreGraphics window-list coordinates (origin top-left of the primary display, y down).
public enum NotchLayout {
    /// What the app reads from an `NSScreen`.
    public struct Screen: Equatable, Codable, Sendable {
        public var frame: CGRect
        public var visibleFrame: CGRect
        /// `safeAreaInsets.top`: the camera housing's height, 0 on a flat screen.
        public var safeAreaTop: CGFloat
        /// Widths of `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`, the menu bar either side of the housing.
        /// Widths are used rather than origins, because they mean the same thing whatever coordinate space the rects are in.
        public var auxiliaryLeftWidth: CGFloat?
        public var auxiliaryRightWidth: CGFloat?

        public init(
            frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat = 0,
            auxiliaryLeftWidth: CGFloat? = nil, auxiliaryRightWidth: CGFloat? = nil
        ) {
            self.frame = frame; self.visibleFrame = visibleFrame; self.safeAreaTop = safeAreaTop
            self.auxiliaryLeftWidth = auxiliaryLeftWidth; self.auxiliaryRightWidth = auxiliaryRightWidth
        }

        /// 0 when the menu bar is set to hide automatically.
        public var menuBarHeight: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }
    }

    /// One entry of `CGWindowListCopyWindowInfo`.
    public struct Window: Equatable, Codable, Sendable {
        public var bounds: CGRect
        public var layer: Int
        /// Belongs to this app (our own notch windows never count as full screen).
        public var isOwn: Bool
        public init(bounds: CGRect, layer: Int, isOwn: Bool = false) {
            self.bounds = bounds; self.layer = layer; self.isOwn = isOwn
        }
    }

    /// `kCGMainMenuWindowLevel`: the menu bar window. It is absent from a full-screen space.
    public static let menuBarLayer = 24
    /// Used for a drawn notch when the menu bar hides automatically.
    public static let fallbackMenuBarHeight: CGFloat = 24
    /// A drawn notch is this many times as wide as it is tall: a small, unobtrusive hover target.
    public static let drawnNotchAspect: CGFloat = 3
    /// Gap kept between the workspace and the screen's side edges.
    public static let screenMargin: CGFloat = 8
    /// Gap below the menu bar on flat screens, keeping menus, status items and the clock accessible.
    public static let menuBarGap: CGFloat = 8
    /// Extra room around the workspace for its drop shadow.
    public static let shadowPadding = (horizontal: CGFloat(24), bottom: CGFloat(48))

    // MARK: Notch

    /// The real camera housing: the gap between the two auxiliary areas, `safeAreaTop` tall. nil on a flat screen.
    public static func camera(screen: Screen) -> CGRect? {
        guard screen.safeAreaTop > 0, let l = screen.auxiliaryLeftWidth, let r = screen.auxiliaryRightWidth else {
            return nil
        }
        let minX = screen.frame.minX + l, maxX = screen.frame.maxX - r
        guard maxX - minX >= 1 else { return nil }
        return CGRect(
            x: minX, y: screen.frame.maxY - screen.safeAreaTop, width: maxX - minX, height: screen.safeAreaTop)
    }

    /// A notch to draw on a screen without one: centered, as tall as the menu bar.
    public static func drawnNotch(screen: Screen, menuBarHeight: CGFloat? = nil) -> CGRect {
        var h = menuBarHeight ?? screen.menuBarHeight
        if h <= 0 { h = fallbackMenuBarHeight }
        h = min(max(h, 22), 40)
        // Even width, so it sits exactly on the screen's center line.
        let w = 2 * (h * drawnNotchAspect / 2).rounded()
        return CGRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
    }

    /// The camera housing if there is one, otherwise the drawn notch.
    public static func notch(screen: Screen) -> CGRect { camera(screen: screen) ?? drawnNotch(screen: screen) }

    // MARK: Frames

    /// The closed shape: wings either side of the notch, measured from the housing's real edges (not the screen center).
    /// `below` grows it downward (an activity strip); `minWidth` widens both wings equally. Always inside the screen.
    public static func idleFrame(
        screen: Screen, leftWing: CGFloat, rightWing: CGFloat,
        below: CGFloat = 0, minWidth: CGFloat = 0
    ) -> CGRect {
        let n = notch(screen: screen)
        var minX = n.minX - max(0, leftWing), maxX = n.maxX + max(0, rightWing)
        if maxX - minX < minWidth {
            let grow = (minWidth - (maxX - minX)) / 2
            minX -= grow; maxX += grow
        }
        let h = n.height + max(0, below)
        return clamp(CGRect(x: minX, y: screen.frame.maxY - h, width: maxX - minX, height: h), into: screen.frame)
    }

    /// The workspace attaches to the top edge only beside a real camera housing.
    /// On flat screens, including external monitors, it floats below the menu bar.
    public static func workspaceAttached(screen: Screen) -> Bool { camera(screen: screen) != nil }

    /// Distance from the screen's top edge to the workspace's top edge: 0 beside a housing; otherwise the menu bar
    /// (the fallback height when it hides automatically, since it slides in exactly where the pointer opens Perch) plus `menuBarGap`.
    public static func workspaceTopInset(screen: Screen) -> CGFloat {
        if workspaceAttached(screen: screen) { return 0 }
        let bar = screen.menuBarHeight > 0 ? screen.menuBarHeight : fallbackMenuBarHeight
        return bar + menuBarGap
    }

    /// The open workspace, centered under the notch, never wider or taller than the screen allows. Flush with the
    /// top edge beside a housing; below the menu bar on a flat screen (`workspaceTopInset`).
    public static func workspaceFrame(screen: Screen, size: CGSize) -> CGRect {
        let f = screen.frame, top = workspaceTopInset(screen: screen)
        let w = min(size.width, f.width - 2 * screenMargin), h = max(0, min(size.height, f.height - top - screenMargin))
        let x = min(max(notch(screen: screen).midX - w / 2, f.minX + screenMargin), f.maxX - screenMargin - w)
        return CGRect(x: x, y: f.maxY - top - h, width: w, height: h)
    }

    /// Where the pointer counts as "on the notch". Open: exactly the workspace. Closed: the idle shape plus a little slop
    /// to the sides and below (never above the screen's top edge, so it can't leak onto a screen stacked above).
    public static func hoverFrame(idle: CGRect, workspace: CGRect, expanded: Bool, slop: CGFloat = 6, screen: Screen)
        -> CGRect
    {
        if expanded { return workspace }
        let r = CGRect(
            x: idle.minX - slop, y: idle.minY - slop, width: idle.width + 2 * slop, height: idle.height + slop)
        return clamp(r, into: screen.frame)
    }

    /// The transparent window per screen: big enough for every shape it may draw plus the workspace shadow.
    public static func windowFrame(screen: Screen, containing shapes: [CGRect]) -> CGRect {
        guard var u = shapes.first else { return .zero }
        for s in shapes.dropFirst() { u = u.union(s) }
        let p = shadowPadding
        let padded = CGRect(
            x: u.minX - p.horizontal, y: u.minY - p.bottom, width: u.width + 2 * p.horizontal,
            height: u.height + p.bottom)
        return padded.intersection(screen.frame)
    }

    /// While a detached workspace is open: the column under the closed shape, from the screen's top edge down to the
    /// workspace, so the pointer that opened it can travel down across the menu bar without it closing. Only as wide
    /// as the closed shape, so the rest of the menu bar stays free. nil when the workspace hangs from the top edge.
    public static func openBridge(idle: CGRect, workspace: CGRect, screen: Screen) -> CGRect? {
        let top = screen.frame.maxY
        guard workspace.maxY < top else { return nil }
        let minX = max(idle.minX, workspace.minX), maxX = min(idle.maxX, workspace.maxX)
        guard maxX > minX else { return nil }
        return CGRect(x: minX, y: workspace.maxY, width: maxX - minX, height: top - workspace.maxY)
    }

    // MARK: Full screen

    /// Converts a screen frame to CoreGraphics window-list coordinates.
    public static func cgRect(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Is a full-screen app showing on this screen? True when another app's normal-layer window spans the screen
    /// (from below the camera housing, where macOS puts full-screen windows on notched Macs, to the bottom edge)
    /// and the screen has no menu bar window, which a full-screen space removes. The menu-bar check keeps a
    /// zoomed window on a desktop from counting.
    public static func isFullScreen(screen: Screen, windows: [Window], primaryHeight: CGFloat, tolerance: CGFloat = 1)
        -> Bool
    {
        let s = cgRect(screen.frame, primaryHeight: primaryHeight)
        let housing = camera(screen: screen)?.height ?? 0
        let hasMenuBar = windows.contains { w in
            w.layer == menuBarLayer && abs(w.bounds.minY - s.minY) <= tolerance
                && w.bounds.height > 0 && w.bounds.height <= 60
                && w.bounds.midX > s.minX && w.bounds.midX < s.maxX
        }
        if hasMenuBar { return false }
        return windows.contains { w in
            !w.isOwn && w.layer == 0
                && abs(w.bounds.minX - s.minX) <= tolerance && abs(w.bounds.width - s.width) <= tolerance
                && abs(w.bounds.maxY - s.maxY) <= tolerance
                && w.bounds.minY >= s.minY - tolerance && w.bounds.minY <= s.minY + housing + tolerance
        }
    }

    // MARK: Pointer

    /// Pointer containment with AppKit's rule (`NSMouseInRect`, unflipped): the top edge belongs to the rect, the
    /// bottom edge doesn't. `NSEvent.mouseLocation` reports y == frame.maxY when the pointer is pushed against the top
    /// of a screen, which is exactly where people aim for a notch; `CGRect.contains` would miss it.
    public static func contains(_ r: CGRect, pointer p: CGPoint) -> Bool {
        p.x >= r.minX && p.x < r.maxX && p.y > r.minY && p.y <= r.maxY
    }

    /// The screen a pointer is on. Where two screens share an edge, the top edge wins (the pointer is on the lower one).
    public static func screenIndex(at p: CGPoint, in screens: [Screen]) -> Int? {
        screens.firstIndex { contains($0.frame, pointer: p) }
    }

    // MARK: Helpers

    /// Shifts (then, if needed, shrinks) `r` so it lies inside `bounds`.
    static func clamp(_ r: CGRect, into bounds: CGRect) -> CGRect {
        let w = min(r.width, bounds.width), h = min(r.height, bounds.height)
        let x = min(max(r.minX, bounds.minX), bounds.maxX - w)
        let y = min(max(r.minY, bounds.minY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// A rect as `{"x","y","w","h"}` for readable JSON dumps.
public struct LayoutRect: Codable, Equatable, Sendable {
    public var x, y, w, h: Double
    public init(_ r: CGRect) { x = Double(r.minX); y = Double(r.minY); w = Double(r.width); h = Double(r.height) }
}
