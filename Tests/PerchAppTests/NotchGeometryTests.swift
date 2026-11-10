import AppKit
import PerchUI
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
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
