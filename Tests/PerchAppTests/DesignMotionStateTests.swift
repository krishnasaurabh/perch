import AppKit
import PerchUI
import SwiftUI
import XCTest
@testable import PerchApp

final class DesignMotionStateTests: XCTestCase {
    @MainActor func testTokenChangesAndPolicyChangesKeepLocalState() async throws {
        for token in DesignTokens.MotionToken.allCases {
            let driver = MotionStateDriver()
            let host = NSHostingView(rootView: MotionStateFixture(driver: driver, token: token))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 180, height: 60),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }

            try await waitForSnapshot(driver, host: host) { $0.value == 0 }
            let original = try XCTUnwrap(driver.snapshot)
            original.seed(7, "Unsaved draft")
            try await waitForSnapshot(driver, host: host) { $0.count == 7 && $0.draft == "Unsaved draft" }

            // Exercise both directions, including changing policy on the same mounted control.
            for reduced in [false, true, false, true] {
                driver.reduced = reduced
                try await waitForSnapshot(driver, host: host) { $0.reduced == reduced }
                assertState(driver.snapshot, matches: original, token: token)
                for _ in 0..<2 {
                    withAnimation(.spring()) { driver.value += 1 }
                    let expectedValue = driver.value
                    try await waitForSnapshot(driver, host: host) { $0.value == expectedValue }
                    assertState(driver.snapshot, matches: original, token: token)
                    let snapshot = try XCTUnwrap(driver.snapshot)
                    XCTAssertEqual(snapshot.disablesAnimations, reduced, token.rawValue)
                    XCTAssertEqual(snapshot.hasAnimation, !reduced, token.rawValue)
                    // Check again after the entire fade, not just its first update.
                    try await Task.sleep(for: .milliseconds(160))
                    host.layoutSubtreeIfNeeded()
                    assertState(driver.snapshot, matches: original, token: token)
                }
            }
        }
    }

    @MainActor func testReducedKeyframesAreOneNonrepeating120MillisecondFade() {
        let fade = KeyframeTimeline(initialValue: 1.0) { Motion.fadeKeyframes(reduceMotion: true) }
        XCTAssertEqual(fade.duration, DesignTokens.Motion.reducedFade, accuracy: 0.000_001)
        XCTAssertEqual(fade.value(time: 0), 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(fade.value(time: fade.duration / 2), 0)
        XCTAssertLessThan(fade.value(time: fade.duration / 2), 1)
        XCTAssertEqual(fade.value(time: fade.duration), 1, accuracy: 0.000_001)
        XCTAssertEqual(fade.value(time: fade.duration * 2), 1, accuracy: 0.000_001)

        let normal = KeyframeTimeline(initialValue: 1.0) { Motion.fadeKeyframes(reduceMotion: false) }
        for time in [0, normal.duration / 2, normal.duration] {
            XCTAssertEqual(normal.value(time: time), 1, accuracy: 0.000_001)
        }
    }

    @MainActor private func assertState(
        _ snapshot: MotionStateSnapshot?, matches original: MotionStateSnapshot, token: DesignTokens.MotionToken
    ) {
        XCTAssertEqual(snapshot?.identity, original.identity, token.rawValue)
        XCTAssertEqual(snapshot?.count, 7, token.rawValue)
        XCTAssertEqual(snapshot?.draft, "Unsaved draft", token.rawValue)
    }

    @MainActor private func waitForSnapshot(
        _ driver: MotionStateDriver, host: NSView, predicate: (MotionStateSnapshot) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let snapshot = driver.snapshot, predicate(snapshot) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The hosted token-motion control did not reach its expected state")
        throw MotionStateFailure.missingUpdate
    }
}

private enum MotionStateFailure: Error { case missingUpdate }

@MainActor private final class MotionStateDriver: ObservableObject {
    @Published var value = 0
    @Published var reduced = false
    var snapshot: MotionStateSnapshot?
}

@MainActor private struct MotionStateSnapshot {
    let identity: UUID
    let count: Int
    let draft: String
    let value: Int
    let reduced: Bool
    let hasAnimation: Bool
    let disablesAnimations: Bool
    let seed: (Int, String) -> Void
}

@MainActor private struct MotionStateFixture: View {
    @ObservedObject var driver: MotionStateDriver
    let token: DesignTokens.MotionToken

    var body: some View {
        StatefulMotionControl(driver: driver)
            .designMotion(token, value: driver.value)
            .motionBoundary()
            .environment(\.motionPolicyOverride, MotionPolicy(reduceMotion: driver.reduced))
    }
}

@MainActor private struct StatefulMotionControl: View {
    @ObservedObject var driver: MotionStateDriver
    @State private var identity = UUID()
    @State private var count = 0
    @State private var draft = "Default"

    var body: some View {
        MotionStateReader(driver: driver, identity: identity, count: $count, draft: $draft)
            .frame(width: 180, height: 60)
            // The reduced-motion boundary must suppress even a nested spatial animation.
            .animation(.spring(), value: driver.value)
    }
}

@MainActor private struct MotionStateReader: NSViewRepresentable {
    @ObservedObject var driver: MotionStateDriver
    let identity: UUID
    @Binding var count: Int
    @Binding var draft: String

    func makeNSView(context: Context) -> NSTextField { NSTextField() }

    func updateNSView(_ view: NSTextField, context: Context) {
        view.stringValue = draft
        let countBinding = $count
        let draftBinding = $draft
        driver.snapshot = MotionStateSnapshot(
            identity: identity, count: count, draft: draft, value: driver.value, reduced: driver.reduced,
            hasAnimation: context.transaction.animation != nil,
            disablesAnimations: context.transaction.disablesAnimations,
            seed: { count, draft in
                countBinding.wrappedValue = count
                draftBinding.wrappedValue = draft
            })
    }
}
