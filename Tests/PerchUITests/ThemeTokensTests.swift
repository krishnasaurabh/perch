import XCTest
@testable import PerchUI

final class ThemeTokensTests: XCTestCase {
    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ value: UInt32) -> Double {
            zip([16, 8, 0], [0.2126, 0.7152, 0.0722]).reduce(0) { total, pair in
                let c = Double((value >> pair.0) & 255) / 255
                return total + pair.1 * (c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
            }
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testEveryReadableTierAndStatusOnPermittedSurfaces() {
        for (palette, surfaces) in [
            (ThemeTokens.light, [ThemeTokens.sage, ThemeTokens.lavender, 0xF5F5F5, 0xFFFFFF]),
            (ThemeTokens.dark, [0, ThemeTokens.tile, ThemeTokens.tileStrong, 0x242424, 0x3A3A3A]),
        ] {
            for ink in [
                palette.text, palette.secondary, palette.tertiary, palette.success,
                palette.danger, palette.warning, palette.info,
            ] {
                for surface in surfaces { XCTAssertGreaterThanOrEqual(contrast(ink, surface), 4.5) }
            }
            for fill in [palette.control, palette.controlHover, palette.controlPressed, palette.selected] {
                for ink in [palette.text, palette.secondary, palette.tertiary] {
                    XCTAssertGreaterThanOrEqual(contrast(ink, fill), 4.5)
                }
            }
            XCTAssertGreaterThanOrEqual(contrast(palette.onAccent, palette.accent), 4.5)
            for surface in surfaces { XCTAssertGreaterThanOrEqual(contrast(palette.info, surface), 3) }
        }
    }

    func testChartSeriesAndFunctionalEdges() {
        XCTAssertGreaterThanOrEqual(contrast(ThemeTokens.chartPlanned, ThemeTokens.lavender), 3)
        XCTAssertGreaterThanOrEqual(contrast(ThemeTokens.chartCompleted, ThemeTokens.lavender), 3)
        for surface in [ThemeTokens.sage, ThemeTokens.lavender] {
            XCTAssertGreaterThanOrEqual(contrast(ThemeTokens.light.cardStroke, surface), 3)
            XCTAssertGreaterThanOrEqual(contrast(ThemeTokens.light.inputStroke, surface), 3)
        }
        for surface in [ThemeTokens.tile, ThemeTokens.tileStrong] {
            XCTAssertGreaterThanOrEqual(contrast(ThemeTokens.dark.cardStroke, surface), 3)
            XCTAssertGreaterThanOrEqual(contrast(ThemeTokens.dark.inputStroke, surface), 3)
        }
    }

    func testOverlaidSeriesAndFocusProgressRemainDistinct() {
        XCTAssertGreaterThanOrEqual(
            contrast(ThemeTokens.chartCompleted, ThemeTokens.chartPlanned), 3,
            "Completed overlays Planned, so their shared edge must remain visible")
        XCTAssertGreaterThanOrEqual(
            contrast(ThemeTokens.light.text, ThemeTokens.chartPlanned), 3,
            "Focus progress uses light-context ink on the timer card's planned-color track")
    }

    func testSmallTypeScaleAndGeometryContract() {
        XCTAssertEqual(
            [
                ThemeTokens.TypeSize.meta, ThemeTokens.TypeSize.body,
                ThemeTokens.TypeSize.heading, ThemeTokens.TypeSize.display,
            ], [11, 13, 15, 32])
        XCTAssertEqual(ThemeTokens.cardRadius, 13)
        XCTAssertEqual(ThemeTokens.controlRadius, 8)
        XCTAssertEqual(ThemeTokens.focusWidth, 2)
        XCTAssertEqual(ThemeTokens.focusGap, 2)
        XCTAssertGreaterThanOrEqual(ThemeTokens.minimumTarget, 28)
        XCTAssertGreaterThanOrEqual(ThemeTokens.primaryHeight, 32)
    }

    func testPaletteIsSendable() async {
        let value = await Task.detached { ThemeTokens.light }.value
        XCTAssertEqual(value.text, ThemeTokens.light.text)
    }
}
