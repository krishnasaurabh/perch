import AppKit
import PerchUI
import SwiftUI
import XCTest
@testable import PerchApp

final class FoundationControlTests: XCTestCase {
    @MainActor func testNativeControlSizes() async {
        for size in PerchButtonSize.allCases {
            let actual = measure(PerchButton("Start it now", size: size) {})
            XCTAssertEqual(actual.height, size.height, accuracy: 2)
            XCTAssertGreaterThanOrEqual(actual.width, DesignTokens.Size.minimumTarget.value)
        }
        for kind in PerchCheckbox.Kind.allCases {
            for checked in [false, true] {
                let actual = measure(PerchCheckbox(title: "A task", isOn: .constant(checked), kind: kind))
                XCTAssertEqual(actual.width, 28, accuracy: 0.5)
                XCTAssertEqual(actual.height, 28, accuracy: 0.5)
            }
        }
        for checked in [false, true] {
            let actual = measure(PerchSwitch(title: "Heads-up before a block ends", isOn: .constant(checked)))
            XCTAssertEqual(actual.width, 42, accuracy: 0.5)
            XCTAssertEqual(actual.height, 28, accuracy: 0.5)
        }
        let choices = [(value: 15, label: "15"), (value: 25, label: "25"), (value: 45, label: "45")]
        let segment = measure(PerchSegmented(title: "Minutes to set aside", items: choices, selection: .constant(45)))
        XCTAssertEqual(segment.height, 30, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(segment.width, 3 * 28)
    }

    @MainActor func testLargeTextGrowsButtonsWithoutClipping() async {
        let normal = measure(PerchButton("Start it now") {}.environment(\.dynamicTypeSize, .large))
        let large = measure(PerchButton("Start it now") {}.environment(\.dynamicTypeSize, .accessibility3))
        XCTAssertGreaterThan(large.height, normal.height)
        XCTAssertGreaterThan(large.width, normal.width)
    }

    @MainActor func testKeyboardModalityDoesNotFollowHoverOrPointerFocus() async {
        let modality = ControlInputModality(observeEvents: false)
        XCTAssertTrue(modality.keyboard)
        modality.receive(.leftMouseDown)
        XCTAssertFalse(modality.keyboard)
        modality.receive(.mouseMoved)
        XCTAssertFalse(modality.keyboard)
        modality.receive(.keyDown)
        XCTAssertTrue(modality.keyboard)
        modality.receive(.mouseMoved)
        XCTAssertTrue(modality.keyboard)
        modality.receive(.rightMouseDown)
        XCTAssertFalse(modality.keyboard)
    }

    @MainActor func testPopReaches128PercentOnceAndReducedMotionNeverScales() async {
        for reduced in [false, true] {
            for isOn in [false, true] {
                let timeline = KeyframeTimeline(initialValue: 1.0) {
                    PerchCheckbox.popKeyframes(isOn: isOn, reduceMotion: reduced)
                }
                XCTAssertEqual(timeline.duration, 0.3, accuracy: 0.000001)
                XCTAssertEqual(
                    timeline.value(time: timeline.duration / 2), reduced || !isOn ? 1 : 1.28, accuracy: 0.000001)
                XCTAssertEqual(timeline.value(time: timeline.duration), 1, accuracy: 0.000001)
                XCTAssertEqual(timeline.value(time: timeline.duration * 2), 1, accuracy: 0.000001)
            }
        }
    }

    @MainActor func testSwitchTravelAndTickStayInsideTheirPaintBounds() async {
        XCTAssertEqual(PerchSwitch.knobInset, 3)
        XCTAssertEqual(PerchSwitch.knobTravel, 18)
        for kind in PerchCheckbox.Kind.allCases {
            let bounds = CGRect(x: 0, y: 0, width: kind.diameter, height: kind.diameter)
            XCTAssertTrue(bounds.contains(PerchCheckMark().path(in: bounds).boundingRect))
        }
    }

    @MainActor private func measure<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view.fixedSize())
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
