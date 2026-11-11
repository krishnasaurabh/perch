import AppKit

/// Ordinary movement uses NSEvent monitors. Poll only while another app owns an active drag.
@MainActor
final class DragPointerObservation {
    static let interval: TimeInterval = 1.0 / 15
    static let maximumSilence: TimeInterval = 120
    private let scheduler: any AppScheduling
    private let now: () -> Date
    private let pressed: () -> Bool
    private let sample: () -> Void
    private var deadline: Date?
    @MainActor
    private final class LifetimeState {
        var work: (any AppScheduledAction)?
    }
    private let lifetimeState = MainActorLifetime(LifetimeState()) { state in
        state.work?.cancel()
    }
    private var work: (any AppScheduledAction)? {
        get { lifetimeState.state.work }
        set { lifetimeState.state.work = newValue }
    }
    private(set) var samples = 0

    init(
        scheduler: any AppScheduling = MainQueueScheduler(), now: @escaping () -> Date = Date.init,
        pressed: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }, sample: @escaping () -> Void
    ) {
        self.scheduler = scheduler; self.now = now; self.pressed = pressed; self.sample = sample
    }

    func begin() {
        deadline = now().addingTimeInterval(Self.maximumSilence)
        if work == nil { schedule() }
    }

    func stop() {
        work?.cancel(); work = nil; deadline = nil
    }

    private func schedule() {
        work = scheduler.schedule(after: Self.interval) { [weak self] in
            guard let self else { return }
            self.work = nil
            guard self.pressed(), self.deadline.map({ self.now() < $0 }) == true else {
                self.stop(); return
            }
            self.samples += 1
            self.sample()
            self.schedule()
        }
    }
}
