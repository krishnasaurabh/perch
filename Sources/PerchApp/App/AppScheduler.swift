import Foundation

/// A cancellable delayed UI action. Tests can advance a scheduler without sleeping.
protocol AppScheduledAction {
    func cancel()
}

@MainActor
protocol AppScheduling {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any AppScheduledAction
}

@MainActor
struct MainQueueScheduler: AppScheduling {
    nonisolated init() {}
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any AppScheduledAction {
        let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }
}

extension DispatchWorkItem: AppScheduledAction {}
