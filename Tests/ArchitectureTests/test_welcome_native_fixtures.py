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

    def test_native_event_fixture_checks_copied_payload_and_current_identity(self):
        source = (ROOT / "Tests/PerchAppTests/NotchClickOpeningTests.swift").read_text()
        dispatch = declaration(source, "@MainActor private static func dispatchQueuedEvent(")
        program = r'''import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
final class NSEvent {
    enum EventType: Int { case leftMouseDown, leftMouseUp, keyDown, keyUp }
    struct EventTypeMask { let rawValue: Int }
    let type: EventType
    var timestamp: Double = 297.72130583333336
    let windowNumber = 5
    let locationInWindow = CGPoint(x: 50, y: 50)
    let modifierFlags = 0
    let clickCount = 2
    let characters: String? = " "
    let keyCode = 49
    init(type: EventType) { self.type = type }
}
@MainActor enum NSApp {
    static var currentEvent: NSEvent?
    static var queued: NSEvent?
    static var sent: NSEvent?
    static func postEvent(_ event: NSEvent, atStart: Bool) {
        precondition(atStart)
        let copy = NSEvent(type: event.type)
        copy.timestamp = (event.timestamp * 1e9).rounded(.towardZero) / 1e9
            + (CommandLine.arguments.contains("--corrupt") ? 1 : 0)
        queued = copy
    }
    static func nextEvent(matching: NSEvent.EventTypeMask, until: Date,
                          inMode: RunLoop.Mode, dequeue: Bool) -> NSEvent? {
        precondition(dequeue && matching.rawValue == 1 << queued!.type.rawValue)
        currentEvent = queued
        queued = nil
        return currentEvent
    }
    static func sendEvent(_ event: NSEvent) { precondition(currentEvent === event); sent = event }
}
func XCTAssertTrue(_ value: Bool, _ message: String = "") { precondition(value, message) }
func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T) {
    precondition(left == right, "Submitted payload mismatch")
}
func XCTAssertEqual(_ left: Double, _ right: Double, accuracy: Double, _ message: String = "") {
    precondition(abs(left - right) <= accuracy, "Submitted payload mismatch: " + message)
}
func XCTUnwrap<T>(_ value: T?) throws -> T { precondition(value != nil); return value! }
struct Fixture {
''' + dispatch + r'''
    @MainActor static func run() throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .keyDown, .keyUp] {
            let original = NSEvent(type: type)
            try dispatchQueuedEvent(original)
            precondition(NSApp.sent !== original, "The test must really copy the event")
            precondition(NSApp.sent === NSApp.currentEvent)
        }
        print("Copied event payload and dequeued identity passed")
    }
}
try Fixture.run()
'''
        swift = shutil.which("swiftc")
        if swift is None:
            self.fail("Swift is required to exercise the copied-event fixture")
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / "main.swift"
            binary = Path(folder) / "event-copy"
            main.write_text(program)
            compiled = subprocess.run([swift, "-swift-version", "6", str(main), "-o", str(binary)],
                                      capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            corrupt = subprocess.run([str(binary), "--corrupt"], capture_output=True, text=True, timeout=30)
            self.assertNotEqual(corrupt.returncode, 0)
            self.assertIn("Submitted payload mismatch", corrupt.stderr)

    def test_welcome_primes_accessibility_off_main_before_building_host(self):
        source = (ROOT / "Tests/PerchAppTests/WelcomeScreenshotConsentTests.swift").read_text()
        test = declaration(source, "@MainActor func testWelcomePresentsHabitsAndReadOnlyPermissionReasons(")
        self.assertIn("import ApplicationServices", source)
        self.assertLess(test.index("primer.orderFront(nil)"), test.index("await Self.primeAccessibility()"))
        self.assertLess(test.index("await Self.primeAccessibility()"), test.index("primer.close()"))
        self.assertLess(test.index("primer.close()"), test.index("let host = NSHostingView("))
        prime = declaration(source, "private nonisolated static func primeAccessibility(")
        for operation in ("withCheckedContinuation", "DispatchQueue.global().async",
                          "AXUIElementCreateApplication(getpid())", "kAXWindowsAttribute",
                          "kAXChildrenAttribute", "continuation.resume()"):
            self.assertIn(operation, prime)
        self.assertLess(prime.index("DispatchQueue.global().async"),
                        prime.index("AXUIElementCreateApplication(getpid())"))
        self.assertIn("XCTAssertTrue(text.contains(value)", test)
        self.assertIn("XCTAssertEqual(store.prefs, before", test)

    def test_native_event_fixture_dequeues_before_dispatch(self):
        source = (ROOT / "Tests/PerchAppTests/NotchClickOpeningTests.swift").read_text()
        dispatch = declaration(source, "private static func dispatchQueuedEvent(")
        self.assertLess(dispatch.index("NSApp.postEvent("), dispatch.index("NSApp.nextEvent("))
        self.assertLess(dispatch.index("NSApp.nextEvent("), dispatch.index("NSApp.sendEvent("))
        self.assertIn("dequeue: true", dispatch)
        for field in ("type", "windowNumber", "locationInWindow", "modifierFlags", "clickCount"):
            self.assertIn(f"XCTAssertEqual(dequeued.{field}, event.{field})", dispatch)
        self.assertIn("XCTAssertEqual(dequeued.timestamp, event.timestamp, accuracy: 1e-6)", dispatch)
        self.assertIn("NSApp.currentEvent === dequeued", dispatch)
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
