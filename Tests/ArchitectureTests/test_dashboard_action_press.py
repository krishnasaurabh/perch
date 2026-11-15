"""Exercise the actual press guard with a simulated in-flight event.

This adapter checks the Swift predicate and superclass forwarding, not AppKit's
cell dispatch. DashboardKeyLoopTests retains the native keyboard assertions.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/PerchApp/Settings/DashboardView.swift"


def press_override(source):
    signature = "override func performClick(_ sender: Any?)"
    if signature not in source:
        return ""  # The old control inherits NSButton's unconditional press.
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


class DashboardActionPressTests(unittest.TestCase):
    def test_inflight_space_is_filtered_without_an_activation_event(self):
        source = SOURCE.read_text().split("final class DashboardProjectActionView: NSButton", 1)[1]
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
    private let code: UInt16
    var keyCode: UInt16 {
        precondition(type != .leftMouseDown, "Never read a mouse event's keyCode")
        return code
    }
    let modifierFlags: ModifierFlags
    let isARepeat: Bool
    init(_ type: EventType = .keyDown, code: UInt16 = 49,
         flags: Int = 0, repeatKey: Bool = false) {
        self.type = type
        self.code = code
        modifierFlags = ModifierFlags(rawValue: flags)
        isARepeat = repeatKey
    }
}
enum NSApp { static var currentEvent: NSEvent? }
class NSButton {
    var forwarded = 0
    var lastSender: AnyObject?
    func performClick(_ sender: Any?) {
        forwarded += 1
        lastSender = sender as AnyObject?
    }
}
final class ActionView: NSButton {
''' + press_override(source) + r'''
}
let button = ActionView()
let sender = NSObject()
func check(_ event: NSEvent?, forwards: Bool, _ label: String) {
    NSApp.currentEvent = event
    let before = button.forwarded
    button.performClick(sender)
    precondition(button.forwarded == before + (forwards ? 1 : 0), label)
    if forwards { precondition(button.lastSender === sender, "Preserve the sender") }
    print("PASS: \(label)")
}
for mask in 1..<16 {
    for repeats in [false, true] {
        check(NSEvent(flags: mask, repeatKey: repeats), forwards: false,
              "modified in-flight Space \(mask), repeat \(repeats)")
    }
}
check(NSEvent(repeatKey: true), forwards: false, "plain repeated Space")
check(NSEvent(), forwards: true, "plain deliberate Space")
check(nil, forwards: true, "no in-flight event for programmatic or accessibility press")
check(NSEvent(.leftMouseDown, flags: 15, repeatKey: true), forwards: true,
      "mouse press is not keyboard activation")
check(NSEvent(code: 36, flags: 15, repeatKey: true), forwards: true,
      "non-Space key is outside this guard")
check(NSEvent(.keyUp, flags: 15, repeatKey: true), forwards: true,
      "release event is outside this press guard")
NSApp.currentEvent = nil
print("PASS: in-flight press guard and superclass forwarding")
'''
        swift = shutil.which("swift")
        assert swift is not None, "Swift is required for the press guard adapter"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "press.swift"
            path.write_text(program)
            result = subprocess.run([swift, str(path)], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: in-flight press guard and superclass forwarding", result.stdout)


if __name__ == "__main__":
    unittest.main()
