import AppKit
import ApplicationServices

/// Workspace and AX notifications trigger scans. No permission prompt is requested.
/// A metadata-only permission check selects a bounded recovery cadence for unsupported clients.
@MainActor
final class FullscreenObservation {
    private let changed: @MainActor () -> Void
    @MainActor
    private final class CallbackContext {
        weak var owner: FullscreenObservation?
        init(_ owner: FullscreenObservation) { self.owner = owner }
    }
    @MainActor
    private final class LifetimeState {
        var tokens: [NSObjectProtocol] = []
        var observer: AXObserver?
        var callbackContext: CallbackContext?
        var registrations: [(AXUIElement, CFString)] = []
        var timer: Timer?
        var delivery: DispatchWorkItem?
    }
    private let lifetimeState = MainActorLifetime(LifetimeState()) { state in
        state.timer?.invalidate(); state.delivery?.cancel()
        for token in state.tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        if let observer = state.observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            for (element, name) in state.registrations { AXObserverRemoveNotification(observer, element, name) }
        }
    }
    private var tokens: [NSObjectProtocol] {
        get { lifetimeState.state.tokens }
        set { lifetimeState.state.tokens = newValue }
    }
    private var observer: AXObserver? {
        get { lifetimeState.state.observer }
        set { lifetimeState.state.observer = newValue }
    }
    private var registrations: [(AXUIElement, CFString)] {
        get { lifetimeState.state.registrations }
        set { lifetimeState.state.registrations = newValue }
    }
    private var timer: Timer? {
        get { lifetimeState.state.timer }
        set { lifetimeState.state.timer = newValue }
    }
    private var delivery: DispatchWorkItem? {
        get { lifetimeState.state.delivery }
        set { lifetimeState.state.delivery = newValue }
    }
    private(set) var recoveryInterval: TimeInterval = 5

    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification,
        ] {
            tokens.append(
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor in
                        self?.refreshApplication(); self?.signal()
                    }
                })
        }
        refreshApplication()
    }

    func refreshApplication() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            for (element, name) in registrations { AXObserverRemoveNotification(observer, element, name) }
        }
        registrations = []; observer = nil
        lifetimeState.state.callbackContext = nil
        if AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication {
            var created: AXObserver?
            let callback: AXObserverCallback = { _, _, _, context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    let context = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
                    context.owner?.signal()
                }
            }
            if AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created {
                observer = created
                lifetimeState.state.callbackContext = CallbackContext(self)
                let element = AXUIElementCreateApplication(app.processIdentifier)
                for name in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
                    register(element, name as CFString)
                }
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                    let windows = value as? [AXUIElement]
                {
                    for window in windows {
                        for name in [
                            kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
                            kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                        ] {
                            register(window, name as CFString)
                        }
                    }
                }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
            }
        }
        recoveryInterval = Self.recoveryCadence(registeredNotifications: registrations.count)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: recoveryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshApplication(); self?.changed()
            }
        }
        timer?.tolerance = recoveryInterval / 5
    }

    static func recoveryCadence(registeredNotifications: Int) -> TimeInterval {
        registeredNotifications == 0 ? 5 : 30
    }

    private func register(_ element: AXUIElement, _ name: CFString) {
        guard let observer, let context = lifetimeState.state.callbackContext else { return }
        // The context outlives the owner until main-queue cleanup removes the observer.
        if AXObserverAddNotification(observer, element, name, Unmanaged.passUnretained(context).toOpaque()) == .success
        {
            registrations.append((element, name))
        }
    }

    private func signal() {
        guard delivery == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delivery = nil
                self.refreshApplication()
                self.changed()
            }
        }
        delivery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}
