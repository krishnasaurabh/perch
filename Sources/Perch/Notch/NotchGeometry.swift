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
    static let workspaceSize = CGSize(width: 820, height: 470)
    /// Wing widths either side of the notch: owl + task count, or owl + running timer.
    static let wing: CGFloat = 32, timerWing: CGFloat = 85
    /// An activity strip hangs this far below the notch, at least this wide.
    static let activityDepth: CGFloat = 62, activityWidth: CGFloat = 400, activityWing: CGFloat = 100

    let screen: NotchLayout.Screen

    init(screen: NotchLayout.Screen) { self.screen = screen }
    init(screen: NSScreen) { self.screen = NotchLayout.Screen(screen) }

    var screenFrame: NSRect { screen.frame }
    var camera: NSRect? { NotchLayout.camera(screen: screen) }
    var hasHardwareNotch: Bool { camera != nil }
    /// The real camera housing, or the notch Perch draws on a flat screen.
    var notchRect: NSRect { NotchLayout.notch(screen: screen) }
    var notchSize: CGSize { notchRect.size }
    var workspace: NSRect { NotchLayout.workspaceFrame(screen: screen, size: Self.workspaceSize) }

    func idle(timer: Bool, activity: Bool) -> NSRect {
        if activity {
            return NotchLayout.idleFrame(screen: screen, leftWing: Self.activityWing, rightWing: Self.activityWing,
                                         below: Self.activityDepth, minWidth: Self.activityWidth)
        }
        let w = timer ? Self.timerWing : Self.wing
        return NotchLayout.idleFrame(screen: screen, leftWing: w, rightWing: w)
    }

    /// The visible shape in global coordinates.
    func shape(expanded: Bool, timer: Bool, activity: Bool) -> NSRect {
        expanded ? workspace : idle(timer: timer, activity: activity)
    }

    /// Where hovering opens the notch (closed), or keeps it open (expanded: exactly the workspace).
    func hover(expanded: Bool, timer: Bool, activity: Bool) -> NSRect {
        NotchLayout.hoverFrame(idle: idle(timer: timer, activity: activity), workspace: workspace, expanded: expanded, screen: screen)
    }

    /// The transparent window: fixed per screen and large enough for every shape, so it never moves while animating.
    var window: NSRect {
        NotchLayout.windowFrame(screen: screen, containing: [idle(timer: true, activity: true), idle(timer: true, activity: false), workspace])
    }

    static func radii(expanded: Bool) -> (top: CGFloat, bottom: CGFloat) { expanded ? (10, 26) : (6, 12) }

    /// Exact hit test against the drawn closed silhouette (not its bounding box). Global coordinates, y up.
    static func silhouetteContains(_ p: NSPoint, shape r: NSRect) -> Bool {
        guard NotchLayout.contains(r, pointer: p) else { return false }
        let k = radii(expanded: false)
        let path = NotchShape(topRadius: k.top, bottomRadius: k.bottom).path(in: CGRect(origin: .zero, size: r.size))
        // SwiftUI paths are y-down. Pull a pointer pinned to the top edge just inside.
        return path.contains(CGPoint(x: p.x - r.minX, y: max(0.5, r.maxY - p.y)))
    }
}

/// Notch silhouette: flush with the top edge, small concave shoulders, rounded bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat = 6
    var bottomRadius: CGFloat = 14

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
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
