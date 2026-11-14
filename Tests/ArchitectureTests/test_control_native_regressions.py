"""Guards for explicit switch semantics and native keyboard focus fixtures."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMPONENTS = ROOT / "Sources/PerchApp/Workspace/Components"


class ControlNativeRegressionTests(unittest.TestCase):
    def test_switch_names_the_actionable_toggle_with_checkbox_semantics(self):
        source = (COMPONENTS / "PerchSwitch.swift").read_text()
        representation = source.split(".accessibilityRepresentation {", 1)[1]
        self.assertIn(".accessibilityLabel(AppL10n.text(title))", representation)
        self.assertIn(".toggleStyle(.checkbox)", representation)
        self.assertIn(".disabled(!enabled)", representation)

    def test_back_tab_invalidates_deferred_focus_like_forward_tab(self):
        source = (COMPONENTS / "PerchSegmented.swift").read_text()
        self.assertIn(".onKeyPress(.tab) { leaveGroup() }", source)
        self.assertIn(r'.onKeyPress(KeyEquivalent("\u{19}")) { leaveGroup() }', source)

    def test_native_fixture_restores_keyboard_preference_and_activation_policy(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        test = source.split("@MainActor func testNativeRovingFocusAndExitCancellation() async throws {", 1)[1]
        test = test.split("@MainActor private final class", 1)[0]
        self.assertIn('try require(NSApp.isFullKeyboardAccessEnabled,', source)
        self.assertIn('let previous = CFPreferencesCopyValue(', test)
        self.assertIn('key, NSNumber(value: 3),', test)
        restore = test.split('defer {', 1)[1].split('let check =', 1)[0]
        self.assertIn('key, previous,', restore)
        self.assertIn('CFPreferencesSynchronize(', restore)
        self.assertIn('app.setActivationPolicy(originalPolicy)', restore)
        self.assertEqual(test.count('kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost'), 5)
        self.assertIn('app.setActivationPolicy(.accessory)', test)
        self.assertLess(test.index('defer {'), test.index('try await withThrowingTaskGroup'))
        self.assertIn('"Native field=', source)

    def test_native_focus_probe_primes_ax_before_asserting_focus(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        self.assertIn("import ApplicationServices", source)
        run = source.split("func run() async throws {", 1)[1].split("private func testArrowsAndEnds", 1)[0]
        self.assertLess(run.index("await primeAccessibility()"), run.index("try assertEditor("))
        prime = source.split("func primeAccessibility() async {", 1)[1].split("private func", 1)[0]
        for query in ("DispatchQueue.global().async", "AXUIElementCreateApplication(getpid())",
                      "kAXWindowsAttribute", "kAXChildrenAttribute", "kAXFocusedUIElementAttribute",
                      "continuation.resume()"):
            self.assertIn(query, prime)
        self.assertLess(prime.index("kAXWindowsAttribute"), prime.index("kAXChildrenAttribute"))
        self.assertLess(prime.index("kAXChildrenAttribute"), prime.index("kAXFocusedUIElementAttribute"))

    def test_every_native_focus_assertion_logs_responder_and_editor_ownership(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        for name in ("assertEditor", "assertSelectedAndFocused", "assertNoSegmentFocus"):
            body = source.split(f"private func {name}(", 1)[1].split("\n        private func", 1)[0]
            self.assertLess(body.index("traceFocus("), body.index("try require("))
        trace = source.split("private func traceFocus(", 1)[1].split("\n        private func", 1)[0]
        for evidence in ("window.firstResponder", "textEditorResigned=", "beforeEditorOwnsFocus=",
                         "afterEditorOwnsFocus=", "isAccessibilityFocused"):
            self.assertIn(evidence, trace)

    def test_native_fixture_runs_in_xctest_with_real_window_events_and_same_deadlines(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        for obsolete in ("SEGMENTED_KEYBOARD_PROBE", "SegmentedKeyboardProbe", "Process()",
                         "subprocess", "'swift', 'build'", "'defaults'", "app.run()", "exit("):
            self.assertNotIn(obsolete, source)
        for required in ("import XCTest", "NSWindow(", "NSHostingView(",
                         'environment(\\.accessibilityEnabled, true)',
                         "NSApp.activate(ignoringOtherApps: true)", "window.makeKeyAndOrderFront(nil)",
                         "try await check.run()", "window.sendEvent(event)", "NSEvent.keyEvent(",
                         "NSEvent.EventType.keyDown, .keyUp", "ContinuousClock.now + .seconds(3)",
                         "Task.sleep(for: .milliseconds(180))", "Task.sleep(for: .seconds(60))",
                         "defer { group.cancelAll() }", "try Task.checkCancellation()",
                         'XCTFail("\\(error); firstResponder=', "throw error"):
            self.assertIn(required, source)
        self.assertEqual(source.count('func testNativeRovingFocusAndExitCancellation('), 1)

    def test_exact_segment_accessibility_and_escape_contracts_are_preserved(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        for required in ('try require(controls.count == 4,', 'for value in [15, 25, 45, 60]',
                         'label($0) == String(value)', 'try require(matches.count == 1,',
                         'boolean(node, "isAccessibilityFocused") == (value == minutes)',
                         'attribute(node, "accessibilityValue") as? String',
                         '(value == minutes ? "Selected" : "Not selected")',
                         'boolean($0, "isAccessibilityFocused") != true',
                         'characters: "\\u{19}"', 'modifiers: .shift',
                         'testArrowsAndEnds()', 'testExternalSelection()',
                         'testExitAndCancellation()', 'testDisabledAndInactive()',
                         'testEscapeRestoresSelection()', '.onExitCommand {',
                         'driver.minutes = original', 'code: 53, characters: "\\u{1b}"',
                         'try assertSelectedAndFocused(original)'):
            self.assertIn(required, source)
        for key_code in (123, 124, 115, 119):
            self.assertIn(str(key_code), source)


if __name__ == "__main__":
    unittest.main()
