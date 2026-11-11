import Foundation

/// Keeps platform resources alive until their cleanup runs on the UI executor.
/// Uses an ordinary destructor: older runtimes can fail in the back-deployment path for
/// `isolated deinit`, including when the last reference is released by a Dispatch callback.
/// State must not retain its owner. Only the owner and this cleanup closure may access it.
final class MainActorLifetime<State: AnyObject & Sendable>: Sendable {
    let state: State
    private let cleanup: @MainActor @Sendable (State) -> Void

    @MainActor
    init(_ state: State, cleanup: @escaping @MainActor @Sendable (State) -> Void) {
        self.state = state
        self.cleanup = cleanup
    }

    deinit {
        let state = state, cleanup = cleanup
        if Thread.isMainThread {
            MainActor.assumeIsolated { cleanup(state) }
        } else {
            DispatchQueue.main.async { cleanup(state) }
        }
    }
}
