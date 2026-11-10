import AppKit
import PlannerCore
import SwiftUI

extension NotchLayout.Screen {
    /// Reads everything `NotchLayout` needs from a live screen.
    init(_ s: NSScreen) {
        self.init(frame: s.frame, visibleFrame: s.visibleFrame, safeAreaTop: s.safeAreaInsets.top,
                  auxiliaryLeftWidth: s.auxiliaryTopLeftArea?.width, auxiliaryRightWidth: s.auxiliaryTopRightArea?.width)
    }
}

/// The notch frames for one screen. A thin AppKit-side view of `NotchLayout`; every number comes from there.
struct NotchGeometry: Equatable {
    static let workspaceSize = WorkspaceLayout.preferredSize()
    /// The closed timer is a separate black capsule beside the notch (not fused to it): this wide, this far from it.
    static let pillWidth: CGFloat = 76, pillGap: CGFloat = 6
    /// With nothing to show, the drawn shape tucks this far inside the camera housing (sides and bottom), so it is
    /// fully hidden behind the hardware and never peeks out by a rounding pixel.
    static let tuck: CGFloat = 1
    /// An activity strip hangs this far below the notch, at least this wide.
    static let activityDepth: CGFloat = 62, activityWidth: CGFloat = 400, activityWing: CGFloat = 100

    let screen: NotchLayout.Screen
    let backingScaleFactor: CGFloat

    init(screen: NotchLayout.Screen, backingScaleFactor: CGFloat = 1) {
        self.screen = screen
        self.backingScaleFactor = max(1, backingScaleFactor)
    }
    init(screen: NSScreen) {
        self.init(screen: NotchLayout.Screen(screen), backingScaleFactor: screen.backingScaleFactor)
    }

    var screenFrame: NSRect { screen.frame }
    var camera: NSRect? { NotchLayout.camera(screen: screen) }
    var hasHardwareNotch: Bool { camera != nil }
    /// The real camera housing, or the notch Perch draws on a flat screen.
    var notchRect: NSRect { NotchLayout.notch(screen: screen) }
    var notchSize: CGSize { notchRect.size }
    var workspace: NSRect { WorkspaceLayout.frame(screen: screen) }
    /// The open workspace hangs from the top edge beside a housing, and floats below the menu bar on a flat screen.
    var workspaceAttached: Bool { NotchLayout.workspaceAttached(screen: screen) }

    /// The closed shape's bounds. Nothing to show: exactly the housing (tucked inside it), so the notch looks untouched.
    /// A running timer: that plus a detached capsule on its side. A nudge: a strip below.
    func idle(timer: NotchTimerPlacement?, activity: Bool) -> NSRect {
        if activity {
            return NotchLayout.idleFrame(screen: screen, leftWing: Self.activityWing, rightWing: Self.activityWing,
                                         below: Self.activityDepth, minWidth: Self.activityWidth)
        }
        if let side = timer { return tuckedNotch.union(pill(side: side)) }
        return tuckedNotch
    }

    /// The housing, 1pt inside on the sides and bottom; the drawn notch on a flat screen.
    var tuckedNotch: NSRect {
        guard let cam = camera else { return notchRect }
        return NSRect(x: cam.minX + Self.tuck, y: cam.minY + Self.tuck, width: cam.width - 2 * Self.tuck, height: cam.height - Self.tuck)
    }

    /// The timer capsule: about three quarters of the notch's height, centred on it vertically, `pillGap` from its side.
    func pill(side: NotchTimerPlacement) -> NSRect {
        let n = notchRect, visible = tuckedNotch, scale = backingScaleFactor
        let h = (n.height * 0.72 * scale).rounded() / scale
        // Centre on the visible (tucked) notch, snapped to a device pixel, rounding up so it never sits low.
        let top = n.maxY - ((visible.height - h) / 2 * scale).rounded(.down) / scale
        let x = side == .left ? n.minX - Self.pillGap - Self.pillWidth : n.maxX + Self.pillGap
        return NSRect(x: x, y: top - h, width: Self.pillWidth, height: h)
    }

    /// The visible shape in global coordinates.
    func shape(expanded: Bool, timer: NotchTimerPlacement?, activity: Bool) -> NSRect {
        expanded ? workspace : idle(timer: timer, activity: activity)
    }

    /// Where hovering opens the notch (closed), or keeps it open (expanded: exactly the workspace).
    func hover(expanded: Bool, timer: NotchTimerPlacement?, activity: Bool) -> NSRect {
        NotchLayout.hoverFrame(idle: idle(timer: timer, activity: activity), workspace: workspace, expanded: expanded, screen: screen)
    }

    /// Open on a flat screen: the strip of menu bar between the notch and the floating workspace. The pointer may
    /// cross it without the workspace closing; clicks there still reach the menu bar.
    func openBridge(timer: NotchTimerPlacement?, activity: Bool) -> NSRect? {
        NotchLayout.openBridge(idle: idle(timer: timer, activity: activity), workspace: workspace, screen: screen)
    }

    /// The transparent window: fixed per screen and large enough for every shape, so it never moves while animating.
    var window: NSRect {
        NotchLayout.windowFrame(screen: screen, containing: [idle(timer: nil, activity: true), idle(timer: .left, activity: false),
                                                                idle(timer: .right, activity: false), workspace])
    }

    static func radii(expanded: Bool) -> (top: CGFloat, bottom: CGFloat) { expanded ? (10, 26) : (6, 12) }

    /// The outline drawn for a state. The one source for the fill, the clip, the content shape and the hit test, so what
    /// takes clicks is exactly what is visible: beside a housing (and always when closed) it hangs from the top edge with
    /// concave shoulders; open on a flat screen it is a rounded rectangle floating below the menu bar.
    func outline(expanded: Bool) -> NotchShape {
        let k = Self.radii(expanded: expanded)
        return NotchShape(topRadius: k.top, bottomRadius: k.bottom, attached: !expanded || workspaceAttached)
    }

    /// Exact hit test against the drawn shape (not its bounding box). Global coordinates, y up.
    func shapeContains(_ p: NSPoint, expanded: Bool, timer: NotchTimerPlacement?, activity: Bool) -> Bool {
        if !expanded, !activity, let side = timer {
            return NotchLayout.contains(pill(side: side), pointer: p) || NotchLayout.contains(tuckedNotch, pointer: p)
        }
        let r = shape(expanded: expanded, timer: timer, activity: activity)
        guard NotchLayout.contains(r, pointer: p) else { return false }
        let path = outline(expanded: expanded).path(in: CGRect(origin: .zero, size: r.size))
        // SwiftUI paths are y-down. Pull a pointer pinned to the top edge just inside.
        return path.contains(CGPoint(x: p.x - r.minX, y: max(0.5, r.maxY - p.y)))
    }
}

/// Notch silhouette: flush with the top edge, small concave shoulders, rounded bottom. Detached (the workspace
/// floating below a flat screen's menu bar) it is a plain continuous rounded rectangle with `bottomRadius` corners.
struct NotchShape: Shape {
    var topRadius: CGFloat = 6
    var bottomRadius: CGFloat = 14
    var attached = true

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        if !attached {
            return RoundedRectangle(cornerRadius: min(bottomRadius, r.height / 2, r.width / 2), style: .continuous).path(in: r)
        }
        var p = Path()
        let t = topRadius, b = min(bottomRadius, r.height / 2)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Borderless panel above the menu bar, one per screen. Mouse routing is set per pointer move by `NotchController`.
final class NotchPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onUndo: ((Bool) -> Void)?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keep the frame exactly where the controller puts it (AppKit would push it below the menu bar).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Let text views handle their own undo.
        if event.charactersIgnoringModifiers == "z", flags.contains(.command), !(firstResponder is NSTextView) {
            onUndo?(flags.contains(.shift))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Clicks land on the first click even when Perch is in the background.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Reads the on-screen window list for `NotchLayout.isFullScreen`. Bounds and layers need no permission.
enum WindowList {
    static func current() -> [NotchLayout.Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { w in
            guard let layer = w[kCGWindowLayer as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return NotchLayout.Window(bounds: r, layer: layer, isOwn: (w[kCGWindowOwnerPID as String] as? pid_t) == me)
        }
    }
}
