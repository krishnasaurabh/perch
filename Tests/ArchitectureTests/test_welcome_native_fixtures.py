"""Check native Welcome fixture utilities without claiming an AppKit run."""
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


class WelcomeNativeFixtureTests(unittest.TestCase):
    def test_accessibility_text_uses_real_foundation_string_types(self):
        source = (ROOT / "Tests/PerchAppTests/WelcomeScreenshotConsentTests.swift").read_text()
        helper = declaration(source, "private static func accessibilityString(")
        text_reader = declaration(source, "@MainActor private static func accessibleText(")
        node_reader = declaration(source, "@MainActor private static func accessibilityNodes(")
        # Only AppKit graph storage is substituted; conversion and traversal are
        # the exact native-test code, using real Foundation attributed strings.
        program = r'''import Foundation
@MainActor class Node: NSObject { var values: [String: Any] = [:] }
@MainActor class NSView: Node { var subviews: [NSView] = [] }
@MainActor class NSWindow: Node { var contentView: NSView? }
struct Reader {
    @MainActor private static func attribute(_ node: NSObject, _ name: String) -> Any? {
        (node as? Node)?.values[name]
    }
''' + helper + "\n" + text_reader + "\n" + node_reader + r'''
    @MainActor static func verify() {
        precondition(accessibilityString("Write it down") == "Write it down")
        precondition(accessibilityString(NSString(string: "Park the rest")) == "Park the rest")
        precondition(accessibilityString(NSAttributedString(string: "Give it time")) == "Give it time",
                     "The native AX reader discarded an attributed label")
        precondition(accessibilityString(NSAttributedString(string: "")) == "")
        precondition(accessibilityString(nil) == nil)
        precondition(accessibilityString(42) == nil)
        print("Welcome accessibility text: 6 cases passed")

        let window = NSWindow()
        let host = NSView()
        let scroll = NSView()
        let group = Node()
        let plain = Node()
        let attributed = Node()
        let button = Node()
        window.contentView = host
        host.subviews = [scroll]
        scroll.values["accessibilityContents"] = [group]
        group.values["accessibilityChildrenInNavigationOrder"] = [plain, attributed, button]
        group.values["accessibilityChildren"] = [window] // Cycle, not another visit.
        plain.values["accessibilityLabel"] = "Write it down"
        attributed.values["accessibilityValue"] = NSAttributedString(string: "Give it time")
        button.values["accessibilityTitle"] = "Start with three things"
        button.values["accessibilityChildren"] = [plain] // Shared edge, not another visit.
        precondition(accessibilityNodes(window).count == 7)
        let expected: Set<String> = ["Write it down", "Give it time", "Start with three things"]
        precondition(accessibleText(window) == expected)
        attributed.values["accessibilityValue"] = NSAttributedString(string: "Changed")
        precondition(!accessibleText(window).contains("Give it time"), "Do not retain stale text")
        precondition(accessibleText(window).contains("Changed"))
        precondition(accessibleText(NSView()).isEmpty, "Do not invent absent labels")
        group.values = [:]
        button.values = [:]
        print("Welcome AX graph: native, contents and ordered edges; cycles and missing labels passed")
    }
}
Reader.verify()
'''
        swift = shutil.which("swiftc")
        if swift is None:
            self.fail("Swift is required to exercise the Foundation AX reader")
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / "main.swift"
            binary = Path(folder) / "reader"
            main.write_text(program)
            compiled = subprocess.run([swift, "-swift-version", "6", str(main), "-o", str(binary)],
                                      capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Welcome accessibility text: 6 cases passed", result.stdout)

    def test_native_event_fixture_dequeues_before_dispatch(self):
        source = (ROOT / "Tests/PerchAppTests/NotchClickOpeningTests.swift").read_text()
        dispatch = declaration(source, "private static func dispatchQueuedEvent(")
        self.assertLess(dispatch.index("NSApp.postEvent("), dispatch.index("NSApp.nextEvent("))
        self.assertLess(dispatch.index("NSApp.nextEvent("), dispatch.index("NSApp.sendEvent("))
        self.assertIn("dequeue: true", dispatch)
        self.assertIn("dequeued === event", dispatch)
        self.assertIn("NSApp.currentEvent === event", dispatch)
        self.assertIn("try Self.dispatchQueuedEvent(event)", source)
        for assertion in (
            "XCTAssertTrue(delivered", "XCTAssertEqual(NSApp.currentEvent?.type, event.type",
            "XCTAssertEqual(NSApp.currentEvent?.clickCount, clickCount",
            "XCTAssertEqual(notifications.destinations.count - before, expected ? 1 : 0",
            "XCTAssertEqual(model.screenID, expected ? screen.id : 0",
            "XCTAssertEqual(model.geometry, expected ? screen.geometry : nil",
        ):
            self.assertIn(assertion, source)


if __name__ == "__main__":
    unittest.main()
