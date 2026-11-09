import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut via Carbon RegisterEventHotKey (works without Accessibility permission).
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) {
        id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1
        GlobalHotKey.installHandlerOnce()
        GlobalHotKey.handlers[id] = handler

        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        let hkID = EventHotKeyID(signature: OSType(0x5052_4348) /* PRCH */, id: id)
        let status = RegisterEventHotKey(keyCode, carbon, hkID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        GlobalHotKey.handlers[id] = nil
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
