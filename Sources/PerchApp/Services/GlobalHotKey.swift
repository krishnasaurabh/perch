import AppKit
import Carbon.HIToolbox
import Foundation

import PerchUI

// MARK: - AppKit and Carbon bridging

extension ShortcutModifiers {
    /// Carbon's modifier mask, built from Carbon's own constants so the two can't drift.
    var carbon: UInt32 {
        var v: UInt32 = 0
        if contains(.command) { v |= UInt32(cmdKey) }
        if contains(.option) { v |= UInt32(optionKey) }
        if contains(.control) { v |= UInt32(controlKey) }
        if contains(.shift) { v |= UInt32(shiftKey) }
        return v
    }
}

extension ShortcutKey {
    /// The chord a key press represents, or nil when it can't be a shortcut (a bare key, a modifier press).
    init?(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), modifiers: ShortcutModifiers(flagBits: event.modifierFlags.rawValue))
        if !isValid { return nil }
    }
}

/// Where the chosen shortcut lives. Deliberately app preferences and not planner.json: an MCP client
/// can edit the planner, and a system-wide keyboard binding is not planner content.
enum ShortcutStore {
    static let defaultsKey = "PerchShortcutKey"
    /// Posted with `userInfo["key"]` after the user picks a new shortcut.
    static let didChange = Notification.Name("PerchShortcutDidChange")
    /// Posted with `userInfo["key"]` (the rejected choice) and `userInfo["restored"]` (what is live now).
    static let didFail = Notification.Name("PerchShortcutDidFail")

    /// Reads the saved shortcut, writing `fallback` once when nothing usable is stored.
    @discardableResult
    static func load(seeding fallback: ShortcutKey = .default, defaults: UserDefaults = .standard) -> ShortcutKey {
        if let data = defaults.data(forKey: defaultsKey),
            let saved = try? JSONDecoder().decode(ShortcutKey.self, from: data),
            saved.isValid
        {
            return saved
        }
        let seed = ShortcutKey.validated(fallback)
        save(seed, defaults: defaults, notify: false)
        return seed
    }

    static func save(_ key: ShortcutKey, defaults: UserDefaults = .standard, notify: Bool = true) {
        guard key.isValid, let data = try? JSONEncoder().encode(key) else { return }
        defaults.set(data, forKey: defaultsKey)
        if notify { NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["key": key]) }
    }
}

/// A system-wide shortcut via Carbon RegisterEventHotKey (works without Accessibility permission).
///
/// It owns the live registration, so a new choice in Settings re-registers the hot key in place instead of
/// needing a relaunch. The initializer keeps the call site's key as the fallback: if the saved shortcut is
/// unavailable at launch, Perch still gets a working hot key.
@MainActor
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var changeObserver: NSObjectProtocol?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1
    private let id: UInt32
    private(set) var shortcut: ShortcutKey = .default

    init?(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) {
        id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1
        GlobalHotKey.installHandlerOnce()

        let fallback = ShortcutKey(keyCode: keyCode, modifiers: ShortcutModifiers(flagBits: modifiers.rawValue))
        var initial = ShortcutStore.load(seeding: fallback)
        if !register(initial) {
            // The saved chord may be taken by another app now; a launch with no hot key would be worse.
            guard register(fallback) else { return nil }
            initial = fallback
            ShortcutStore.save(fallback, notify: false)
        }
        shortcut = initial
        GlobalHotKey.handlers[id] = handler

        changeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.didChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let key = note.userInfo?["key"] as? ShortcutKey else { return }
            MainActor.assumeIsolated { self.apply(key) }
        }
    }

    isolated deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        MainActor.assumeIsolated {
            unregister()
            GlobalHotKey.handlers[id] = nil
        }
    }

    /// Swaps the live hot key. On failure the previous chord is put back and Settings is told why.
    private func apply(_ key: ShortcutKey) {
        guard key != shortcut else { return }
        let previous = shortcut
        if register(key) {
            shortcut = key
            return
        }
        _ = register(previous)
        ShortcutStore.save(previous, notify: false)
        NotificationCenter.default.post(
            name: ShortcutStore.didFail, object: nil,
            userInfo: ["key": key, "restored": previous])
    }

    private func register(_ key: ShortcutKey) -> Bool {
        guard key.isValid else { return false }
        unregister()
        var newRef: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5052_4348) /* PRCH */, id: id)
        let status = RegisterEventHotKey(
            key.keyCode, key.modifiers.carbon, hkID, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else {
            PlatformLog.hotKey.error(
                "register failed id=\(self.id, privacy: .public) status=\(status, privacy: .public)")
            return false
        }
        ref = newRef
        PlatformLog.hotKey.debug("register succeeded id=\(self.id, privacy: .public)")
        return true
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                DispatchQueue.main.async { GlobalHotKey.handlers[hk.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        if status != noErr {
            PlatformLog.hotKey.error("install handler failed status=\(status, privacy: .public)")
        }
    }
}
