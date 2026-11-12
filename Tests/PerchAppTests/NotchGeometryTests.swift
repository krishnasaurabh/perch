import AppKit
import PerchUI
import PlannerCore
import SwiftUI
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

    func testClosedPaintedPathsAndHitTestingAgreeForEveryStateAndScale() {
        let states: [(name: String, timer: NotchTimerPlacement?, activity: Bool, glance: Bool)] = [
            ("idle", nil, false, false),
            ("left timer", .left, false, false),
            ("right timer", .right, false, false),
            ("activity", nil, true, false),
            ("opt-in count", nil, false, true),
        ]
        for hardware in [true, false] {
            for scale in [CGFloat(1), 2] {
                let screen = NotchLayout.Screen(
                    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                    safeAreaTop: hardware ? 32 : 0,
                    auxiliaryLeftWidth: hardware ? 663 : nil, auxiliaryRightWidth: hardware ? 664 : nil)
                let geometry = NotchGeometry(screen: screen, backingScaleFactor: scale)
                for state in states {
                    let label = "\(hardware ? "hardware" : "synthetic") housing, \(state.name), \(scale)x"
                    let housing = geometry.tuckedNotch
                    assertRoutedHitsMatchPaintedPath(
                        geometry.outline(expanded: false).path(in: CGRect(origin: .zero, size: housing.size)),
                        in: housing, geometry: geometry, state: state, scale: scale,
                        label: label, pinTopEdge: true)

                    if let side = state.timer {
                        let capsule = geometry.pill(side: side)
                        assertRoutedHitsMatchPaintedPath(
                            Capsule(style: .continuous).path(in: CGRect(origin: .zero, size: capsule.size)),
                            in: capsule, geometry: geometry, state: state, scale: scale,
                            label: "\(label) capsule")
                        let gapX =
                            side == .left
                            ? (capsule.maxX + geometry.notchRect.minX) / 2
                            : (geometry.notchRect.maxX + capsule.minX) / 2
                        XCTAssertFalse(
                            geometry.shapeContains(
                                CGPoint(x: gapX, y: capsule.midY), expanded: false,
                                timer: side, activity: false),
                            "The transparent gap beside the housing must not route")
                    }
                    if state.glance {
                        let capsule = geometry.glanceRect
                        assertRoutedHitsMatchPaintedPath(
                            Capsule(style: .continuous).path(in: CGRect(origin: .zero, size: capsule.size)),
                            in: capsule, geometry: geometry, state: state, scale: scale,
                            label: "\(label) capsule")
                        let gap = CGPoint(
                            x: (geometry.notchRect.maxX + capsule.minX) / 2, y: capsule.midY)
                        XCTAssertFalse(
                            geometry.shapeContains(
                                gap, expanded: false, timer: nil, activity: false, glance: true),
                            "The transparent gap beside the housing must not route")
                    }
                    if state.activity {
                        let strip = geometry.activityRect
                        assertRoutedHitsMatchPaintedPath(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .path(in: CGRect(origin: .zero, size: strip.size)),
                            in: strip, geometry: geometry, state: state, scale: scale,
                            label: "\(label) strip")
                    }
                }
            }
        }
    }

    private func assertRoutedHitsMatchPaintedPath(
        _ path: Path, in rect: CGRect, geometry: NotchGeometry,
        state: (name: String, timer: NotchTimerPlacement?, activity: Bool, glance: Bool),
        scale: CGFloat, label: String, pinTopEdge: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var checked = 0
        var paintedPoints = 0
        var mismatches: [String] = []
        for x in Self.sampleOffsets(rect.width, scale: scale) {
            for y in Self.sampleOffsets(rect.height, scale: scale) {
                let point = CGPoint(x: rect.minX + x, y: rect.maxY - y)
                let painted = path.contains(CGPoint(x: x, y: pinTopEdge ? max(0.5, y) : y))
                let routed = geometry.shapeContains(
                    point, expanded: false, timer: state.timer,
                    activity: state.activity, glance: state.glance)
                checked += 1
                paintedPoints += painted ? 1 : 0
                if painted != routed, mismatches.count < 4 {
                    mismatches.append(
                        "x=\(x), yDown=\(y): painted=\(painted), routed=\(routed)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 20, label, file: file, line: line)
        XCTAssertGreaterThan(paintedPoints, 0, "The fixture must include painted housing", file: file, line: line)
        XCTAssertTrue(
            mismatches.isEmpty,
            "\(label): routed hits differ from the painted path at \(mismatches)",
            file: file, line: line)
    }

    private static func sampleOffsets(_ length: CGFloat, scale: CGFloat) -> [CGFloat] {
        var offsets: Set<CGFloat> = [0.5, 1, length / 2, length - 1, length - 0.5]
        for offset in stride(from: 0.5 / scale, to: length, by: 0.5 / scale) {
            offsets.insert(offset)
        }
        return offsets.filter { $0 >= 0 && $0 < length }.sorted()
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
