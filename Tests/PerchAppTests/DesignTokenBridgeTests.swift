import AppKit
import CoreText
import PerchUI
import SwiftUI
import XCTest
@testable import PerchApp

final class DesignTokenBridgeTests: XCTestCase {
    @MainActor func testDynamicColorResolutionAndPairCorrections() async throws {
        for (name, mode) in [(NSAppearance.Name.aqua, DesignTokens.Appearance.light), (.darkAqua, .dark)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for token in DesignTokens.ColorToken.allCases {
                    for background in [DesignTokens.ColorToken.paper, .apricot, .doneFill] {
                        guard let color = NSColor(Color.token(token, on: background)).usingColorSpace(.sRGB) else {
                            XCTFail("Unable to resolve sRGB color")
                            return
                        }
                        let hex = token.resolved(on: background, in: mode)
                        XCTAssertEqual(color.redComponent, Double((hex >> 16) & 255) / 255, accuracy: 0.001)
                        XCTAssertEqual(color.greenComponent, Double((hex >> 8) & 255) / 255, accuracy: 0.001)
                        XCTAssertEqual(color.blueComponent, Double(hex & 255) / 255, accuracy: 0.001)
                        XCTAssertEqual(color.alphaComponent, 1)
                    }
                }
            }
        }
    }

    @MainActor func testRegistrationFailureLogsOnceAndDoesNotRetry() async throws {
        let registry = LexendRegistration()
        var failures = 0
        var calls = 0
        for _ in 0..<2 {
            XCTAssertFalse(
                registry.register(
                    folders: [],
                    registerFont: { _ in
                        calls += 1; return false
                    }, logFailure: { failures += 1 }))
        }
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(calls, 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in DesignTokens.FontResource.files { try Data().write(to: root.appendingPathComponent(name)) }
        let failedWeight = LexendRegistration()
        for _ in 0..<2 {
            XCTAssertFalse(
                failedWeight.register(
                    folders: [root],
                    registerFont: { _ in
                        calls += 1; return calls != 2
                    }, logFailure: { failures += 1 }))
        }
        XCTAssertEqual(calls, DesignTokens.FontResource.files.count)
        XCTAssertEqual(failures, 2)
    }

    @MainActor func testAllWeightsRegisterAndBothFontPathsScale() async throws {
        XCTAssertTrue(LexendRegistration.shared.isAvailable)
        for weight in [DesignTokens.Weight.regular, .medium, .semibold, .bold] {
            XCTAssertNotNil(NSFont(name: DesignTokens.FontResource.postScriptName(for: weight), size: 14))
        }
        @MainActor func width(_ digits: String, _ fallback: Bool) -> CGFloat {
            let host = NSHostingView(rootView: Text(digits).perchFont(.timer, useSystemFont: fallback).fixedSize())
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        for fallback in [false, true] {
            XCTAssertEqual(width("111111", fallback), width("888888", fallback), accuracy: 0.5)
        }
        @MainActor func size(_ dynamicType: DynamicTypeSize, _ fallback: Bool) -> CGSize {
            let host = NSHostingView(
                rootView: Text("08:42 1122")
                    .perchFont(.timer, useSystemFont: fallback)
                    .fixedSize()
                    .environment(\.dynamicTypeSize, dynamicType))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        for fallback in [false, true] {
            let normal = size(.large, fallback)
            let larger = size(.accessibility3, fallback)
            XCTAssertGreaterThan(normal.height, 0)
            XCTAssertGreaterThan(larger.height, normal.height)
            XCTAssertGreaterThan(larger.width, normal.width)
        }
    }

    @MainActor func testResourceSearchPrefersInstalledAppAndHandlesSwiftPM() async throws {
        let app = URL(fileURLWithPath: "/Applications/Perch.app/Contents/Resources")
        let executable = URL(fileURLWithPath: "/Applications/Perch.app/Contents/MacOS/Perch")
        let folders = LexendRegistration.folders(resourceURL: app, executableURL: executable)
        XCTAssertEqual(folders.first, app.appendingPathComponent("Fonts"))
        XCTAssertTrue(folders.contains(app.appendingPathComponent("Perch_PerchUI.bundle/Contents/Resources/Fonts")))
        XCTAssertEqual(LexendRegistration.folders(resourceURL: nil, executableURL: nil), [])
    }

    @MainActor func testReducedContentTransactionsSuppressNestedSpatialAnimation() async {
        let policy = MotionPolicy(reduceMotion: true)
        for token in DesignTokens.MotionToken.allCases {
            var transaction = Transaction(animation: Motion.token(token))
            policy.enforce(on: &transaction)
            XCTAssertNil(transaction.animation)
            XCTAssertTrue(transaction.disablesAnimations)
        }
    }
}
