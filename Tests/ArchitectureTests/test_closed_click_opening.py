"""Run the production closed-activation method with data-only AppKit adapters.

This covers the routing decision and emitted notification, not native event delivery.
The macOS suite separately exercises the method with NSApplication events.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def declaration(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


class ClosedClickOpeningTests(unittest.TestCase):
    def test_closed_activation_obeys_click_preference_and_keeps_explicit_routes(self):
        source = (ROOT / "Sources/PerchApp/Notch/NotchGlanceCapsule.swift").read_text()
        activate = declaration(source, "func activateClosed(")
        trigger = declaration((ROOT / "Sources/PlannerCore/Models.swift").read_text(),
                              "public enum NotchOpenTrigger:")
        legacy_policy = declaration((ROOT / "Sources/PerchUI/NotchGlancePresentation.swift").read_text(),
                                    "public static func allowsActivation(")
        adapter = r'''
import Foundation
struct Preferences {
    var notchClickToOpen = true
    var notchOpenTrigger = NotchOpenTrigger.hover
}
struct NSEvent {
    enum EventType { case leftMouseDown, leftMouseUp, keyDown, keyUp }
    let type: EventType
    let clickCount: Int
}
@MainActor enum NSApp { static var currentEvent: NSEvent? }
struct PlannerStore { var prefs: Preferences }
struct NotchScreenState { let id: Int; let geometry: Int }
enum NotchPage: Sendable { case home }
extension Notification.Name { static let perchOpenWorkspace = Self("perchOpenWorkspace") }
@MainActor final class OpenRecorder {
    var pages: [NotchPage] = []
    func record(_ page: NotchPage) { pages.append(page) }
}
'''
        program = (adapter + trigger + "\nstruct NotchClosedPresentation {\n" + legacy_policy
                   + "\n}\n@MainActor final class NotchModel {\n"
                   + "var screenID = -1\nvar geometry: Int?\n" + activate + "\n}\n" + r'''
let recorder = OpenRecorder()
let observer = NotificationCenter.default.addObserver(forName: .perchOpenWorkspace,
                                                       object: nil, queue: nil) { note in
    precondition(note.name == .perchOpenWorkspace)
    let page = note.object as! NotchPage
    MainActor.assumeIsolated { recorder.record(page) }
}
defer { NotificationCenter.default.removeObserver(observer) }
var cases = 0
for trigger in NotchOpenTrigger.allCases {
    for enabled in [false, true] {
        let store = PlannerStore(prefs: Preferences(notchClickToOpen: enabled, notchOpenTrigger: trigger))
        let screen = NotchScreenState(id: 7, geometry: 42)
        let events: [NSEvent?] = [nil, NSEvent(type: .keyDown, clickCount: 0),
            NSEvent(type: .keyUp, clickCount: 0)] + [NSEvent.EventType.leftMouseDown, .leftMouseUp].flatMap {
                type in [1, 2, 3].map { NSEvent(type: type, clickCount: $0) }
            }
        for event in events {
            let pointer = event?.type == .leftMouseDown || event?.type == .leftMouseUp
            let expected = !pointer || enabled || (trigger == .doubleClick && event!.clickCount >= 2)
            NSApp.currentEvent = event
            let model = NotchModel()
            let before = recorder.pages.count
            model.activateClosed(in: store, on: screen)
            precondition(recorder.pages.count - before == (expected ? 1 : 0),
                         "route mismatch: trigger=\(trigger), enabled=\(enabled), event=\(String(describing: event))")
            precondition(model.screenID == (expected ? screen.id : -1))
            precondition(model.geometry == (expected ? screen.geometry : nil))
            if expected { precondition(recorder.pages.last == .home) }
            cases += 1
        }
    }
}
print("Closed activation matrix passed: \(cases) cases")
''')
        swift = shutil.which("swiftc")
        if swift is None:
            self.fail("Swift is required to exercise closed activation")
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / "main.swift"
            binary = Path(folder) / "closed-activation"
            main.write_text(program)
            compiled = subprocess.run([swift, "-swift-version", "6", str(main), "-o", str(binary)],
                                      capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Closed activation matrix passed: 90 cases", result.stdout)

    def test_all_closed_controls_reach_the_guarded_activation_method(self):
        root = (ROOT / "Sources/PerchApp/Notch/NotchRootView.swift").read_text()
        layer = (ROOT / "Sources/PerchApp/Notch/NotchGlanceCapsule.swift").read_text()
        self.assertIn("model.activateClosed(in: store, on: screen)", root)
        closed_layer = layer.split("struct NotchClosedLayer: View {", 1)[1].split(
            "private struct NotchProgressLine", 1)[0]
        self.assertEqual(closed_layer.count("Button(action: open)"), 3)
        for control in ("notch.closed.progress", "notch.closed.reminder", "notch.closed.tab"):
            self.assertIn(control, closed_layer)


if __name__ == "__main__":
    unittest.main()
