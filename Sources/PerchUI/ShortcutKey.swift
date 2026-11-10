import Foundation
import PlannerCore

// The shortcut model is plain Swift on purpose: no AppKit, no Carbon, so its rules are unit-testable off-device.

/// The modifier keys held for a shortcut, in the order macOS prints them.
public struct ShortcutModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)
    public static let all: ShortcutModifiers = [.control, .option, .shift, .command]

    /// Reads `NSEvent.ModifierFlags` device-independent bits without importing AppKit.
    /// Bits: capsLock 1<<16, shift 1<<17, control 1<<18, option 1<<19, command 1<<20, function 1<<23.
    public init(flagBits: UInt) {
        var m: ShortcutModifiers = []
        if flagBits & (1 << 20) != 0 { m.insert(.command) }
        if flagBits & (1 << 19) != 0 { m.insert(.option) }
        if flagBits & (1 << 18) != 0 { m.insert(.control) }
        if flagBits & (1 << 17) != 0 { m.insert(.shift) }
        self = m
    }

    private static let ordered: [ShortcutModifiers] = [.control, .option, .shift, .command]
    private static let symbols: [(ShortcutModifiers, String)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]

    /// Persisted as one integer, with unknown bits masked off on the way back in: a newer build's flags cannot
    /// turn into a modifier this one doesn't understand.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = ShortcutModifiers(rawValue: raw & ShortcutModifiers.all.rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var count: Int { ShortcutModifiers.ordered.filter { contains($0) }.count }

    /// "⌃⌥⇧⌘", in the order macOS shows modifiers.
    public var display: String {
        var s = ""
        for (flag, symbol) in ShortcutModifiers.symbols where contains(flag) { s += symbol }
        return s
    }
}

/// One system-wide hot key: a virtual key code plus the modifiers that must be held.
public struct ShortcutKey: Equatable, Codable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ShortcutModifiers

    /// ⌥N, the shortcut Perch has always used.
    public static let `default` = ShortcutKey(keyCode: 45, modifiers: [.option])

    /// Escape cancels recording in Settings, so it can never be the shortcut itself.
    public static let escapeKeyCode: UInt32 = 53

    public init(keyCode: UInt32, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The key's name, or nil for a key code Perch doesn't know (modifier keys, unknown hardware).
    public var name: String? { ShortcutKey.names[keyCode] }

    public var isValid: Bool { !modifiers.isEmpty && keyCode != ShortcutKey.escapeKeyCode && name != nil }

    public var display: String { modifiers.display + (name ?? "?") }

    /// Anything unusable (corrupt defaults, a stale key code) falls back to ⌥N rather than leaving no hot key.
    public static func validated(_ key: ShortcutKey?) -> ShortcutKey {
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
