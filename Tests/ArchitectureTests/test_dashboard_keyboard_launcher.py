"""Portable contracts for the native dashboard keyboard launcher, not UI evidence."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Tests/PerchAppTests/DashboardKeyLoopTests.swift"
SCENARIOS = (
    "testHistorySearchHasExplicitTabPredecessor",
    "testEverySectionInstallsInitialTabStopWithoutRequiringSearch",
    "testArrowAndSpaceUseCurrentSelectionAndDoNotStealPageKeys",
    "testSelectionChangesPreserveHostedRootAndRefreshHistoryLinks",
)


class DashboardKeyboardLauncherTests(unittest.TestCase):
    def test_four_scenarios_run_once_and_have_required_pass_lines(self):
        source = SOURCE.read_text()
        probe, parent = source.split("#else", 1)
        self.assertTrue(probe.startswith("#if DASHBOARD_KEYBOARD_PROBE"))
        self.assertNotIn("import XCTest", probe)
        self.assertNotIn("XCTSkip", source)
        for name in SCENARIOS:
            self.assertEqual(probe.count("func " + name + "("), 1)
            self.assertEqual(probe.count("try await check." + name + "()"), 1)
            self.assertIn('log("PASS: Dashboard ' + name + '")', probe)
            self.assertIn('"PASS: Dashboard ' + name + '"', parent)
        self.assertIn("XCTAssertEqual(process.terminationReason, .exit)", parent)
        self.assertIn("XCTAssertEqual(process.terminationStatus, 0,", parent)
        self.assertIn("result.components(separatedBy: .newlines).filter", parent)
        self.assertIn("XCTAssertEqual(lines.filter { $0 == marker }.count, 1", parent)

    def test_only_child_changes_policy_and_retains_activation_bound(self):
        probe, parent = SOURCE.read_text().split("#else", 1)
        self.assertEqual(probe.count("setActivationPolicy("), 1)
        self.assertNotIn("setActivationPolicy", parent)
        startup = probe.split("private enum DashboardKeyboardProbe", 1)[1]
        ordered = ("MainActor.assumeIsolated", "app.setActivationPolicy(.regular)",
                   "Task { @MainActor in", "try await runChecks()", "app.run()")
        positions = [startup.index(item) for item in ordered]
        self.assertEqual(positions, sorted(positions))
        for token in ("Bundle.main.bundleIdentifier == nil", "NSApp.isFullKeyboardAccessEnabled",
                      "for attempt in 0..<25", "Task.sleep(for: .milliseconds(180))",
                      "NSApp.isActive", "NSApp.activationPolicy().rawValue",
                      "window.isKeyWindow ? window : nil"):
            self.assertIn(token, probe)

    def test_native_predicates_and_event_order_are_not_replaced_by_launch_checks(self):
        source = SOURCE.read_text().split("#else", 1)[0]
        for token in ("tabs.nextKeyView === search", "search.previousKeyView === tabs",
                      "window.firstResponder === currentTabs", "tabs.nextValidKeyView === action",
                      "window.initialFirstResponder === tabs", "root.nextKeyView === tabs",
                      "window.firstResponder === action", "host.selectionState === selection",
                      'for phase in ["initial", "rebuilt"]', "for _ in 0..<30", "for _ in 0..<2",
                      "search.removeFromSuperview()", "Task.sleep(nanoseconds: 50_000_000)"):
            self.assertIn(token, source)
        routine = source.split("func testArrowAndSpaceUseCurrentSelectionAndDoNotStealPageKeys", 1)[1]
        routine = routine.split("func testSelectionChanges", 1)[0]
        ordered = ('host.handleSelectionKey(event(124,', 'equal(selection.tab, expected)',
                   'host.handleSelectionKey(event(49,', 'equal(selection.tab, expected)')
        start = 0
        for item in ordered:
            start = routine.index(item, start) + len(item)
        self.assertIn("flags: .command", routine)
        self.assertIn("await Task.yield()", routine)

    def test_child_build_and_launch_failures_and_timeouts_propagate(self):
        source = SOURCE.read_text()
        match = re.search(r'#"""\n(.*?)\n\s*"""#', source, re.S)
        self.assertIsNotNone(match)
        assert match is not None
        program = textwrap.dedent(match[1])
        for failure in (None, "build", "bin_path", "run", "timeout"):
            calls = []

            def run(args, **kwargs):
                stage = "build" if args[0] == "swift" else "run"
                calls.append((stage, args, kwargs))
                if stage == failure:
                    raise subprocess.CalledProcessError(7, args)
                if failure == "timeout" and stage == "run":
                    raise subprocess.TimeoutExpired(args, kwargs["timeout"])

            def output(args, **kwargs):
                calls.append(("bin_path", args, kwargs))
                if failure == "bin_path":
                    raise subprocess.CalledProcessError(7, args)
                return "/fixture/.build/debug\n"

            module = types.ModuleType("subprocess")
            setattr(module, "run", run)
            setattr(module, "check_output", output)
            with self.subTest(failure=failure), patch.dict(sys.modules, {"subprocess": module}), \
                    patch.object(sys, "argv", ["launcher", "/fixture"]):
                if failure is None:
                    exec(program, {})
                else:
                    error = subprocess.TimeoutExpired if failure == "timeout" else subprocess.CalledProcessError
                    with self.assertRaises(error):
                        exec(program, {})
            stages = ["build", "bin_path", "run"]
            failed_stage = "run" if failure == "timeout" else failure
            expected = stages if failed_stage is None else stages[:stages.index(failed_stage) + 1]
            self.assertEqual([item[0] for item in calls], expected)
            self.assertEqual(calls[0][1], [
                "swift", "build", "--jobs", "2", "--package-path", "/fixture",
                "-Xswiftc", "-DDASHBOARD_KEYBOARD_PROBE", "-Xswiftc", "-enable-testing",
                "--product", "Perch"])
            self.assertEqual(calls[0][2], {"check": True, "timeout": 300})
            if len(calls) == 3:
                self.assertEqual(calls[2][1], ["/fixture/.build/debug/Perch", "-AppleKeyboardUIMode", "3"])
                self.assertEqual(calls[2][2], {"check": True, "timeout": 120})
        parent = source.split("#else", 1)[1]
        self.assertIn('for item in ["Package.swift", "Sources", "Tests"]', parent)
        self.assertIn('"Sources/Perch/main.swift"', parent)
        self.assertIn("DashboardKeyboardProbe.run()", parent)
        self.assertIn("CFPreferencesCopyValue", parent)
        self.assertIn("key, previous,", parent)
        self.assertLess(parent.index("defer {"), parent.index("try process.run()"))

    def test_real_assertion_helpers_reject_bad_values(self):
        source = SOURCE.read_text()
        helpers = source.split("// Portable assertion primitives.", 1)[1].split(
            "// End portable assertion primitives.", 1)[0]
        cases = r'''
func expectFailure(_ action: () throws -> Void) {
    do { try action(); fatalError("negative control was accepted") }
    catch {
        precondition(String(describing: error).contains("control"))
        precondition(String(describing: error).contains("321"))
    }
}
try require(true)
try reject(false)
try equal(2, 2)
try isNil(Optional<Int>.none)
try notNil(Optional(2))
let unwrapped = try unwrap(Optional(2))
precondition(unwrapped == 2)
expectFailure { try require(false, "control", line: 321) }
expectFailure { try reject(true, "control", line: 321) }
expectFailure { try equal(1, 2, "control", line: 321) }
expectFailure { try isNil(Optional(2), "control", line: 321) }
expectFailure { try notNil(Optional<Int>.none, "control", line: 321) }
expectFailure { let _: Int = try unwrap(nil, "control", line: 321) }
print("PASS: assertion positive and negative controls")
'''
        # Only assertion primitives execute here; this is not a native-window test.
        with tempfile.TemporaryDirectory() as temporary:
            main = Path(temporary) / "main.swift"
            main.write_text("import Foundation\n" + textwrap.dedent(helpers) + cases)
            result = subprocess.run(["swift", str(main)], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: assertion positive and negative controls", result.stdout)


if __name__ == "__main__":
    unittest.main()
