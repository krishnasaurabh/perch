"""Guards for explicit switch semantics and back-tab focus cancellation."""
from pathlib import Path
import subprocess
import sys
import textwrap
import unittest
from unittest.mock import patch

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

    def test_native_probe_requires_effective_keyboard_access_and_restores_preference(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        self.assertIn('try require(NSApp.isFullKeyboardAccessEnabled,', source)
        self.assertIn("'defaults', 'write', '-g', 'AppleKeyboardUIMode', '-int', '3'", source)
        self.assertIn("finally:", source)
        self.assertIn("'defaults', 'delete', '-g', 'AppleKeyboardUIMode'", source)
        self.assertIn("previous.returncode == 0", source)
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

    def test_native_launcher_restores_setting_on_success_failure_and_timeout(self):
        source = (ROOT / "Tests/PerchAppTests/SegmentedKeyboardTests.swift").read_text()
        program = textwrap.dedent(source.split('#"""', 1)[1].split('"""#', 1)[0])
        for had_setting in (False, True):
            for failure in (None, subprocess.CalledProcessError(1, "Perch"),
                            subprocess.TimeoutExpired("Perch", 60)):
                with self.subTest(had_setting=had_setting, failure=type(failure).__name__):
                    calls = []

                    def run(arguments, **kwargs):
                        calls.append(arguments)
                        if arguments[:2] == ["defaults", "read"]:
                            return subprocess.CompletedProcess(arguments, 0 if had_setting else 1, "2\n", "")
                        if arguments[0].endswith("/Perch") and failure is not None:
                            raise failure
                        return subprocess.CompletedProcess(arguments, 0)

                    with patch.object(subprocess, "run", side_effect=run), \
                         patch.object(subprocess, "check_output", return_value="/fixture/bin\n"), \
                         patch.object(sys, "argv", ["launcher", "/fixture/package"]):
                        if failure is None:
                            exec(compile(program, "<native-launcher>", "exec"), {})
                        else:
                            with self.assertRaises(type(failure)):
                                exec(compile(program, "<native-launcher>", "exec"), {})
                    self.assertIn(["defaults", "write", "-g", "AppleKeyboardUIMode", "-int", "3"], calls)
                    self.assertIn(["/fixture/bin/Perch"], calls,
                                  "Keyboard mode belongs in global defaults, never app arguments")
                    expected = (["defaults", "write", "-g", "AppleKeyboardUIMode", "-int", "2"]
                                if had_setting else ["defaults", "delete", "-g", "AppleKeyboardUIMode"])
                    self.assertEqual(calls[-1], expected)


if __name__ == "__main__":
    unittest.main()
