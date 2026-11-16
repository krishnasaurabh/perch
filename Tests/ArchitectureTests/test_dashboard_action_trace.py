"""Probe-only action diagnostics; substitute events do not verify AppKit dispatch."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/PerchApp/Settings/DashboardView.swift"


class DashboardActionTraceTests(unittest.TestCase):
    def test_action_and_space_entries_trace_before_dispatch_or_rejection(self):
        source = SOURCE.read_text()
        for signature, invocation in (
            ('override func keyDown(with event: NSEvent)', 'traceProjectAction("keyDown", event: event)'),
            ('override func keyUp(with event: NSEvent)', 'traceProjectAction("keyUp", event: event)'),
            ('@objc private func activateProjectAction(_ sender: Any?)', 'traceProjectAction("activateProjectAction")'),
        ):
            body = source.split(signature, 1)[1]
            prefix = body.split('#endif', 1)[0]
            self.assertIn('#if DASHBOARD_KEYBOARD_PROBE', prefix)
            self.assertIn(invocation, prefix)
            self.assertNotIn('performClick(', prefix)
            self.assertNotIn('onAction()', prefix)
            self.assertNotIn('super.', prefix)
            if 'event:' in invocation:
                self.assertIn('if event.keyCode == 49', prefix)
        self.assertRegex(source, r'#if DASHBOARD_KEYBOARD_PROBE\s+private func traceProjectAction')

    def test_trace_is_synchronous_and_includes_caller_and_event_context(self):
        source = SOURCE.read_text()
        helper = source.split('private func traceProjectAction', 1)[1].split('#endif', 1)[0]
        for value in (
            'Thread.callStackSymbols.joined(separator: " | ")', 'ObjectIdentifier(self)',
            'NSApp.currentEvent', 'window?.firstResponder', 'accessibilityIdentifier()',
            'event.type.rawValue', 'event.keyCode', 'event.modifierFlags.rawValue',
            'FileHandle.standardError.write',
        ):
            self.assertIn(value, helper)
        for value in ('DispatchQueue', 'Task {', 'print(', 'onAction()', 'performClick(', 'sleep'):
            self.assertNotIn(value, helper)

    def test_real_trace_helper_handles_absent_and_nonkeyboard_current_events(self):
        source = SOURCE.read_text()
        helper = 'private func traceProjectAction' + source.split(
            'private func traceProjectAction', 1)[1].split('#endif', 1)[0]
        program = r'''
import Foundation

final class NSEvent {
    enum EventType: Int { case keyDown = 10, keyUp = 11, flagsChanged = 12, leftMouseDown = 1 }
    struct ModifierFlags: OptionSet { let rawValue: UInt }
    let type: EventType
    let modifierFlags: ModifierFlags
    private let code: UInt16
    var keyCode: UInt16 {
        precondition(type != .leftMouseDown, "Mouse events have no key code")
        return code
    }
    init(_ type: EventType, _ code: UInt16 = 49, _ flags: UInt = 0) {
        self.type = type
        self.code = code
        self.modifierFlags = ModifierFlags(rawValue: flags)
    }
}
class NSView: NSObject {
    func accessibilityIdentifier() -> String? { "synthetic-delete-target" }
}
final class Window { var firstResponder: NSObject? }
@MainActor final class Application { var currentEvent: NSEvent? }
@MainActor enum Harness { static let app = Application() }
@MainActor var NSApp: Application { Harness.app }
@MainActor final class TraceTarget {
    var window: Window?
''' + helper + r'''
    func exercise() {
        traceProjectAction("absent")
        window = Window()
        window?.firstResponder = NSView()
        let down = NSEvent(.keyDown, 49, 1048576)
        NSApp.currentEvent = down
        traceProjectAction("down", event: down)
        NSApp.currentEvent = NSEvent(.leftMouseDown)
        traceProjectAction("up", event: NSEvent(.keyUp, 49, 1048576))
    }
}
MainActor.assumeIsolated { TraceTarget().exercise() }
'''
        swift = shutil.which('swift')
        if swift is None:
            self.fail('Swift is required for the trace adapter control')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'trace.swift'
            path.write_text(program)
            result = subprocess.run([swift, str(path)], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = result.stderr.splitlines()
        self.assertEqual(len(lines), 3, result.stderr)
        self.assertIn('absent', lines[0])
        self.assertIn('event=nil currentEvent=nil responder=nil responderIdentifier=nil', lines[0])
        self.assertIn('event=type=10,keyCode=49,modifiers=1048576', lines[1])
        self.assertIn('currentEvent=type=10,keyCode=49,modifiers=1048576', lines[1])
        self.assertIn('event=type=11,keyCode=49,modifiers=1048576', lines[2])
        self.assertIn('currentEvent=type=1,keyCode=not-key,modifiers=0', lines[2])
        self.assertIn('responder=NSView responderIdentifier=synthetic-delete-target', lines[1])
        for line in lines:
            self.assertRegex(line, r'instance=ObjectIdentifier\(0x[0-9a-f]+\)')
            self.assertRegex(line, r'stack=.+ \| .+')
        self.assertEqual(len(set(re.findall(r'instance=(ObjectIdentifier\(.*?\))', result.stderr))), 1)


if __name__ == '__main__':
    unittest.main()
