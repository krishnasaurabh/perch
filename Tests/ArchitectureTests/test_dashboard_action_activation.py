"""Execute actual action routing against an eager native-button substitute.

This verifies event provenance and the destructive-action guard on Linux, not
AppKit dispatch. The unchanged DashboardKeyLoopTests cover real native events.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/PerchApp/Settings/DashboardView.swift"


def method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


class DashboardActionActivationTests(unittest.TestCase):
    def test_native_equivalent_carries_its_event_to_the_action_guard(self):
        source = SOURCE.read_text().split("final class DashboardProjectActionView: NSButton", 1)[1]
        # Keep the real handlers and guard. Strip only probe-only logging and
        # Objective-C exposure, which the Linux compiler cannot implement.
        methods = []
        signatures = [
            "override func keyDown(with event: NSEvent)",
            "override func keyUp(with event: NSEvent)",
            "override func mouseDown(with event: NSEvent)",
            "override func accessibilityPerformPress()",
            "@objc private func activateProjectAction(_ sender: Any?)",
        ]
        for optional in (
            "override func performKeyEquivalent(with event: NSEvent)",
            "private func withActivationEvent<T>",
        ):
            if optional in source:
                signatures.append(optional)
        for signature in signatures:
            body = method(source, signature)
            body = re.sub(r"\s*#if DASHBOARD_KEYBOARD_PROBE.*?#endif", "", body, flags=re.S)
            body = body.replace("@objc private func", "func")
            methods.append(body)
        event_property = "private var activationEvent: NSEvent?" if "private var activationEvent: NSEvent?" in source else ""
        program = r'''
import Foundation

final class NSEvent {
    enum EventType { case keyDown, keyUp, leftMouseDown }
    struct ModifierFlags: OptionSet {
        let rawValue: Int
        static let command = Self(rawValue: 1)
        static let control = Self(rawValue: 2)
        static let option = Self(rawValue: 4)
        static let shift = Self(rawValue: 8)
    }
    let type: EventType
    let keyCode: UInt16
    let modifierFlags: ModifierFlags
    let isARepeat: Bool
    let window: Window?
    init(_ type: EventType = .keyDown, code: UInt16 = 49,
         flags: Int = 0, repeatKey: Bool = false, window: Window?) {
        self.type = type
        keyCode = code
        modifierFlags = ModifierFlags(rawValue: flags)
        isARepeat = repeatKey
        self.window = window
    }
}
final class Window {
    var isKeyWindow = true
    var firstResponder: NSButton?
    func selectPreviousKeyView(_ sender: NSButton) {}
    func selectNextKeyView(_ sender: NSButton) {}
}
class NSButton {
    var window: Window?
    var acceptsFirstResponder = true
    var onClick: () -> Void = {}
    func performClick(_ sender: Any?) { onClick() }
    func keyDown(with event: NSEvent) {}
    func keyUp(with event: NSEvent) {}
    // Deliberately emulate a native equivalent that bypasses keyDown and
    // invokes target/action even for modified Space. The action must refuse.
    func performKeyEquivalent(with event: NSEvent) -> Bool {
        performClick(nil)
        return true
    }
    func mouseDown(with event: NSEvent) { performClick(nil) }
    func accessibilityPerformPress() -> Bool { false }
}
final class ActionView: NSButton {
    var onAction: () -> Void = {}
    var pressChanged: (Bool) -> Void = { _ in }
''' + event_property + "\n" + "\n".join(methods) + r'''
}

let window = Window()
let button = ActionView()
button.window = window
window.firstResponder = button
var actions = 0
button.onAction = { actions += 1 }
button.onClick = { button.activateProjectAction(nil) }
func expect(_ count: Int, _ label: String) {
    guard actions == count else {
        fatalError("\(label): \(actions) != \(count)")
    }
    print("PASS: \(label)")
}
button.keyDown(with: NSEvent(window: window))
expect(1, "plain Space activates")
button.keyDown(with: NSEvent(repeatKey: true, window: window))
expect(1, "held Space does not repeat")
for mask in 1..<16 {
    for phase in [NSEvent.EventType.keyDown, .keyUp] {
        _ = button.performKeyEquivalent(with: NSEvent(phase, flags: mask, window: window))
        expect(1, "modified native equivalent \(mask) \(phase) is rejected at action")
    }
}
_ = button.performKeyEquivalent(with: NSEvent(repeatKey: true, window: window))
expect(1, "native equivalent cannot repeat")
_ = button.performKeyEquivalent(with: NSEvent(.keyUp, window: window))
expect(1, "native equivalent cannot activate on release")
_ = button.performKeyEquivalent(with: NSEvent(window: Window()))
expect(1, "wrong window cannot activate")
window.isKeyWindow = false
_ = button.performKeyEquivalent(with: NSEvent(window: window))
expect(1, "inactive window cannot activate")
window.isKeyWindow = true
window.firstResponder = NSButton()
_ = button.performKeyEquivalent(with: NSEvent(window: window))
expect(1, "unfocused native equivalent cannot activate")
window.firstResponder = button
_ = button.performKeyEquivalent(with: NSEvent(window: window))
expect(2, "plain native equivalent still activates")
button.performClick(nil)
expect(3, "programmatic click remains supported")
_ = button.accessibilityPerformPress()
expect(4, "accessibility press still activates")
button.mouseDown(with: NSEvent(.leftMouseDown, flags: 1, window: window))
expect(5, "pointer press is not a keyboard equivalent")
button.acceptsFirstResponder = false
_ = button.performKeyEquivalent(with: NSEvent(window: window))
button.performClick(nil)
assert(!button.accessibilityPerformPress())
expect(5, "disabled actions are rejected")
button.acceptsFirstResponder = true
button.window = nil
_ = button.performKeyEquivalent(with: NSEvent(window: window))
button.performClick(nil)
assert(!button.accessibilityPerformPress())
expect(5, "detached actions are rejected")
button.window = window
// A nested native invocation must not erase the outer event context.
button.onAction = {
    actions += 1
    _ = button.performKeyEquivalent(with: NSEvent(flags: 4, window: window))
}
button.keyDown(with: NSEvent(window: window))
expect(6, "nested modified equivalent is rejected")
button.onAction = { actions += 1 }
button.performClick(nil)
expect(7, "event context is restored after dispatch")
'''
        swift = shutil.which("swift")
        self.assertIsNotNone(swift, "Swift is required for the action routing adapter")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "action.swift"
            path.write_text(program)
            result = subprocess.run([swift, str(path)], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: event context is restored after dispatch", result.stdout)


if __name__ == "__main__":
    unittest.main()
