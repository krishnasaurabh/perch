import AppKit
import Carbon.HIToolbox
import Foundation

// MARK: - PURE-BEGIN
// The shortcut model is plain Swift on purpose: no AppKit, no Carbon, so its rules are unit-testable off-device.

/// The modifier keys held for a shortcut, in the order macOS prints them.
struct ShortcutModifiers: OptionSet, Hashable, Codable, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let control = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let shift = ShortcutModifiers(rawValue: 1 << 2)
    static let command = ShortcutModifiers(rawValue: 1 << 3)
    static let all: ShortcutModifiers = [.control, .option, .shift, .command]

    /// Reads `NSEvent.ModifierFlags` device-independent bits without importing AppKit.
    /// Bits: capsLock 1<<16, shift 1<<17, control 1<<18, option 1<<19, command 1<<20, function 1<<23.
    init(flagBits: UInt) {
        var m: ShortcutModifiers = []
        if flagBits & (1 << 20) != 0 { m.insert(.command) }
        if flagBits & (1 << 19) != 0 { m.insert(.option) }
        if flagBits & (1 << 18) != 0 { m.insert(.control) }
        if flagBits & (1 << 17) != 0 { m.insert(.shift) }
        self = m
    }

    private static let ordered: [ShortcutModifiers] = [.control, .option, .shift, .command]
    private static let symbols: [(ShortcutModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]

    /// Persisted as one integer, with unknown bits masked off on the way back in: a newer build's flags cannot
    /// turn into a modifier this one doesn't understand.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = ShortcutModifiers(rawValue: raw & ShortcutModifiers.all.rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    var count: Int { ShortcutModifiers.ordered.filter { contains($0) }.count }

    /// "⌃⌥⇧⌘", in the order macOS shows modifiers.
    var display: String {
        var s = ""
        for (flag, symbol) in ShortcutModifiers.symbols where contains(flag) { s += symbol }
        return s
    }
}

/// One system-wide hot key: a virtual key code plus the modifiers that must be held.
struct ShortcutKey: Equatable, Codable, Sendable {
    var keyCode: UInt32
    var modifiers: ShortcutModifiers

    /// ⌥N, the shortcut Perch has always used.
    static let `default` = ShortcutKey(keyCode: 45, modifiers: [.option])

    /// Escape cancels recording in Settings, so it can never be the shortcut itself.
    static let escapeKeyCode: UInt32 = 53

    init(keyCode: UInt32, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The key's name, or nil for a key code Perch doesn't know (modifier keys, unknown hardware).
    var name: String? { ShortcutKey.names[keyCode] }

    var isValid: Bool { !modifiers.isEmpty && keyCode != ShortcutKey.escapeKeyCode && name != nil }

    var display: String { modifiers.display + (name ?? "?") }

    /// Anything unusable (corrupt defaults, a stale key code) falls back to ⌥N rather than leaving no hot key.
    static func validated(_ key: ShortcutKey?) -> ShortcutKey {
        guard let key, key.isValid else { return .default }
        return key
    }

    /// Carbon virtual key codes, so the table stays identical to what RegisterEventHotKey receives.
    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete",
        53: "Escape", 65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/", 76: "Enter", 78: "-", 81: "=",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13",
        107: "F14", 109: "F10", 111: "F12", 113: "F15", 115: "Home", 116: "Page Up", 117: "Forward Delete",
        118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
// MARK: - PURE-END

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
           saved.isValid {
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

        changeObserver = NotificationCenter.default.addObserver(forName: ShortcutStore.didChange, object: nil, queue: .main) { [weak self] note in
            guard let self, let key = note.userInfo?["key"] as? ShortcutKey else { return }
            self.apply(key)
        }
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        unregister()
        GlobalHotKey.handlers[id] = nil
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
        NotificationCenter.default.post(name: ShortcutStore.didFail, object: nil,
                                        userInfo: ["key": key, "restored": previous])
    }

    private func register(_ key: ShortcutKey) -> Bool {
        guard key.isValid else { return false }
        unregister()
        var newRef: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5052_4348) /* PRCH */, id: id)
        let status = RegisterEventHotKey(key.keyCode, key.modifiers.carbon, hkID, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return false }
        ref = newRef
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
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { GlobalHotKey.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
