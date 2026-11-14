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

    def test_native_launcher_restores_keyboard_preference_without_changing_its_activation_policy(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        test = source.split("func testNativeRovingFocusAndExitCancellation() throws {", 1)[1]
        self.assertIn('try require(NSApp.isFullKeyboardAccessEnabled,', source)
        self.assertIn('let previous = CFPreferencesCopyValue(', test)
        self.assertIn('key, NSNumber(value: 3),', test)
        restore = test.split('defer {', 1)[1].split('let source =', 1)[0]
        self.assertIn('key, previous,', restore)
        self.assertIn('CFPreferencesSynchronize(', restore)
        normalized = ' '.join(test.split())
        self.assertEqual(normalized.count('kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost'), 5)
        self.assertNotIn('setActivationPolicy', source.split('#elseif os(macOS)', 1)[1])
        self.assertLess(test.index('defer {'), test.index('try process.run()'))
        self.assertIn('"Native field=', source)

    def test_unbundled_probe_sets_regular_activation_before_scheduling_checks(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        probe = source.split("private enum SegmentedKeyboardProbe {", 1)[1]
        startup = probe.split("@MainActor private static func runCheck()", 1)[0]
        ordered = ("MainActor.assumeIsolated {", "let app = NSApplication.shared",
                   "app.setActivationPolicy(.regular)", "Task { @MainActor in",
                   "try await runCheck()", "app.run()")
        positions = [startup.index(step) for step in ordered]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(source.count("setActivationPolicy("), 1)

    def test_every_activation_attempt_logs_policy_and_active_state(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        activation = source.split("private func activateKeyWindow() async {", 1)[1]
        activation = activation.split("private func settle()", 1)[0]
        ordered = ("for attempt in 0..<25", "NSApp.activate(ignoringOtherApps: true)",
                   "window.makeKeyAndOrderFront(nil)", "await settle()", 'log(',
                   "NSApp.activationPolicy().rawValue", "NSApp.isActive", "if window.isKeyWindow")
        positions = [activation.index(step) for step in ordered]
        self.assertEqual(positions, sorted(positions))
        self.assertIn(r"\(attempt + 1)", activation)

    def test_native_focus_probe_primes_ax_before_asserting_focus(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        self.assertIn("import ApplicationServices", source)
        setup = source.split("static func runCheck() async throws {", 1)[1].split("private static func require", 1)[0]
        ordered = ('require(Bundle.main.bundleIdentifier == nil', 'let primer = NSWindow(',
                   'NSTextField(labelWithString:', 'primer.orderFront(nil)',
                   'await SegmentedKeyboardCheck.primeAccessibility()', 'primer.close()',
                   'let check = SegmentedKeyboardCheck()', 'try await check.run()')
        positions = [setup.index(step) for step in ordered]
        self.assertEqual(positions, sorted(positions))
        run = source.split("func run() async throws {", 1)[1].split("private func testArrowsAndEnds", 1)[0]
        self.assertLess(run.index("await activateKeyWindow()"), run.index("try assertEditor("))
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

    def test_native_fixture_spawns_package_product_with_real_events_and_same_deadlines(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        for required in ("#if SEGMENTED_KEYBOARD_PROBE", "SegmentedKeyboardProbe.run()", "Process()",
                         'for item in ["Package.swift", "Sources", "Tests"]',
                         '"Sources/Perch/main.swift"', "import XCTest", "NSWindow(", "NSHostingView(",
                         'environment(\\.accessibilityEnabled, true)',
                         "NSApp.activate(ignoringOtherApps: true)", "window.makeKeyAndOrderFront(nil)",
                         "try await check.run()", "window.sendEvent(event)", "NSEvent.keyEvent(",
                         "NSEvent.EventType.keyDown, .keyUp", "for attempt in 0..<25",
                         "Task.sleep(for: .milliseconds(180))", "Task.sleep(for: .seconds(60))",
                         "defer { group.cancelAll() }", "try Task.checkCancellation()",
                         "'swift', 'build', '--jobs', '2', '--package-path', package",
                         "'-Xswiftc', '-DSEGMENTED_KEYBOARD_PROBE', '-Xswiftc', '-enable-testing'",
                         "'--product', 'Perch'", "timeout=300", "timeout=120",
                         "'-AppleKeyboardUIMode', '3'", "app.run()", "exit(0)", "exit(1)",
                         "XCTAssertEqual(process.terminationReason, .exit)",
                         "XCTAssertEqual(process.terminationStatus, 0,",
                         'XCTAssertTrue(result.contains("PASS: Segmented native arrows, ends, Tab, back-tab and cancellation"))',
                         "FileHandle.standardError.write(Data(result.utf8))"):
            self.assertIn(required, source)
        self.assertEqual(source.count('func testNativeRovingFocusAndExitCancellation('), 1)
        self.assertNotIn('group.addTask { @MainActor', source)
        self.assertNotIn('setActivationPolicy', source.split('#elseif os(macOS)', 1)[1])
        self.assertNotIn('XCTSkip', source)

    def test_native_launcher_executes_exact_commands_and_propagates_failures(self):
        import re
        import sys
        import textwrap
        import types
        from unittest.mock import patch

        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        match = re.search(r'#"""\n(.*?)\n\s*"""#', source, re.S)
        self.assertIsNotNone(match)
        assert match is not None
        program = textwrap.dedent(match[1])
        for failure in (None, "build", "bin_path", "run"):
            calls = []

            def run(args, **kwargs):
                stage = "build" if args[0] == "swift" else "run"
                calls.append((stage, args, kwargs))
                if stage == failure:
                    raise RuntimeError(stage)

            def output(args, **kwargs):
                calls.append(("bin_path", args, kwargs))
                if failure == "bin_path":
                    raise RuntimeError("bin_path")
                return "/fixture/.build/debug\n"

            module = types.ModuleType("subprocess")
            setattr(module, "run", run)
            setattr(module, "check_output", output)
            with self.subTest(failure=failure), patch.dict(sys.modules, {"subprocess": module}), \
                    patch.object(sys, "argv", ["launcher", "/fixture"]):
                if failure is None:
                    exec(program, {})
                else:
                    with self.assertRaisesRegex(RuntimeError, failure):
                        exec(program, {})
            expected = ["build", "bin_path", "run"]
            self.assertEqual([item[0] for item in calls],
                             expected if failure is None else expected[:expected.index(failure) + 1])
            self.assertEqual(calls[0][1], [
                "swift", "build", "--jobs", "2", "--package-path", "/fixture",
                "-Xswiftc", "-DSEGMENTED_KEYBOARD_PROBE", "-Xswiftc", "-enable-testing",
                "--product", "Perch"])
            self.assertEqual(calls[0][2], {"check": True, "timeout": 300})
            if failure is None:
                self.assertEqual(calls[1][2], {"text": True, "timeout": 30})
                self.assertEqual(calls[2][1], ["/fixture/.build/debug/Perch", "-AppleKeyboardUIMode", "3"])
                self.assertEqual(calls[2][2], {"check": True, "timeout": 120})

    def test_exact_segment_accessibility_and_escape_contracts_are_preserved(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        for required in ('try require(controls.count == 4,', 'for value in [15, 25, 45, 60]',
                         'label($0) == String(value)', 'try require(matches.count == 1,',
                         'if value != minutes {',
                         'boolean(node, "isAccessibilityFocused") == false',
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
