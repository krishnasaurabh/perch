import Foundation
import XCTest
@testable import PerchApp

#if os(macOS)
    import AppKit
    import PerchUI
    import PlannerCore
    import SwiftUI
#endif

final class InsightsPageLayoutTests: XCTestCase {
    func testCompactPageWidthsStackMomentumBelowChart() {
        for width: CGFloat in [640, 668, 700, 739.5] {
            XCTAssertEqual(InsightsPageLayout.resolve(width: width), .stacked, "Page width: \(width)")
        }
    }

    func testBreakpointKeepsTwoColumns() {
        XCTAssertEqual(InsightsPageLayout.twoColumnMinimumWidth, 740)
        XCTAssertEqual(InsightsPageLayout.resolve(width: 740), .twoColumn)
    }

    func testWidePageWidthsKeepTwoColumns() {
        // An 820pt workspace offers 784pt after its two horizontal insets.
        for width: CGFloat in [784, 820, 1024] {
            XCTAssertEqual(InsightsPageLayout.resolve(width: width), .twoColumn, "Page width: \(width)")
        }
    }

    func testInitialZeroWidthUsesCompactLayout() {
        XCTAssertEqual(InsightsPageLayout.resolve(width: 0), .stacked)
    }
}

#if os(macOS)
    final class InsightsPageGeometryTests: XCTestCase {
        @MainActor
        func testPageWidthInsideCompactAndPreferredWorkspaces() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = PlannerStore(
                file: PlannerFile(url: root.appendingPathComponent("planner.json")), watching: false)
            let task = try XCTUnwrap(store.apply { try $0.addTasks(["Layout sample"], on: .day($0.today)) }?.first)
            XCTAssertNotNil(store.apply { try $0.complete(task.id) })

            // The workspace is screen-clamped, not a resizable window with a fixed minimum.
            for (screenWidth, expectedPageWidth, expectedLayout) in [
                (CGFloat(720), CGFloat(668), InsightsPageLayout.stacked),
                (CGFloat(1024), CGFloat(784), InsightsPageLayout.twoColumn),
            ] {
                let screen = NotchLayout.Screen(
                    frame: CGRect(x: 0, y: 0, width: screenWidth, height: 768),
                    visibleFrame: CGRect(x: 0, y: 0, width: screenWidth, height: 744))
                let workspace = WorkspaceLayout.frame(screen: screen)
                let observed = WidthObservation()
                let page = InsightsPage().environmentObject(store)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.onAppear { observed.width = geometry.size.width }
                        }
                    }
                    // Same insets as WorkspaceView and NotchRootView, respectively.
                    .padding(.horizontal, 8)
                    .padding(.horizontal, 10)
                let host = NSHostingView(rootView: page)
                host.sizingOptions = []
                let window = NSWindow(
                    contentRect: CGRect(origin: .zero, size: CGSize(width: workspace.width, height: 300)),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.setContentSize(CGSize(width: workspace.width, height: 300))
                window.orderFront(nil)
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                for _ in 0..<50 where observed.width == nil {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let width = try XCTUnwrap(observed.width)
                print("Insights geometry: screen=\(screenWidth), workspace=\(workspace.width), page=\(width)")
                XCTAssertEqual(width, expectedPageWidth, accuracy: 0.5)
                XCTAssertEqual(InsightsPageLayout.resolve(width: width), expectedLayout)
            }
        }

        @MainActor
        private final class WidthObservation {
            var width: CGFloat?
        }
    }
#endif
