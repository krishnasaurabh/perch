import AppKit
import PerchUI
import PlannerCore
import XCTest
@testable import PerchApp

final class NotchGeometryTests: XCTestCase {
    func testBuiltInFlatScreenDoesNotDrawOrRouteSyntheticNotchWhenEnabled() {
        let screen = NotchLayout.Screen(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), isBuiltIn: true)
        let geometry = NotchGeometry(screen: screen)
        let enabled = true

        XCTAssertFalse(NotchLayout.shouldDrawFakeNotch(screen: screen, enabled: enabled))
        let points = [
            CGPoint(x: geometry.notchRect.midX, y: screen.frame.maxY),
            CGPoint(x: geometry.tuckedNotch.midX, y: geometry.tuckedNotch.midY),
            CGPoint(x: geometry.pill(side: .right).midX, y: geometry.pill(side: .right).midY),
        ]
        for point in points {
            XCTAssertFalse(
                geometry.shapeContains(point, expanded: false, timer: .right, activity: false),
                "Built-in synthetic notch must not capture clicks at \(point)")
        }
        XCTAssertTrue(
            geometry.shapeContains(
                geometry.workspace.center, expanded: true, timer: nil, activity: false),
            "Suppressing the closed synthetic notch must not prevent the workspace opening")

        var external = screen
        external.isBuiltIn = false
        let externalGeometry = NotchGeometry(screen: external)
        XCTAssertTrue(NotchLayout.shouldDrawFakeNotch(screen: external, enabled: enabled))
        XCTAssertTrue(
            externalGeometry.shapeContains(
                CGPoint(x: externalGeometry.notchRect.midX, y: external.frame.maxY),
                expanded: false, timer: nil, activity: false),
            "The same explicit preference still enables an external synthetic notch")
    }

    func testActivityControlsStayClickableWithoutBecomingOpenTargets() {
        let screen = NotchLayout.Screen(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32, auxiliaryLeftWidth: 663, auxiliaryRightWidth: 664)
        let geometry = NotchGeometry(screen: screen)
        let activity = geometry.idle(timer: nil, activity: true)
        let openTarget = geometry.hover(expanded: false, timer: nil, activity: true)

        XCTAssertEqual(openTarget, geometry.notchRect)
        for x in [activity.minX + 40, activity.maxX - 22] {
            let control = CGPoint(x: x, y: activity.minY + 20)
            XCTAssertTrue(
                geometry.shapeContains(control, expanded: false, timer: nil, activity: true),
                "The strip must keep receiving its own control clicks")
            XCTAssertFalse(
                NotchLayout.contains(openTarget, pointer: control),
                "The same control click must not be routed to workspace opening")
        }
        let gap = CGPoint(x: activity.midX, y: activity.minY - 1)
        XCTAssertFalse(geometry.shapeContains(gap, expanded: false, timer: nil, activity: true))
        XCTAssertFalse(NotchLayout.contains(openTarget, pointer: gap))
    }
    func testDetachedTimerKeepsEveryGapAndCornerClickThrough() {
        for scale in [CGFloat(1), 2] {
            for side in [PlannerCore.NotchTimerPlacement.left, .right] {
                let screen = NotchLayout.Screen(
                    frame: CGRect(x: -1512, y: 300, width: 1512, height: 982),
                    visibleFrame: CGRect(x: -1512, y: 300, width: 1512, height: 950),
                    safeAreaTop: 32, auxiliaryLeftWidth: 663, auxiliaryRightWidth: 664)
                let g = NotchGeometry(screen: screen, backingScaleFactor: scale)
                let pill = g.pill(side: side)
                let gapX = side == .left ? (pill.maxX + g.notchRect.minX) / 2 : (g.notchRect.maxX + pill.minX) / 2
                let gap = CGPoint(x: gapX, y: pill.midY)
                XCTAssertFalse(g.shapeContains(gap, expanded: false, timer: side, activity: false))
                XCTAssertFalse(
                    NotchLayout.contains(g.hover(expanded: false, timer: side, activity: false), pointer: gap))
                XCTAssertFalse(
                    g.shapeContains(
                        CGPoint(x: pill.minX + 0.5 / scale, y: pill.maxY - 0.5 / scale),
                        expanded: false, timer: side, activity: false))
                XCTAssertTrue(g.shapeContains(pill.center, expanded: false, timer: side, activity: false))
                XCTAssertEqual(g.hover(expanded: false, timer: side, activity: false), g.notchRect)
                XCTAssertEqual(pill.height * scale, (pill.height * scale).rounded())
                XCTAssertTrue(g.window.contains(pill))
                XCTAssertEqual(g.idle(timer: nil, activity: false), g.tuckedNotch)
            }
        }
    }

    func testActivityDoesNotPaintOrCaptureTheMenuBarBesideHousing() {
        for hardware in [true, false] {
            let screen = NotchLayout.Screen(
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                safeAreaTop: hardware ? 32 : 0,
                auxiliaryLeftWidth: hardware ? 663 : nil, auxiliaryRightWidth: hardware ? 664 : nil)
            let g = NotchGeometry(screen: screen)
            XCTAssertLessThan(g.activityRect.maxY, g.notchRect.minY)
            XCTAssertTrue(g.window.contains(g.activityRect))
            for x in [g.activityRect.minX + 20, g.activityRect.maxX - 20] {
                let menuItem = CGPoint(x: x, y: screen.frame.maxY - 5)
                XCTAssertFalse(g.shapeContains(menuItem, expanded: false, timer: nil, activity: true))
                XCTAssertFalse(
                    NotchLayout.contains(g.hover(expanded: false, timer: nil, activity: true), pointer: menuItem))
            }
            let gap = CGPoint(x: g.notchRect.midX, y: g.notchRect.minY - 2)
            XCTAssertFalse(g.shapeContains(gap, expanded: false, timer: nil, activity: true))
            XCTAssertTrue(g.shapeContains(g.activityRect.center, expanded: false, timer: nil, activity: true))
        }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
