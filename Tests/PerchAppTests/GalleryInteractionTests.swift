import AppKit
import SwiftUI
import XCTest
@testable import PerchApp

#if DEBUG || PERCH_TESTING
    final class GalleryInteractionTests: XCTestCase {
        @MainActor func testActionsChangeTheVisibleGalleryWithoutAPlanner() async throws {
            let app = NSApplication.shared
            let originalPolicy = app.activationPolicy()
            app.setActivationPolicy(.accessory)
            let host = NSHostingView(
                rootView: GalleryPage(page: .motion)
                    .environment(\.accessibilityEnabled, true)
                    .environment(\.motionPolicyOverride, MotionPolicy(reduceMotion: true)))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: GalleryPage.Page.motion.size),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            defer {
                window.close()
                app.setActivationPolicy(originalPolicy)
            }

            try press(try await find("Start it now", role: "AXButton", in: window))
            _ = try await find("Pause", role: "AXButton", in: window)
            try press(try await find("Pause", role: "AXButton", in: window))
            _ = try await find("Start", role: "AXButton", in: window)
            try press(try await find("+5 min", role: "AXButton", in: window))
            _ = try await find("30 minutes left of 45", in: window)
            try press(try await find("Back to 24:10", role: "AXButton", in: window))
            _ = try await find("25 minutes left of 45", in: window)
            try press(try await find("15", role: "AXButton", in: window))
            _ = try await find("15 minutes left of 15", in: window)
            let step = try await find("Complete Write the smoke tests", role: "AXCheckBox", in: window)
            try press(step)
            _ = try await find("10:00 – 10:45 · 3 of 4 steps", in: window)
            let headsUp = try await find("Heads-up before a block ends", role: "AXCheckBox", in: window)
            XCTAssertEqual((attribute(headsUp, "accessibilityValue") as? NSNumber)?.intValue, 1)
            try press(headsUp)
            let toggled = try await find("Heads-up before a block ends", role: "AXCheckBox", value: 0, in: window)
            XCTAssertEqual((attribute(toggled, "accessibilityValue") as? NSNumber)?.intValue, 0)
        }

        @MainActor private func find(_ label: String, role: String? = nil, value: Int? = nil, in window: NSWindow)
            async throws -> NSObject
        {
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                window.contentView?.layoutSubtreeIfNeeded()
                if let node = nodes(window).first(where: { node in
                    let values = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
                        .compactMap { attribute(node, $0) as? String }
                    return values.contains(label)
                        && (role == nil || attribute(node, "accessibilityRole") as? String == role)
                        && (value == nil || (attribute(node, "accessibilityValue") as? NSNumber)?.intValue == value)
                }) {
                    return node
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Gallery is missing \(label)")
            throw GalleryInteractionError.missingElement
        }

        @MainActor private func attribute(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }

        @MainActor private func press(_ node: NSObject) throws {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            let implementation = try XCTUnwrap(node.responds(to: selector) ? node.method(for: selector) : nil)
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(node, selector))
        }

        @MainActor private func nodes(_ root: NSObject) -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            @MainActor func walk(_ node: NSObject) -> [NSObject] {
                guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
                var children = [
                    "accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder",
                ]
                .flatMap { (attribute(node, $0) as? [NSObject]) ?? [] }
                if let view = node as? NSView { children += view.subviews }
                if let window = node as? NSWindow, let view = window.contentView { children.append(view) }
                return [node] + children.flatMap { walk($0) }
            }
            return walk(root)
        }
    }

    private enum GalleryInteractionError: Error { case missingElement }
#endif
