"""Keep native peek checks in a real app lifecycle, with a fail-closed launcher."""

import contextlib
import io
import itertools
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Tests/PerchAppTests/NotchPeekAccessibilityTests.swift"


def launcher():
    source = SOURCE.read_text()
    match = re.search(r'#"""\n(.*?)\n\s*"""#', source, re.S)
    assert match is not None, "Missing native launcher"
    return textwrap.dedent(match.group(1))


class NotchPeekNativeFixtureTests(unittest.TestCase):
    def run_launcher(self, *, build_error=None, run_error=None, stdout=None):
        calls = []

        def run(command, **kwargs):
            calls.append((command, kwargs))
            error = build_error if command[0] == "swift" else run_error
            if error:
                raise error
            return subprocess.CompletedProcess(command, 0, stdout=stdout or "")

        with mock.patch("subprocess.run", side_effect=run), mock.patch(
            "subprocess.check_output", return_value="/build\n"
        ), mock.patch("sys.argv", ["launcher", "/fixture"]), contextlib.redirect_stdout(io.StringIO()):
            exec(compile(launcher(), "peek-launcher", "exec"), {"__name__": "__main__"})
        return calls

    def markers(self):
        return "\n".join(
            f"PASS: Peek stopwatch-{str(s).lower()}-paused-{str(p).lower()}-other-task-{str(t).lower()}"
            for s, p, t in itertools.product([False, True], repeat=3)
        )

    def test_all_eight_scenarios_are_required(self):
        calls = self.run_launcher(stdout=self.markers())
        self.assertEqual(len(calls), 2)
        self.assertIn("-DNOTCH_PEEK_AX_PROBE", calls[0][0])
        self.assertTrue(calls[0][1]["check"])
        self.assertEqual(calls[0][1]["timeout"], 300)
        self.assertTrue(calls[1][1]["check"])
        self.assertEqual(calls[1][1]["timeout"], 120)

    def test_missing_duplicate_or_unknown_marker_fails(self):
        complete = self.markers()
        for output in ["", complete.split("\n", 1)[1], complete + "\n" + complete.splitlines()[0], complete + "\nPASS: Peek unknown"]:
            with self.subTest(output=output), self.assertRaises(AssertionError):
                self.run_launcher(stdout=output)

    def test_build_failure_child_failure_and_timeouts_propagate(self):
        for phase, error in [
            ("build_error", subprocess.CalledProcessError(1, "swift")),
            ("build_error", subprocess.TimeoutExpired("swift", 300)),
            ("run_error", subprocess.CalledProcessError(1, "Perch")),
            ("run_error", subprocess.TimeoutExpired("Perch", 120)),
        ]:
            with self.subTest(phase=phase, error=error), self.assertRaises(type(error)):
                self.run_launcher(**{phase: error})

    def test_throwing_assertions_fail_closed(self):
        source = SOURCE.read_text()
        helpers = source.split("// Throwing assertions", 1)[1].split("private enum NotchPeekProbe", 1)[0]
        helpers = helpers[helpers.index("private struct PeekProbeFailure"):]
        compiler = shutil.which("swiftc")
        assert compiler is not None, "The Swift toolchain is required"
        program = "import Foundation\n" + textwrap.dedent(helpers) + r'''
func rejects(_ check: () throws -> Void) throws {
    do { try check() } catch is PeekProbeFailure { return }
    throw NSError(domain: "An assertion accepted invalid input", code: 1)
}
try peekRequire(true)
try rejects { try peekRequire(false) }
try peekEqual(1, 1)
try rejects { try peekEqual(1, 2) }
try peekEqual(1.0, 1.5, accuracy: 0.5)
try rejects { try peekEqual(1.0, 1.6, accuracy: 0.5) }
try rejects { try peekEqual(Double.nan, 1.0, accuracy: 1.0) }
try peekEqual(try peekUnwrap(Optional(4)), 4)
try rejects { let _: Int = try peekUnwrap(nil) }
print("PASS: Native probe assertion positive and negative controls")
'''
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / "main.swift"
            main.write_text(program)
            binary = Path(directory) / "assertions"
            subprocess.run([compiler, str(main), "-o", str(binary)], check=True, capture_output=True, timeout=60)
            result = subprocess.run([str(binary)], check=True, text=True, capture_output=True, timeout=10)
            self.assertIn("PASS: Native probe assertion positive and negative controls", result.stdout)

    def test_real_app_lifecycle_keeps_the_semantic_and_persistence_gates(self):
        source = SOURCE.read_text()
        self.assertIn("app.setActivationPolicy(.regular)", source)
        self.assertIn("app.run()", source)
        self.assertIn("Bundle.main.bundleIdentifier == nil", source)
        self.assertIn("try peekRequire(window.isKeyWindow", source)
        self.assertIn("try peekEqual(saved.focus?.state, paused ? .running : .paused)", source)
        self.assertIn("try peekRequire(saved.focus?.taskID == nil)", source)
        self.assertIn("try peekEqual(saved.tasks, tasks)", source)
        self.assertIn("unsafeBitCast(implementation, to: Press.self)(button, selector)", source)
        self.assertIn('== "notch.peek.time" }.count, 1)', source)
        self.assertIn('== "notch.peek.block" }.count, 1)', source)
        self.assertIn("AXUIElementCreateApplication(getpid())", source)
        for edge in ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"]:
            self.assertIn(edge, source)
        self.assertIn("children += view.subviews", source)
        self.assertIn(".environment(\\.accessibilityEnabled, true)", source)
        self.assertNotIn("XCTSkip", source)


if __name__ == "__main__":
    unittest.main()
