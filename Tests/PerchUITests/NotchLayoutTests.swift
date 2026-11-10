import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import XCTest
@testable import PlannerCore
@testable import PerchUI

/// Screens as `NSScreen` reports them. Sources are noted per fixture; positions in a multi-monitor arrangement
/// use AppKit global coordinates with the MacBook as the primary display at the origin.
enum Screens {
    /// 14-inch MacBook Pro at the default 1512 x 982: a 185 x 32 pt housing with 663 pt of menu bar to its left and 664
    /// to its right (published NSScreen measurements, M1 Pro 2021). The housing is half a point off-center, on purpose.
    static let mbp14 = NotchLayout.Screen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 32, auxiliaryLeftWidth: 663, auxiliaryRightWidth: 664)
    /// 16-inch MacBook Pro at 1800 x 1169 (published NSScreen measurement: a 220 x 38 pt housing).
    static let mbp16 = NotchLayout.Screen(
        frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1131),
        safeAreaTop: 38, auxiliaryLeftWidth: 790, auxiliaryRightWidth: 790)
    /// 15-inch MacBook Air M3 at its default 1710 x 1112, measured with NSScreen on real hardware (macOS 27.0.1):
    /// safeAreaInsets.top 37.5, auxiliary areas 751 wide each, visibleFrame top 1074.
    static let mba15 = NotchLayout.Screen(
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1074),
        safeAreaTop: 37.5, auxiliaryLeftWidth: 751, auxiliaryRightWidth: 751)
    /// 14-inch at its smallest scaled resolution (1024 x 665, 22 pt housing): narrower than the workspace.
    static let mbp14Small = NotchLayout.Screen(
        frame: CGRect(x: 0, y: 0, width: 1024, height: 665),
        visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 643),
        safeAreaTop: 22, auxiliaryLeftWidth: 450, auxiliaryRightWidth: 450)
    /// 1080p monitor to the right of the MacBook, bottoms aligned, 24 pt menu bar.
    static let hd1080 = NotchLayout.Screen(
        frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1056))
    /// 4K monitor at "looks like 2560 x 1440", to the left (negative x), Dock on its left edge.
    static let uhd4k = NotchLayout.Screen(
        frame: CGRect(x: -2560, y: -200, width: 2560, height: 1440),
        visibleFrame: CGRect(x: -2480, y: -200, width: 2480, height: 1416))
    /// 4K monitor at native 1x, menu bar set to hide automatically (visibleFrame reaches the top).
    static let uhd4kNative = NotchLayout.Screen(
        frame: CGRect(x: 1512, y: 0, width: 3840, height: 2160),
        visibleFrame: CGRect(x: 1512, y: 0, width: 3840, height: 2160))
    /// 34-inch ultrawide (3440 x 1440) stacked above the MacBook.
    static let ultrawide = NotchLayout.Screen(
        frame: CGRect(x: -964, y: 982, width: 3440, height: 1440),
        visibleFrame: CGRect(x: -964, y: 982, width: 3440, height: 1415))
    /// A notch-less screen at the 14-inch size (safe area 0, no auxiliary areas), e.g. an Intel MacBook.
    static let mbp14FullScreenSpace = NotchLayout.Screen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))

    /// The GitHub macOS runner's only display: flat 1024 x 768 with a 24 pt menu bar (CI `perch-open.png`).
    static let ci1024 = NotchLayout.Screen(
        frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
        visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 744))
    /// A larger flat built-in screen: a notchless 13-inch MacBook Air at 1440 x 900, 25 pt menu bar.
    static let flat1440 = NotchLayout.Screen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), isBuiltIn: true)

    static let all: [(String, NotchLayout.Screen)] = [
        ("mbp14", mbp14), ("mbp16", mbp16), ("mba15", mba15), ("mbp14Small", mbp14Small), ("hd1080", hd1080),
        ("uhd4k", uhd4k), ("uhd4kNative", uhd4kNative), ("ultrawide", ultrawide),
        ("mbp14FullScreenSpace", mbp14FullScreenSpace),
        ("ci1024", ci1024), ("flat1440", flat1440),
    ]
}

final class NotchLayoutTests: XCTestCase {
    let workspaceSize = CGSize(width: 820, height: 470)

    // MARK: Camera housing

    func testCameraIsTheGapBetweenAuxiliaryAreas() {
        XCTAssertEqual(NotchLayout.camera(screen: Screens.mbp14), CGRect(x: 663, y: 950, width: 185, height: 32))
        XCTAssertEqual(NotchLayout.camera(screen: Screens.mbp16), CGRect(x: 790, y: 1131, width: 220, height: 38))
        XCTAssertEqual(NotchLayout.camera(screen: Screens.mba15), CGRect(x: 751, y: 1074.5, width: 208, height: 37.5))
        XCTAssertEqual(NotchLayout.camera(screen: Screens.mbp14Small), CGRect(x: 450, y: 643, width: 124, height: 22))
    }

    func testCameraFollowsTheScreenOrigin() {
        var s = Screens.mbp14
        s.frame.origin = CGPoint(x: -1512, y: 300)
        XCTAssertEqual(NotchLayout.camera(screen: s), CGRect(x: -849, y: 1250, width: 185, height: 32))
    }

    func testFlatScreensHaveNoCamera() {
        for s in [Screens.hd1080, Screens.uhd4k, Screens.uhd4kNative, Screens.ultrawide, Screens.mbp14FullScreenSpace] {
            XCTAssertNil(NotchLayout.camera(screen: s))
        }
        // A safe area without auxiliary areas, or auxiliary areas that meet, is not a housing.
        var odd = Screens.mbp14
        odd.auxiliaryRightWidth = nil
        XCTAssertNil(NotchLayout.camera(screen: odd))
        odd.auxiliaryRightWidth = 1512 - 663
        XCTAssertNil(NotchLayout.camera(screen: odd))
    }

    // MARK: Drawn notch

    func testDrawnNotchIsCenteredAndAsTallAsTheMenuBar() {
        let n = NotchLayout.drawnNotch(screen: Screens.hd1080)
        XCTAssertEqual(n, CGRect(x: 2436, y: 1056, width: 72, height: 24))
        XCTAssertEqual(n.midX, Screens.hd1080.frame.midX)
        XCTAssertEqual(n.maxY, Screens.hd1080.frame.maxY)

        let u = NotchLayout.drawnNotch(screen: Screens.ultrawide)
        XCTAssertEqual(u.height, 25)
        XCTAssertEqual(u.width, 76)
        XCTAssertEqual(u.midX, Screens.ultrawide.frame.midX)
        XCTAssertEqual(u.maxY, Screens.ultrawide.frame.maxY)
    }

    func testDrawnNotchWithAutoHiddenMenuBarUsesFallbackHeight() {
        let n = NotchLayout.drawnNotch(screen: Screens.uhd4kNative)
        XCTAssertEqual(n.height, NotchLayout.fallbackMenuBarHeight)
        XCTAssertEqual(n.maxY, 2160)
    }

    func testDrawnNotchHeightIsBounded() {
        XCTAssertEqual(NotchLayout.drawnNotch(screen: Screens.hd1080, menuBarHeight: 90).height, 40)
        XCTAssertEqual(NotchLayout.drawnNotch(screen: Screens.hd1080, menuBarHeight: 10).height, 22)
    }

    func testBuiltInFlatScreenNeverDrawsFakeNotch() {
        XCTAssertTrue(Screens.flat1440.isBuiltIn)
        XCTAssertFalse(
            NotchLayout.shouldDrawFakeNotch(
                screen: Screens.flat1440, enabled: Preferences().notchOnMonitors),
            "A new install draws nothing on a housing-less built-in screen")
        XCTAssertFalse(
            NotchLayout.shouldDrawFakeNotch(screen: Screens.flat1440, enabled: true),
            "A saved external-display preference must not affect built-in screens")
        XCTAssertTrue(NotchLayout.shouldDrawFakeNotch(screen: Screens.hd1080, enabled: true))
    }

    func testClosedNotchVisibilityGatesClicksOnWhatIsDrawn() {
        // Fresh default: nothing drawn, so nothing may be clickable, on a housing-less screen of either kind.
        XCTAssertFalse(
            NotchLayout.closedNotchVisible(screen: Screens.flat1440, enabled: Preferences().notchOnMonitors))
        XCTAssertFalse(NotchLayout.closedNotchVisible(screen: Screens.hd1080, enabled: Preferences().notchOnMonitors))
        // An older saved preference must not leave an invisible click target on a built-in screen.
        XCTAssertFalse(
            NotchLayout.closedNotchVisible(screen: Screens.flat1440, enabled: true),
            "A built-in screen never takes clicks for a notch it does not draw")
        XCTAssertTrue(NotchLayout.closedNotchVisible(screen: Screens.hd1080, enabled: true))
        // The real housing is always drawn and always takes its own clicks.
        XCTAssertTrue(NotchLayout.closedNotchVisible(screen: Screens.mbp14, enabled: false))
        XCTAssertTrue(NotchLayout.closedNotchVisible(screen: Screens.mbp14, enabled: true))
    }

    func testNotchPrefersTheRealHousing() {
        XCTAssertEqual(NotchLayout.notch(screen: Screens.mbp14), NotchLayout.camera(screen: Screens.mbp14))
        XCTAssertEqual(NotchLayout.notch(screen: Screens.hd1080), NotchLayout.drawnNotch(screen: Screens.hd1080))
    }

    // MARK: Idle frame

    func testIdleWingsSitBesideTheRealHousing() {
        let cam = NotchLayout.camera(screen: Screens.mbp14)!
        let idle = NotchLayout.idleFrame(screen: Screens.mbp14, leftWing: 32, rightWing: 32)
        XCTAssertEqual(idle, CGRect(x: 631, y: 950, width: 249, height: 32))
        XCTAssertEqual(idle.minX, cam.minX - 32)
        XCTAssertEqual(idle.maxX, cam.maxX + 32)
        // The housing is 0.5 pt left of center; the wings follow the housing, not the screen center.
        XCTAssertNotEqual(idle.midX, Screens.mbp14.frame.midX)
        XCTAssertEqual(idle.midX, cam.midX)
    }

    func testIdleWingsCanBeAsymmetric() {
        let cam = NotchLayout.camera(screen: Screens.mbp16)!
        let idle = NotchLayout.idleFrame(screen: Screens.mbp16, leftWing: 32, rightWing: 85)
        XCTAssertEqual(idle.minX, cam.minX - 32)
        XCTAssertEqual(idle.maxX, cam.maxX + 85)
        XCTAssertEqual(idle.height, 38)
        XCTAssertEqual(idle.maxY, Screens.mbp16.frame.maxY)
    }

    func testIdleOnAMonitorWrapsTheDrawnNotch() {
        let n = NotchLayout.drawnNotch(screen: Screens.hd1080)
        let idle = NotchLayout.idleFrame(screen: Screens.hd1080, leftWing: 32, rightWing: 32)
        XCTAssertEqual(idle, CGRect(x: n.minX - 32, y: 1056, width: 136, height: 24))
    }

    func testIdleActivityGrowsDownAndToMinWidthEvenly() {
        let cam = NotchLayout.camera(screen: Screens.mbp14)!
        let idle = NotchLayout.idleFrame(screen: Screens.mbp14, leftWing: 32, rightWing: 32, below: 62, minWidth: 400)
        XCTAssertEqual(idle.width, 400)
        XCTAssertEqual(idle.height, 94)
        XCTAssertEqual(idle.maxY, 982)
        XCTAssertEqual(idle.midX, cam.midX)
    }

    func testIdleIsClampedInsideTheScreen() {
        let idle = NotchLayout.idleFrame(screen: Screens.mbp14Small, leftWing: 600, rightWing: 0)
        XCTAssertEqual(idle.minX, 0)
        XCTAssertLessThanOrEqual(idle.maxX, 1024)
        let huge = NotchLayout.idleFrame(screen: Screens.mbp14Small, leftWing: 5000, rightWing: 5000)
        XCTAssertEqual(huge, CGRect(x: 0, y: 643, width: 1024, height: 22))
    }

    func testNegativeWingsAreIgnored() {
        let cam = NotchLayout.camera(screen: Screens.mbp14)!
        XCTAssertEqual(NotchLayout.idleFrame(screen: Screens.mbp14, leftWing: -10, rightWing: -10), cam)
    }

    // MARK: Workspace

    func testWorkspaceHangsFromTheTopCenteredUnderTheHousing() {
        let w = NotchLayout.workspaceFrame(screen: Screens.mbp14, size: workspaceSize)
        XCTAssertEqual(w, CGRect(x: 345.5, y: 512, width: 820, height: 470))
        XCTAssertEqual(w.midX, NotchLayout.camera(screen: Screens.mbp14)!.midX)
    }

    /// Flat screens: the workspace floats `menuBarGap` below the menu bar, so the
    /// app menus, status items and clock stay uncovered.
    func testWorkspaceOnMonitorsInEveryDirection() {
        let right = NotchLayout.workspaceFrame(screen: Screens.hd1080, size: workspaceSize)
        XCTAssertEqual(right, CGRect(x: 2062, y: 578, width: 820, height: 470))
        let left = NotchLayout.workspaceFrame(screen: Screens.uhd4k, size: workspaceSize)
        XCTAssertEqual(left, CGRect(x: -1690, y: 738, width: 820, height: 470))
        let above = NotchLayout.workspaceFrame(screen: Screens.ultrawide, size: workspaceSize)
        XCTAssertEqual(above, CGRect(x: 346, y: 1919, width: 820, height: 470), "25 pt menu bar + 8 gap")
    }

    func testWorkspaceShrinksToFitASmallScreen() {
        let tiny = NotchLayout.Screen(
            frame: CGRect(x: 0, y: 0, width: 800, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 376))
        let w = NotchLayout.workspaceFrame(screen: tiny, size: workspaceSize)
        XCTAssertEqual(w, CGRect(x: 8, y: 8, width: 784, height: 360))
    }

    // MARK: Menu bar clearance

    /// The CI display: a flat 1024 x 768 screen. The shell used to sit on the menu bar from x 102 to 922, covering
    /// Finder's menus and clipping the date beside the clock. Now the whole menu bar is clear.
    func testFlatScreenWorkspaceLeavesTheWholeMenuBarClear() {
        let ci = Screens.ci1024
        XCTAssertFalse(NotchLayout.workspaceAttached(screen: ci))
        XCTAssertEqual(NotchLayout.workspaceTopInset(screen: ci), 32)
        let w = NotchLayout.workspaceFrame(screen: ci, size: workspaceSize)
        XCTAssertEqual(w, CGRect(x: 102, y: 266, width: 820, height: 470))
        let menuBar = CGRect(x: 0, y: 744, width: 1024, height: 24)
        XCTAssertFalse(w.intersects(menuBar))
        XCTAssertEqual(menuBar.minY - w.maxY, NotchLayout.menuBarGap)
    }

    /// Review F03 (d035096): the shell covered x 102-922 of the CI menu bar and clipped the date to "ov 9 11:40 AM".
    /// On every flat screen, the open shell, the whole window band it is drawn in above its top edge, and the corner
    /// where the clock sits stay apart: nothing Perch draws or hit-tests while open overlaps the menu bar except the
    /// notch-wide bridge, which only keeps it open (clicks there pass through).
    func testFlatScreensKeepTheClockAndStatusItemsClear() {
        let flats: [(String, NotchLayout.Screen)] =
            Screens.all.filter { !NotchLayout.workspaceAttached(screen: $0.1) } + [
                (
                    "1280x800",
                    .init(
                        frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                        visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 776))
                ),
                (
                    "1680x1050",
                    .init(
                        frame: CGRect(x: 0, y: 0, width: 1680, height: 1050),
                        visibleFrame: CGRect(x: 0, y: 0, width: 1680, height: 1025))
                ),
                (
                    "2560x1440",
                    .init(
                        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                        visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415))
                ),
            ]
        XCTAssertTrue(flats.contains { $0.0 == "ci1024" } && flats.contains { $0.0 == "flat1440" })
        for (name, s) in flats {
            let w = NotchLayout.workspaceFrame(screen: s, size: workspaceSize)
            let idle = NotchLayout.idleFrame(screen: s, leftWing: 85, rightWing: 85)
            let bridge = NotchLayout.openBridge(idle: idle, workspace: w, screen: s)
            XCTAssertEqual(w.height, workspaceSize.height, "\(name): the 470 pt height policy is unchanged here")
            if s.menuBarHeight > 0 {
                let bar = s.menuBarHeight
                let menuBar = CGRect(x: s.frame.minX, y: s.frame.maxY - bar, width: s.frame.width, height: bar)
                XCTAssertFalse(w.intersects(menuBar), name)
                XCTAssertEqual(menuBar.minY - w.maxY, NotchLayout.menuBarGap, name)
                // The clock: the right-most 160 pt of the menu bar (date + time + Control Center).
                let clock = CGRect(x: menuBar.maxX - 160, y: menuBar.minY, width: 160, height: bar)
                XCTAssertFalse(idle.intersects(clock), name)
                XCTAssertNotNil(bridge, name)
                XCTAssertFalse(bridge!.intersects(clock), name)
                XCTAssertLessThanOrEqual(bridge!.width, idle.width, name)
            } else {
                XCTAssertEqual(w.maxY, s.frame.maxY, name)
                XCTAssertNil(bridge, name)
            }
            // The host window still reaches the top edge and holds the shell.
            let win = NotchLayout.windowFrame(screen: s, containing: [idle, w])
            XCTAssertEqual(win.maxY, s.frame.maxY, name)
            XCTAssertTrue(win.contains(w), name)
        }
    }

    func testFlat1440FixtureFloatsBelowItsMenuBar() {
        let s = Screens.flat1440
        let w = NotchLayout.workspaceFrame(screen: s, size: workspaceSize)
        XCTAssertEqual(w, CGRect(x: 310, y: 397, width: 820, height: 470), "25 pt menu bar + 8 gap")
        XCTAssertEqual(
            NotchLayout.openBridge(
                idle: NotchLayout.idleFrame(screen: s, leftWing: 32, rightWing: 32), workspace: w, screen: s)?.height,
            33)
    }

    func testAutoHiddenMenuBarAttachesWorkspaceToTopEdge() {
        let screen = Screens.uhd4kNative
        XCTAssertEqual(screen.menuBarHeight, 0)
        XCTAssertEqual(NotchLayout.workspaceTopInset(screen: screen), 0)
        let w = NotchLayout.workspaceFrame(screen: screen, size: workspaceSize)
        XCTAssertEqual(w.maxY, screen.frame.maxY)
        XCTAssertNil(
            NotchLayout.openBridge(
                idle: NotchLayout.idleFrame(screen: screen, leftWing: 32, rightWing: 32),
                workspace: w, screen: screen))
    }

    func testBesideAHousingTheWorkspaceStillHangsFromTheTop() {
        // The workspace attaches to the real camera housing.
        for s in [Screens.mbp14, Screens.mbp16, Screens.mba15, Screens.mbp14Small] {
            XCTAssertTrue(NotchLayout.workspaceAttached(screen: s))
            XCTAssertEqual(NotchLayout.workspaceTopInset(screen: s), 0)
            XCTAssertEqual(NotchLayout.workspaceFrame(screen: s, size: workspaceSize).maxY, s.frame.maxY)
        }
    }

    func testOpenBridgeSpansTheMenuBarUnderTheNotchOnly() {
        let s = Screens.hd1080
        let idle = NotchLayout.idleFrame(screen: s, leftWing: 32, rightWing: 32)
        let w = NotchLayout.workspaceFrame(screen: s, size: workspaceSize)
        let b = NotchLayout.openBridge(idle: idle, workspace: w, screen: s)
        XCTAssertEqual(b, CGRect(x: idle.minX, y: w.maxY, width: idle.width, height: 32))
        XCTAssertEqual(b?.maxY, s.frame.maxY)
        // Attached workspaces need no bridge.
        let m = Screens.mbp14
        XCTAssertNil(
            NotchLayout.openBridge(
                idle: NotchLayout.idleFrame(screen: m, leftWing: 32, rightWing: 32),
                workspace: NotchLayout.workspaceFrame(screen: m, size: workspaceSize), screen: m))
    }

    func testWorkspaceStaysOnScreenWhenTheNotchIsNearAnEdge() {
        // A hypothetical housing near the left edge: the workspace slides right rather than leave the screen.
        let s = NotchLayout.Screen(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32, auxiliaryLeftWidth: 100, auxiliaryRightWidth: 1227)
        let w = NotchLayout.workspaceFrame(screen: s, size: workspaceSize)
        XCTAssertEqual(w.minX, NotchLayout.screenMargin)
    }

    // MARK: Hover

    func testHoverWhenOpenIsExactlyTheWorkspace() {
        for (_, s) in Screens.all {
            let idle = NotchLayout.idleFrame(screen: s, leftWing: 32, rightWing: 32)
            let w = NotchLayout.workspaceFrame(screen: s, size: workspaceSize)
            XCTAssertEqual(NotchLayout.hoverFrame(idle: idle, workspace: w, expanded: true, screen: s), w)
        }
    }

    func testHoverWhenClosedAddsSlopButNeverPastTheTopEdge() {
        let s = Screens.mbp14
        let idle = NotchLayout.idleFrame(screen: s, leftWing: 32, rightWing: 32)
        let w = NotchLayout.workspaceFrame(screen: s, size: workspaceSize)
        let h = NotchLayout.hoverFrame(idle: idle, workspace: w, expanded: false, screen: s)
        XCTAssertEqual(h, CGRect(x: 625, y: 944, width: 261, height: 38))
        XCTAssertEqual(h.maxY, s.frame.maxY)
        // On the ultrawide stacked above, the laptop's hover area must not reach into it.
        XCTAssertLessThanOrEqual(h.maxY, Screens.ultrawide.frame.minY)
    }

    // MARK: Pointer

    func testPointerAtTheVeryTopOfAScreenIsInside() {
        let cam = NotchLayout.camera(screen: Screens.mbp14)!
        XCTAssertTrue(NotchLayout.contains(cam, pointer: CGPoint(x: cam.midX, y: 982)))
        XCTAssertFalse(cam.contains(CGPoint(x: cam.midX, y: 982)), "CGRect.contains misses the top edge")
        XCTAssertFalse(NotchLayout.contains(cam, pointer: CGPoint(x: cam.midX, y: cam.minY)))
        XCTAssertTrue(NotchLayout.contains(cam, pointer: CGPoint(x: cam.minX, y: 960)))
        XCTAssertFalse(NotchLayout.contains(cam, pointer: CGPoint(x: cam.maxX, y: 960)))
    }

    func testScreenUnderPointerAcrossArrangements() {
        let all = [Screens.mbp14, Screens.hd1080, Screens.uhd4k, Screens.ultrawide]
        XCTAssertEqual(
            NotchLayout.screenIndex(at: CGPoint(x: 755, y: 982), in: all), 0, "laptop top edge, ultrawide above")
        XCTAssertEqual(NotchLayout.screenIndex(at: CGPoint(x: 755, y: 982.5), in: all), 3)
        XCTAssertEqual(NotchLayout.screenIndex(at: CGPoint(x: 1512, y: 500), in: all), 1)
        XCTAssertEqual(NotchLayout.screenIndex(at: CGPoint(x: -1, y: 500), in: all), 2)
        XCTAssertEqual(NotchLayout.screenIndex(at: CGPoint(x: 2000, y: 1240), in: all), 3)
        XCTAssertNil(NotchLayout.screenIndex(at: CGPoint(x: 3000, y: 1200), in: all))
    }

    // MARK: Window

    func testWindowHoldsEveryShapeAndItsShadowButStaysOnItsScreen() {
        for (name, s) in Screens.all {
            let idle = NotchLayout.idleFrame(screen: s, leftWing: 85, rightWing: 85, below: 62, minWidth: 400)
            let w = NotchLayout.workspaceFrame(screen: s, size: workspaceSize)
            let win = NotchLayout.windowFrame(screen: s, containing: [idle, w])
            XCTAssertTrue(win.contains(idle), name)
            XCTAssertTrue(win.contains(w), name)
            XCTAssertTrue(s.frame.contains(win), name)
            XCTAssertEqual(win.maxY, s.frame.maxY, name)
        }
        XCTAssertEqual(NotchLayout.windowFrame(screen: Screens.mbp14, containing: []), .zero)
    }

    // MARK: Invariants over every screen

    func testInvariantsOnEveryScreen() {
        for (name, s) in Screens.all {
            let n = NotchLayout.notch(screen: s)
            XCTAssertTrue(s.frame.contains(n), name)
            XCTAssertEqual(n.maxY, s.frame.maxY, name)
            for wing in [CGFloat(0), 32, 85] {
                let idle = NotchLayout.idleFrame(screen: s, leftWing: wing, rightWing: wing)
                XCTAssertTrue(idle.contains(n), "\(name) wing \(wing)")
                XCTAssertTrue(s.frame.contains(idle), "\(name) wing \(wing)")
                XCTAssertEqual(idle.maxY, s.frame.maxY, name)
                let w = NotchLayout.workspaceFrame(screen: s, size: workspaceSize)
                let closed = NotchLayout.hoverFrame(idle: idle, workspace: w, expanded: false, screen: s)
                XCTAssertTrue(closed.contains(idle), name)
                XCTAssertTrue(s.frame.contains(closed), name)
            }
            let w = NotchLayout.workspaceFrame(screen: s, size: workspaceSize)
            XCTAssertTrue(s.frame.contains(w), name)
            XCTAssertEqual(w.maxY, s.frame.maxY - NotchLayout.workspaceTopInset(screen: s), name)
            XCTAssertTrue((w.minX <= n.minX && n.maxX <= w.maxX) || w.width < n.width, name)
            if NotchLayout.workspaceAttached(screen: s) {
                XCTAssertTrue(w.contains(n) || w.width < n.width, name)
            } else if s.menuBarHeight == 0 {
                XCTAssertEqual(w.maxY, s.frame.maxY, name)
            } else {
                // Never on a visible menu bar.
                XCTAssertLessThanOrEqual(w.maxY, s.visibleFrame.maxY - NotchLayout.menuBarGap, name)
            }
        }
    }

    // MARK: Full screen

    /// CoreGraphics window-list coordinates use the primary display's height (the MacBook, 982).
    let primary: CGFloat = 982
    func cg(_ s: NotchLayout.Screen) -> CGRect { NotchLayout.cgRect(s.frame, primaryHeight: primary) }
    func menuBar(_ s: NotchLayout.Screen) -> NotchLayout.Window {
        let r = cg(s)
        return .init(
            bounds: CGRect(x: r.minX, y: r.minY, width: r.width, height: s.menuBarHeight > 0 ? s.menuBarHeight : 24),
            layer: 24)
    }

    func testCGCoordinatesFlipAroundThePrimaryDisplay() {
        XCTAssertEqual(cg(Screens.mbp14), CGRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(cg(Screens.hd1080), CGRect(x: 1512, y: -98, width: 1920, height: 1080))
        XCTAssertEqual(cg(Screens.ultrawide), CGRect(x: -964, y: -1440, width: 3440, height: 1440))
        XCTAssertEqual(cg(Screens.uhd4k), CGRect(x: -2560, y: -258, width: 2560, height: 1440))
    }

    func testFullScreenWindowBelowTheHousingWithoutAMenuBar() {
        let s = Screens.mbp14
        let fs = NotchLayout.Window(bounds: CGRect(x: 0, y: 32, width: 1512, height: 950), layer: 0)
        XCTAssertTrue(NotchLayout.isFullScreen(screen: s, windows: [fs], primaryHeight: primary))
    }

    func testFullScreenWindowCoveringTheWholeFlatScreen() {
        let s = Screens.hd1080
        let fs = NotchLayout.Window(bounds: cg(s), layer: 0)
        XCTAssertTrue(NotchLayout.isFullScreen(screen: s, windows: [fs], primaryHeight: primary))
    }

    func testZoomedWindowOnADesktopIsNotFullScreen() {
        // Same rect a full-screen window has on a notched Mac, but the desktop still has its menu bar.
        let s = Screens.mbp14
        let zoomed = NotchLayout.Window(bounds: CGRect(x: 0, y: 32, width: 1512, height: 950), layer: 0)
        XCTAssertFalse(NotchLayout.isFullScreen(screen: s, windows: [menuBar(s), zoomed], primaryHeight: primary))
        // On a flat screen a zoomed window starts under the menu bar.
        let m = Screens.hd1080, r = cg(m)
        let z2 = NotchLayout.Window(
            bounds: CGRect(x: r.minX, y: r.minY + 24, width: r.width, height: r.height - 24), layer: 0)
        XCTAssertFalse(NotchLayout.isFullScreen(screen: m, windows: [z2], primaryHeight: primary))
    }

    func testFullScreenIsPerScreen() {
        let laptop = Screens.mbp14, monitor = Screens.hd1080, above = Screens.ultrawide
        let video = NotchLayout.Window(bounds: cg(monitor), layer: 0)
        let wins = [menuBar(laptop), menuBar(above), video]
        XCTAssertTrue(NotchLayout.isFullScreen(screen: monitor, windows: wins, primaryHeight: primary))
        XCTAssertFalse(NotchLayout.isFullScreen(screen: laptop, windows: wins, primaryHeight: primary))
        XCTAssertFalse(NotchLayout.isFullScreen(screen: above, windows: wins, primaryHeight: primary))
    }

    func testAMenuBarOnAnotherScreenDoesNotVetoThisOne() {
        let laptop = Screens.mbp14, monitor = Screens.hd1080
        let fs = NotchLayout.Window(bounds: CGRect(x: 0, y: 32, width: 1512, height: 950), layer: 0)
        XCTAssertTrue(
            NotchLayout.isFullScreen(screen: laptop, windows: [menuBar(monitor), fs], primaryHeight: primary))
    }

    func testOwnWindowsOtherLayersAndPartialWindowsDoNotCount() {
        let s = Screens.hd1080, r = cg(s)
        let own = NotchLayout.Window(bounds: r, layer: 0, isOwn: true)
        let overlay = NotchLayout.Window(bounds: r, layer: 25)
        let half = NotchLayout.Window(
            bounds: CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height), layer: 0)
        let short = NotchLayout.Window(
            bounds: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 100), layer: 0)
        let elsewhere = NotchLayout.Window(bounds: cg(Screens.mbp14), layer: 0)
        XCTAssertFalse(
            NotchLayout.isFullScreen(
                screen: s, windows: [own, overlay, half, short, elsewhere], primaryHeight: primary))
        XCTAssertFalse(NotchLayout.isFullScreen(screen: s, windows: [], primaryHeight: primary))
    }

    func testFullScreenToleratesSubPointRounding() {
        let s = Screens.ultrawide, r = cg(s)
        let fs = NotchLayout.Window(bounds: r.insetBy(dx: 0.4, dy: 0.4), layer: 0)
        XCTAssertTrue(NotchLayout.isFullScreen(screen: s, windows: [fs], primaryHeight: primary))
    }

    // MARK: JSON dump (CI artifact)

    /// With NOTCH_LAYOUT_JSON set, writes every fixture's frames so a run can be inspected without a Mac.
    func testDumpFramesToJSON() throws {
        struct Row: Encodable {
            let name: String
            let camera: LayoutRect?
            let notch, idle, idleTimer, idleActivity, workspace, hoverClosed, window: LayoutRect
        }
        let rows: [Row] = Screens.all.map { name, s in
            let idle = NotchLayout.idleFrame(screen: s, leftWing: 32, rightWing: 32)
            let timer = NotchLayout.idleFrame(screen: s, leftWing: 85, rightWing: 85)
            let act = NotchLayout.idleFrame(screen: s, leftWing: 32, rightWing: 32, below: 62, minWidth: 400)
            let w = WorkspaceLayout.frame(screen: s)
            return Row(
                name: name, camera: NotchLayout.camera(screen: s).map(LayoutRect.init),
                notch: .init(NotchLayout.notch(screen: s)), idle: .init(idle), idleTimer: .init(timer),
                idleActivity: .init(act),
                workspace: .init(w),
                hoverClosed: .init(NotchLayout.hoverFrame(idle: idle, workspace: w, expanded: false, screen: s)),
                window: .init(NotchLayout.windowFrame(screen: s, containing: [timer, act, w])))
        }
        XCTAssertEqual(rows.count, Screens.all.count)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(rows)
        XCTAssertFalse(data.isEmpty)
        if let path = ProcessInfo.processInfo.environment["NOTCH_LAYOUT_JSON"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
