import AppKit
import ApplicationServices

/// Workspace and AX notifications trigger scans. No permission prompt is requested.
/// A metadata-only permission check selects a bounded recovery cadence for unsupported clients.
@MainActor
final class FullscreenObservation {
    private let changed: @MainActor () -> Void
    private var tokens: [NSObjectProtocol] = []
    private var observer: AXObserver?
    private var registrations: [(AXUIElement, CFString)] = []
    private var timer: Timer?
    private var delivery: DispatchWorkItem?
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

    deinit {
        timer?.invalidate(); delivery?.cancel()
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            for (element, name) in registrations { AXObserverRemoveNotification(observer, element, name) }
        }
    }

    func refreshApplication() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            for (element, name) in registrations { AXObserverRemoveNotification(observer, element, name) }
        }
        registrations = []; observer = nil
        if AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication {
            var created: AXObserver?
            let callback: AXObserverCallback = { _, _, _, context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    let owner = Unmanaged<FullscreenObservation>.fromOpaque(context).takeUnretainedValue()
                    owner.signal()
                }
            }
            if AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created {
                observer = created
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
        recoveryInterval = registrations.isEmpty ? 5 : 30
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: recoveryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshApplication(); self?.changed()
            }
        }
        timer?.tolerance = recoveryInterval / 5
    }

    private func register(_ element: AXUIElement, _ name: CFString) {
        guard let observer else { return }
        if AXObserverAddNotification(observer, element, name, Unmanaged.passUnretained(self).toOpaque()) == .success {
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
