import XCTest
@testable import PerchUI

final class FoundationControlContractTests: XCTestCase {
    func testSizesAndTargetClearance() {
        let size = DesignTokens.Size.self
        XCTAssertEqual(size.minimumTarget.value, 28)
        XCTAssertEqual(
            [size.buttonHeight.value, size.stripButtonHeight.value, size.smallButtonHeight.value], [40, 36, 30])
        XCTAssertEqual(size.taskCheckboxSize.value, 20)
        XCTAssertEqual(size.stepCheckboxSize.value, 18)
        XCTAssertEqual(size.stepCheckboxRadius.value, 6)
        XCTAssertLessThan(size.taskCheckboxSize.value, size.minimumTarget.value)
        XCTAssertLessThan(size.stepCheckboxSize.value, size.minimumTarget.value)
        XCTAssertEqual(size.switchWidth.value, 42)
        XCTAssertEqual(size.switchHeight.value, 24)
        XCTAssertEqual(size.switchKnob.value, 18)
        XCTAssertEqual(size.segmentHeight.value, 30)
        XCTAssertEqual(size.segmentRadius.value, 10)
        XCTAssertEqual(size.segmentItemRadius.value, 8)
        XCTAssertEqual(size.focusGap.value, 2)
        XCTAssertEqual(size.focusWidth.value, 2.5)
    }

    func testFeedbackAndCheckmarkTimings() {
        XCTAssertEqual(DesignTokens.Size.hoverLift.value, 1.5)
        XCTAssertEqual(DesignTokens.Motion.pressScale, 0.96)
        XCTAssertEqual(DesignTokens.Motion.tickScale, 1.28)
        XCTAssertEqual(DesignTokens.MotionToken.tickFill.duration, 0.18)
        XCTAssertEqual(DesignTokens.MotionToken.tickDraw.duration, 0.24)
        for token in DesignTokens.MotionToken.allCases {
            let plan = token.plan(reduceMotion: true)
            XCTAssertFalse(plan.allowsSpatialMotion)
            XCTAssertEqual(plan.curve, .easeOut)
            XCTAssertEqual(plan.duration, 0.12)
        }
    }

    func testSelectedLabelAndToggleGraphicsContrastInBothAppearances() {
        for mode in DesignTokens.Appearance.allCases {
            let pairs: [(DesignTokens.ColorToken, DesignTokens.ColorToken, Double)] = [
                (.paper, .ink, 4.5), (.ink, .field, 4.5), (.onBrand, .brandFill, 4.5),
                (.onDone, .doneFill, 3), (.white, .switchOff, 3),
                (.doneFill, .paper, 3), (.switchOff, .paper, 3),
            ]
            for (foreground, background, minimum) in pairs {
                let a = luminance(foreground.resolved(on: background, in: mode))
                let b = luminance(background.hex(in: mode))
                XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), minimum)
            }
        }
    }

    private func luminance(_ rgb: UInt32) -> Double {
        let values = [16, 8, 0].map { shift -> Double in
            let value = Double((rgb >> shift) & 255) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }
}
