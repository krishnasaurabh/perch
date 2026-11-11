import Foundation
import XCTest
@testable import PerchApp

@MainActor
private final class LifetimeProbeState {
    var calls = 0
    var child: MainActorLifetime<LifetimeProbeState>?
}

final class MainActorLifetimeTests: XCTestCase {
    @MainActor
    func testMainThreadCleanupIsSynchronousAndRunsOnce() async {
        let state = LifetimeProbeState()
        var lifetime: MainActorLifetime<LifetimeProbeState>? = MainActorLifetime(state) { state in state.calls += 1 }
        weak var weakLifetime = lifetime
        lifetime = nil
        XCTAssertNil(weakLifetime)
        XCTAssertEqual(state.calls, 1)
    }

    func testFinalReleaseOnDispatchQueueCleansUpOnMainActor() async {
        let finished = expectation(description: "cleanup on main actor")
        let gate = DispatchSemaphore(value: 0)
        await MainActor.run {
            let state = LifetimeProbeState()
            let lifetime = MainActorLifetime(state) { state in
                XCTAssertTrue(Thread.isMainThread)
                state.calls += 1
                XCTAssertEqual(state.calls, 1)
                finished.fulfill()
            }
            DispatchQueue.global().async {
                gate.wait()
                withExtendedLifetime(lifetime) {}
            }
        }
        // The MainActor scope has dropped its reference before the background queue releases the last one.
        gate.signal()
        await fulfillment(of: [finished], timeout: 3)
    }

    @MainActor
    func testNestedCleanupDoesNotEnterIsolatedDeinitRuntime() async {
        let parent = LifetimeProbeState()
        let child = LifetimeProbeState()
        parent.child = MainActorLifetime(child) { $0.calls += 1 }
        var lifetime: MainActorLifetime<LifetimeProbeState>? = MainActorLifetime(parent) { state in
            state.calls += 1
            state.child = nil
        }
        XCTAssertNotNil(lifetime)
        lifetime = nil
        XCTAssertEqual(parent.calls, 1)
        XCTAssertEqual(child.calls, 1)
    }
}
