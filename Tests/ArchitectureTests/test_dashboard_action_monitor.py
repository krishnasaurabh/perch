"""Exercise the actual pre-dispatch guard with a portable event-monitor adapter.

This checks registration, event identity, scope and filtering, not AppKit event
routing. DashboardKeyLoopTests remains the unchanged native acceptance gate.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/PerchApp/Settings/DashboardView.swift"


def method(source, signature):
    if signature not in source:
        return ""
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


class DashboardActionMonitorTests(unittest.TestCase):
    def test_key_loop_installs_predispatch_guard(self):
        source = SOURCE.read_text()
        install = method(source, "static func install(in window: NSWindow)")
        self.assertIn("installProjectActionMonitor()", install)

    def test_actual_monitor_scope_event_identity_and_swift6_isolation(self):
        source = SOURCE.read_text().split("enum DashboardKeyLoop {", 1)[1]
        registration = method(source, "private static func installProjectActionMonitor()")
        handler = method(source, "private static func handleProjectActionKey(_ event: NSEvent)")
        descendants = method(source, "private static func descendants(_ root: NSView)")
        # Expose only the installer to this adapter. The predicate and closure
        # run unchanged, including the Sendable-safe MainActor handoff.
        registration = registration.replace("private static func", "static func", 1)
        if not registration:
            registration = "static func installProjectActionMonitor() {}"
        program = r'''
import Foundation

final class NSEvent {
    enum EventType: Int { case keyDown = 10, keyUp = 11, applicationDefined = 13, leftMouseDown = 1 }
    struct EventTypeMask: OptionSet, Sendable {
        let rawValue: Int
        static let keyDown = Self(rawValue: 1)
    }
    struct ModifierFlags: OptionSet, Sendable {
        let rawValue: Int
        static let command = Self(rawValue: 1)
        static let control = Self(rawValue: 2)
        static let option = Self(rawValue: 4)
        static let shift = Self(rawValue: 8)
    }
    @MainActor static var registrations = 0
    @MainActor static var monitor: ((NSEvent) -> NSEvent?)?
    @MainActor static func addLocalMonitorForEvents(
        matching mask: EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?
    ) -> Any? {
        precondition(mask == .keyDown)
        registrations += 1
        monitor = handler
        return NSObject()
    }
    let type: EventType
    let modifierFlags: ModifierFlags
    let isARepeat: Bool
    let window: NSWindow?
    private let code: UInt16
    var keyCode: UInt16 {
        precondition(type == .keyDown || type == .keyUp, "Do not read non-key keyCode")
        return code
    }
    init(_ type: EventType = .keyDown, code: UInt16 = 49, flags: Int = 0,
         repeats: Bool = false, window: NSWindow?) {
        self.type = type
        self.code = code
        modifierFlags = ModifierFlags(rawValue: flags)
        isARepeat = repeats
        self.window = window
    }
}
@MainActor class NSView {
    weak var window: NSWindow?
    weak var superview: NSView?
    var subviews: [NSView] = []
    func addSubview(_ view: NSView) {
        view.superview = self
        view.window = window
        subviews.append(view)
    }
    func isDescendant(of ancestor: NSView) -> Bool {
        self === ancestor || superview?.isDescendant(of: ancestor) == true
    }
}
@MainActor final class NSWindow {
    var isKeyWindow = true
    var firstResponder: AnyObject?
    var contentView: NSView?
}
@MainActor final class DashboardSelection {
    enum Tab { case projects, history, yourWeek }
    var tab: Tab = .projects
}
@MainActor final class DashboardTabsHost: NSView {
    var selectionState: DashboardSelection? = DashboardSelection()
}
@MainActor final class DashboardProjectActionView: NSView {
    var acceptsFirstResponder = true
    func accessibilityIdentifier() -> String? { "dashboard-project-delete" }
}
@MainActor enum DashboardKeyLoop {
    private static var projectActionMonitor: Any?
''' + registration + "\n" + handler + "\n" + descendants + r'''
}
let window = NSWindow()
let root = NSView()
root.window = window
window.contentView = root
let host = DashboardTabsHost()
root.addSubview(host)
let action = DashboardProjectActionView()
root.addSubview(action)
window.firstResponder = action
DashboardKeyLoop.installProjectActionMonitor()
DashboardKeyLoop.installProjectActionMonitor()
precondition(NSEvent.registrations == 1, "Install exactly one app-lifetime monitor")
var swallowed = 0
@MainActor func check(_ event: NSEvent, swallow: Bool, _ label: String) {
    let result = NSEvent.monitor?(event)
    if swallow {
        precondition(result == nil, label)
        swallowed += 1
    } else {
        precondition(result === event, "Forward the exact original event: \(label)")
    }
}
// All modifier combinations, including Shift with another modifier; plain
// Shift is outside this monitor and remains subject to the existing key guard.
for mask in 0..<16 {
    for repeats in [false, true] {
        check(NSEvent(flags: mask, repeats: repeats, window: window),
              swallow: mask & 7 != 0 || repeats, "mask \(mask), repeat \(repeats)")
    }
}
let blocked = NSEvent(flags: 1, window: window)
let child = NSView()
action.addSubview(child)
window.firstResponder = child
check(blocked, swallow: true, "descendant of project action")
window.firstResponder = action
for phase in [NSEvent.EventType.keyUp, .applicationDefined, .leftMouseDown] {
    check(NSEvent(phase, flags: 1, repeats: true, window: window), swallow: false, "non-key-down")
}
check(NSEvent(code: 48, flags: 1, repeats: true, window: window), swallow: false, "other key")
check(NSEvent(flags: 1, window: nil), swallow: false, "no window")
check(NSEvent(flags: 1, window: NSWindow()), swallow: false, "other window")
window.isKeyWindow = false
check(blocked, swallow: false, "inactive window")
window.isKeyWindow = true
window.firstResponder = nil
check(blocked, swallow: false, "no responder")
window.firstResponder = NSView()
check(blocked, swallow: false, "unrelated view")
window.firstResponder = NSObject()
check(blocked, swallow: false, "non-view responder")
window.firstResponder = host
check(blocked, swallow: false, "tab strip")
window.firstResponder = action
for tab in [DashboardSelection.Tab.history, .yourWeek] {
    host.selectionState?.tab = tab
    check(blocked, swallow: false, "different page")
}
host.selectionState = nil
check(blocked, swallow: false, "missing page model")
host.selectionState = DashboardSelection()
action.acceptsFirstResponder = false
check(blocked, swallow: false, "disabled or hidden action")
action.acceptsFirstResponder = true
action.window = nil
check(blocked, swallow: false, "detached action")
action.window = window
action.superview = nil
check(blocked, swallow: false, "action outside root")
action.superview = root
window.contentView = nil
check(blocked, swallow: false, "no root")
window.contentView = root
root.subviews.removeFirst()
check(blocked, swallow: false, "no dashboard host")
root.addSubview(host)
check(blocked, swallow: true, "restored dashboard")
print("PASS: scoped monitor, identity, one registration; swallowed=\(swallowed)")
'''
        swiftc = shutil.which("swiftc")
        assert swiftc is not None, "Swift is required for the monitor adapter"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "monitor.swift"
            binary = Path(directory) / "monitor"
            path.write_text(program)
            compiled = subprocess.run(
                [swiftc, "-swift-version", "6", "-DDASHBOARD_KEYBOARD_PROBE", str(path), "-o", str(binary)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: scoped monitor, identity, one registration; swallowed=32", result.stdout)
        trace_lines = result.stderr.splitlines()
        self.assertEqual(len(trace_lines), 32, result.stderr)
        for line in trace_lines:
            self.assertIn("TRACE: DashboardKeyLoop swallowed", line)
            for field in ("type=10", "keyCode=49", "modifiers=", "isARepeat=",
                          "responderIdentifier=dashboard-project-delete"):
                self.assertIn(field, line)


if __name__ == "__main__":
    unittest.main()
