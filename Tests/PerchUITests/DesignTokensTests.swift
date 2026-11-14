import XCTest
@testable import PerchUI

final class DesignTokensTests: XCTestCase {
    func testEveryAuthoredColorInBothAppearances() {
        let expected: [DesignTokens.ColorToken: [UInt32]] = [
            .sheet: [0xFFF6EA, 0x1B1714],
            .paper: [0xFFFDF9, 0x2A2420],
            .paperEdge: [0xF0E2CF, 0x3A312A],
            .butter: [0xFFE7A3, 0x4B3E14],
            .butterEdge: [0xF2D27A, 0x6A581C],
            .blush: [0xFFD3C7, 0x4D2A22],
            .blushEdge: [0xF2BBAC, 0x6B3A2F],
            .apricot: [0xFFC89A, 0x4A301A],
            .apricotEdge: [0xF3B37F, 0x6A4526],
            .mint: [0xCBEBD6, 0x1F3A2B],
            .mintEdge: [0xB0D9C0, 0x2D5340],
            .field: [0xFFF1DD, 0x352D27],
            .band: [0x0E0D0C, 0x0E0D0C],
            .dot: [0xE0CBB0, 0x3A312A],
            .ink: [0x2A1B14, 0xF6EDE4],
            .ink2: [0x5E453A, 0xD2C4B7],
            .ink3: [0x75594C, 0xC0B1A2],
            .brandFill: [0xBF4428, 0xF0714F],
            .onBrand: [0xFFFFFF, 0x1B1714],
            .brandText: [0xA9391F, 0xFF9B7D],
            .carried: [0x8A4B12, 0xF0B36B],
            .doneText: [0x1C6140, 0x8FD9AE],
            .doneFill: [0x2E7D57, 0x6FCB98],
            .focusRing: [0x2456C8, 0x7DB8FF],
            .onDone: [0xFFFFFF, 0xFFFFFF],
            .switchOff: [0x8F7868, 0x8F7868],
            .white: [0xFFFFFF, 0xFFFFFF],
        ]
        XCTAssertEqual(Set(expected.keys), Set(DesignTokens.ColorToken.allCases))
        for (token, pair) in expected {
            XCTAssertEqual(token.hex(in: .light), pair[0], "\(token) light")
            XCTAssertEqual(token.hex(in: .dark), pair[1], "\(token) dark")
        }
    }

    func testEverySize() {
        let expected: [DesignTokens.Size: Double] = [
            .todayWidth: 960,
            .weekWidth: 1280,
            .peekWidth: 460,
            .stripMinWidth: 400,
            .stripMaxWidth: 640,
            .sheetPadding: 14,
            .cardGap: 14,
            .cardPadding: 16,
            .cardRadius: 20,
            .currentTaskRadius: 14,
            .sheetBottomRadius: 24,
            .taskRowHeight: 38,
            .stepRowHeight: 30,
            .addFieldHeight: 44,
            .addFieldRadius: 14,
            .buttonHeight: 40,
            .stripButtonHeight: 36,
            .smallButtonHeight: 30,
            .buttonSidePadding: 18,
            .taskCheckboxSize: 20,
            .checkboxStroke: 2,
            .minimumTarget: 28,
            .stepCheckboxSize: 18,
            .stepCheckboxRadius: 6,
            .switchWidth: 42,
            .switchHeight: 24,
            .switchKnob: 18,
            .segmentHeight: 30,
            .segmentRadius: 10,
            .segmentItemRadius: 8,
            .cardEdge: 1.5,
            .dotDiameter: 1.1,
            .dotSpacing: 16,
            .focusGap: 2,
            .focusWidth: 2.5,
            .fieldFocusWidth: 2,
            .pillMinHeight: 22,
            .pillMaxHeight: 34,
            .windowPadding: 20,
            .hoverLift: 1.5,
        ]
        XCTAssertEqual(Set(expected.keys), Set(DesignTokens.Size.allCases))
        for (token, value) in expected { XCTAssertEqual(token.value, value, "\(token)") }
    }

    func testSurfaceEdgesAndRuntimeBandHeight() {
        let edges: [DesignTokens.Surface: DesignTokens.ColorToken] = [
            .paper: .paperEdge, .butter: .butterEdge, .blush: .blushEdge,
            .apricot: .apricotEdge, .mint: .mintEdge,
        ]
        for surface in DesignTokens.Surface.allCases { XCTAssertEqual(surface.edge, edges[surface]) }
        XCTAssertEqual(DesignTokens.bandHeight(menuBarHeight: 27), 27)
        XCTAssertEqual(DesignTokens.bandHeight(menuBarHeight: 34), 34)
    }

    func testTypeRolesAndTabularDigits() {
        let expected: [DesignTokens.TypeRole: [Int]] = [
            .windowTitle: [24, 700], .cardTitle: [20, 700], .currentTask: [16, 600],
            .stripTitle: [16, 700], .body: [14, 500], .button: [14, 600],
            .detail: [12, 500], .detailStrong: [12, 600], .timer: [26, 700], .pill: [13, 500],
        ]
        XCTAssertEqual(Set(expected.keys), Set(DesignTokens.TypeRole.allCases))
        for (role, values) in expected {
            XCTAssertEqual(role.spec.size, Double(values[0]))
            XCTAssertEqual(role.spec.weight.rawValue, values[1])
            XCTAssertTrue(role.spec.monospacedDigits)
            XCTAssertGreaterThanOrEqual(role.spec.size, 12)
        }
        XCTAssertEqual(DesignTokens.FontResource.weights, [400, 500, 600, 700])
    }

    func testDynamicTypeScaleIncludesFallbackAndMinimum() {
        XCTAssertEqual(DesignTokens.TypeRole.body.spec.scaledSize(for: .large), 14)
        XCTAssertEqual(DesignTokens.TypeRole.detail.spec.scaledSize(for: .xSmall), 12)
        for role in DesignTokens.TypeRole.allCases {
            var prior: Double = 0
            for category in DesignTokens.TextScale.allCases {
                let size = role.spec.scaledSize(for: category)
                XCTAssertGreaterThanOrEqual(size, prior)
                XCTAssertGreaterThanOrEqual(size, 12)
                prior = size
            }
            XCTAssertGreaterThan(role.spec.scaledSize(for: .accessibility3), role.spec.size)
        }
    }

    func testMotionAndReducedFadeForEveryToken() {
        let expected: [DesignTokens.MotionToken: Double] = [
            .press: 0.07, .hover: 0.16, .pop: 0.3, .time: 0.65,
            .tickFill: 0.18, .tickDraw: 0.24, .strikeThrough: 0.22,
        ]
        XCTAssertEqual(Set(expected.keys), Set(DesignTokens.MotionToken.allCases))
        for (token, duration) in expected {
            XCTAssertEqual(token.plan(reduceMotion: false).duration, duration)
            let reduced = token.plan(reduceMotion: true)
            XCTAssertEqual(reduced.duration, 0.12)
            XCTAssertEqual(reduced.curve, .easeOut)
            XCTAssertFalse(reduced.allowsSpatialMotion)
        }
        XCTAssertEqual(DesignTokens.MotionToken.pop.plan(reduceMotion: false).curve, .spring)
        XCTAssertEqual(DesignTokens.Motion.pressScale, 0.96)
        XCTAssertEqual(DesignTokens.Motion.tickScale, 1.28)
        XCTAssertEqual(DesignTokens.Motion.spring.response, 0.3)
        XCTAssertEqual(DesignTokens.Motion.spring.dampingFraction, 0.78)
    }

    func testPairSpecificCorrectionsNeverChangeAuthoredColors() {
        XCTAssertEqual(DesignTokens.ColorToken.focusRing.hex(in: .light), 0x2456C8)
        XCTAssertEqual(DesignTokens.ColorToken.focusRing.resolved(on: .band, in: .light), 0x2456C9)
        XCTAssertEqual(DesignTokens.ColorToken.onDone.hex(in: .dark), 0xFFFFFF)
        XCTAssertEqual(DesignTokens.ColorToken.onDone.resolved(on: .doneFill, in: .dark), 0x646464)
        XCTAssertEqual(DesignTokens.ColorToken.onDone.resolved(on: .paper, in: .dark), 0xFFFFFF)
        XCTAssertEqual(DesignTokens.ColorToken.brandText.hex(in: .light), 0xA9391F)
        XCTAssertEqual(DesignTokens.ColorToken.brandText.resolved(on: .apricot, in: .light), 0xA4351E)
        XCTAssertEqual(DesignTokens.ColorToken.brandText.resolved(on: .paper, in: .light), 0xA9391F)
    }
}
