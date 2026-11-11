import AppKit
import PerchUI
import SwiftUI
import XCTest
@testable import PerchApp

final class ThemeBridgeTests: XCTestCase {
    @MainActor func testNativeInkMatchesPortablePaletteInBothAppearances() async throws {
        for (name, palette) in [(NSAppearance.Name.aqua, ThemeTokens.light), (.darkAqua, ThemeTokens.dark)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for (color, hex) in [
                    (Theme.text, palette.text), (Theme.secondary, palette.secondary),
                    (Theme.tertiary, palette.tertiary), (Theme.success, palette.success),
                    (Theme.danger, palette.danger), (Theme.warning, palette.warning), (Theme.info, palette.info),
                ] {
                    let resolved = NSColor(color).usingColorSpace(.sRGB)!
                    XCTAssertEqual(resolved.redComponent, Double((hex >> 16) & 255) / 255, accuracy: 0.001)
                    XCTAssertEqual(resolved.greenComponent, Double((hex >> 8) & 255) / 255, accuracy: 0.001)
                    XCTAssertEqual(resolved.blueComponent, Double(hex & 255) / 255, accuracy: 0.001)
                    XCTAssertEqual(resolved.alphaComponent, 1)
                }
            }
        }
    }
}
