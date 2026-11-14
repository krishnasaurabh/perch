import PerchUI
import XCTest

final class SurfaceSizeContractTests: XCTestCase {
    func testSheetAndCardGeometry() {
        XCTAssertEqual(DesignTokens.Size.sheetPadding.value, 14)
        XCTAssertEqual(DesignTokens.Size.cardGap.value, 14)
        XCTAssertEqual(DesignTokens.Size.windowPadding.value, 20)
        XCTAssertEqual(DesignTokens.Size.cardPadding.value, 16)
        XCTAssertEqual(DesignTokens.Size.cardRadius.value, 20)
        XCTAssertEqual(DesignTokens.Size.currentTaskRadius.value, 14)
        XCTAssertEqual(DesignTokens.Size.sheetBottomRadius.value, 24)
        XCTAssertEqual(DesignTokens.Size.cardEdge.value, 1.5)
    }

    func testDotGridAndFieldGeometry() {
        XCTAssertEqual(DesignTokens.Size.dotDiameter.value, 1.1)
        XCTAssertEqual(DesignTokens.Size.dotSpacing.value, 16)
        XCTAssertEqual(DesignTokens.Size.addFieldHeight.value, 44)
        XCTAssertEqual(DesignTokens.Size.addFieldRadius.value, 14)
        XCTAssertEqual(DesignTokens.Size.fieldFocusWidth.value, 2)
        XCTAssertEqual(DesignTokens.Size.focusGap.value, 2)
        XCTAssertEqual(DesignTokens.Size.focusWidth.value, 2.5)
        XCTAssertGreaterThanOrEqual(DesignTokens.Size.minimumTarget.value, 28)
    }

    func testPillsAndFieldsUseLegibleScalableType() {
        XCTAssertEqual(DesignTokens.Size.pillMinHeight.value, 22)
        XCTAssertEqual(DesignTokens.Size.pillMaxHeight.value, 34)
        XCTAssertEqual(DesignTokens.TypeRole.detailStrong.spec.size, 12)
        XCTAssertEqual(DesignTokens.TypeRole.pill.spec.size, 13)
        for size in DesignTokens.TextScale.allCases {
            XCTAssertGreaterThanOrEqual(DesignTokens.TypeRole.detail.spec.scaledSize(for: size), 12)
            XCTAssertGreaterThanOrEqual(DesignTokens.TypeRole.body.spec.scaledSize(for: size), 12)
        }
    }

    func testLegacyBorderKeepsItsOriginalWidth() {
        XCTAssertEqual(ThemeTokens.focusWidth / 2, 1)
    }

    func testAllCardSurfacesHaveEdgesAndFieldHasNone() {
        for surface in [DesignTokens.Surface.paper, .butter, .blush, .apricot, .mint] {
            XCTAssertNotNil(surface.edge)
        }
        XCTAssertNil(DesignTokens.Surface.sheet.edge)
        XCTAssertNil(DesignTokens.Surface.field.edge)
    }
}
