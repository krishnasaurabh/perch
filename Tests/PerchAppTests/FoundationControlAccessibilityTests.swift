import AppKit
import PerchUI
import SwiftUI
import XCTest
@testable import PerchApp

final class FoundationControlAccessibilityTests: XCTestCase {
    @MainActor func testToggleNamesValuesTargetsAndActions() async throws {
        let driver = ControlAccessibilityDriver()
        let (window, host) = makeWindow(driver)
        defer { window.close() }
        for (name, expectedRole) in [
            ("Complete Draft the test checklist", "AXCheckBox"),
            ("Complete Write the smoke tests", "AXCheckBox"),
            ("Heads-up before a block ends", "AXCheckBox"),
        ] {
            let node = try await find(name, in: window, host: host)
            XCTAssertEqual(attribute(node, "accessibilityRole") as? String, expectedRole)
            XCTAssertEqual((attribute(node, "accessibilityValue") as? NSNumber)?.intValue, 0)
            let frame = try XCTUnwrap(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            XCTAssertGreaterThanOrEqual(frame.width, 28)
            XCTAssertGreaterThanOrEqual(frame.height, 28)
            try press(node)
        }
        XCTAssertTrue(driver.task)
        XCTAssertTrue(driver.step)
        XCTAssertTrue(driver.isOn)
        for name in [
            "Complete Draft the test checklist", "Complete Write the smoke tests", "Heads-up before a block ends",
        ] {
            let node = try await find(name, in: window, host: host)
            XCTAssertEqual((attribute(node, "accessibilityValue") as? NSNumber)?.intValue, 1)
        }
    }

    @MainActor func testButtonAndSegmentActionsReachBindingsAndDisabledStatePreventsChanges() async throws {
        let driver = ControlAccessibilityDriver()
        let (window, host) = makeWindow(driver)
        defer { window.close() }
        try press(try await find("Start it now", in: window, host: host))
        XCTAssertEqual(driver.starts, 1)
        try press(try await find("25", in: window, host: host))
        XCTAssertEqual(driver.minutes, 25)
        driver.enabled = false
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let node = try await find("Start it now", in: window, host: host)
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        let implementation = try XCTUnwrap(node.method(for: selector))
        typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertFalse(unsafeBitCast(implementation, to: Enabled.self)(node, selector))
        XCTAssertEqual(driver.starts, 1)
    }

    @MainActor private func makeWindow(_ driver: ControlAccessibilityDriver) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ControlAccessibilityFixture(driver: driver))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return (window, host)
    }

    @MainActor private func find(_ label: String, in window: NSWindow, host: NSView) async throws -> NSObject {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let result = nodes(window).first(where: {
                let role = attribute($0, "accessibilityRole") as? String
                return ["AXButton", "AXCheckBox"].contains(role ?? "")
                    && (attribute($0, "accessibilityLabel") as? String == label
                        || attribute($0, "accessibilityTitle") as? String == label)
            }) {
                return result
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Missing native control: \(label)")
        throw ControlAccessibilityError.missingControl
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
            var children = ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]
                .flatMap { (attribute(node, $0) as? [NSObject]) ?? [] }
            if let view = node as? NSView { children += view.subviews }
            if let window = node as? NSWindow, let content = window.contentView { children.append(content) }
            return [node] + children.flatMap { walk($0) }
        }
        return walk(root)
    }
}

private enum ControlAccessibilityError: Error { case missingControl }

@MainActor private final class ControlAccessibilityDriver: ObservableObject {
    @Published var task = false
    @Published var step = false
    @Published var isOn = false
    @Published var minutes = 45
    @Published var enabled = true
    @Published var starts = 0
}

private struct ControlAccessibilityFixture: View {
    @ObservedObject var driver: ControlAccessibilityDriver
    var body: some View {
        VStack {
            PerchButton("Start it now") { driver.starts += 1 }
            PerchCheckbox(title: "Draft the test checklist", isOn: $driver.task)
            PerchCheckbox(title: "Write the smoke tests", isOn: $driver.step, kind: .step)
            PerchSwitch(title: "Heads-up before a block ends", isOn: $driver.isOn)
            PerchSegmented(
                title: "Minutes to set aside",
                items: [(value: 15, label: "15"), (value: 25, label: "25"), (value: 45, label: "45")],
                selection: $driver.minutes)
        }
        .disabled(!driver.enabled)
        .padding(20)
    }
}
