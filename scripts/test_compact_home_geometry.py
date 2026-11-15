"""Exercise the compact probe's real selection and failure-collection logic.

Foundation fixtures validate policy only; native geometry remains a macOS gate.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/compact_home_probe.swift"


def declaration(source, name):
    return name + source.split(name, 1)[1].split("\n}\n", 1)[0] + "\n}\n"


class CompactHomeGeometryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.swiftc = shutil.which("swiftc")
        if cls.swiftc is None:
            raise RuntimeError("swiftc is required for the geometry probe regressions")
        cls.temp = tempfile.TemporaryDirectory(prefix="compact-geometry-", dir=os.environ.get("TMPDIR"))
        cls.root = Path(cls.temp.name)
        source = SOURCE.read_text()
        cls.logic = "import Foundation\n" + "\n".join(declaration(source, name) for name in (
            "struct ProbeAssertions {", "struct TaskViewportCandidate {", "enum TaskViewportSelection {"))

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_swift(self, driver, *, logic=None):
        assert self.swiftc is not None
        source, binary = self.root / "main.swift", self.root / "geometry"
        source.write_text((self.logic if logic is None else logic) + driver)
        compiled = subprocess.run([self.swiftc, "-swift-version", "6", str(source), "-o", str(binary)],
                                  capture_output=True, text=True, timeout=60)
        self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
        return subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)

    def test_collects_every_failure_and_evaluates_each_condition_once(self):
        result = self.run_swift('''
var checks = ProbeAssertions()
var evaluations = 0
@MainActor func condition(_ value: Bool) -> Bool { evaluations += 1; return value }
precondition(!checks.check(condition(false), "empty: height=340 limit=300"))
precondition(checks.check(condition(true), "three: height=280 limit=300"))
precondition(!checks.check(condition(false), "dense: outside shell"))
precondition(evaluations == 3)
precondition(checks.failures == ["empty: height=340 limit=300", "dense: outside shell"])
precondition(!checks.succeeded)
var clean = ProbeAssertions()
precondition(clean.check(true, "valid"))
precondition(clean.succeeded)
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_selects_identity_not_leftmost_or_shortest(self):
        result = self.run_swift('''
let candidates = [
    TaskViewportCandidate(frame: CGRect(x: 0, y: 0, width: 200, height: 200), identifier: "unrelated", hasTaskMarker: false),
    TaskViewportCandidate(frame: CGRect(x: 250, y: 0, width: 300, height: 340), identifier: "today-task-viewport", hasTaskMarker: false),
    TaskViewportCandidate(frame: CGRect(x: 600, y: 0, width: 300, height: 100), identifier: "notes", hasTaskMarker: false),
]
precondition(TaskViewportSelection.index(in: candidates, ownerFrames: []) == 1)
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_existing_marker_and_accessibility_owner_work_without_cue(self):
        result = self.run_swift('''
let frame = CGRect(x: 40, y: 20, width: 260, height: 300)
let other = TaskViewportCandidate(frame: CGRect(x: 500, y: 0, width: 200, height: 200), identifier: "", hasTaskMarker: false)
let marked = TaskViewportCandidate(frame: frame, identifier: "", hasTaskMarker: true)
let unmarked = TaskViewportCandidate(frame: frame, identifier: "", hasTaskMarker: false)
precondition(TaskViewportSelection.index(in: [other, marked], ownerFrames: []) == 1)
precondition(TaskViewportSelection.index(in: [other, unmarked], ownerFrames: [frame]) == 1)
precondition(TaskViewportSelection.index(in: [other, unmarked], ownerFrames: []) == nil)
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_real_require_reaches_the_final_failure_gate(self):
        source = SOURCE.read_text()
        logger = "@MainActor\n" + declaration(source, "enum ProbeCheckLog {")
        require = source.split("@discardableResult\n", 1)[1].split("\n@MainActor\nfunc settle", 1)[0]
        ending = "            guard ProbeCheckLog.assertions.succeeded else {" + source.split(
            "            guard ProbeCheckLog.assertions.succeeded else {", 1)[1].split(
                '            print("Compact Home layout probes passed.")', 1)[0]
        driver = logger + "\n@MainActor\n@discardableResult\n" + require + '''
ProbeCheckLog.geometryContext = "workspaceHeight=544 viewportHeight=340 limit=300"
require(false, "first failure")
print("REACHED_SECOND_CHECK")
require(false, "second failure")
print("REACHED_FINAL_GATE")
''' + ending
        result = self.run_swift(driver)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("REACHED_SECOND_CHECK", result.stdout)
        self.assertIn("REACHED_FINAL_GATE", result.stdout)
        self.assertIn("2 assertions", result.stderr)
        self.assertIn("first failure", result.stderr)
        self.assertIn("second failure", result.stderr)
        self.assertIn("viewportHeight=340", result.stderr)
        clean = self.run_swift(driver.replace('require(false,', 'require(true,'))
        self.assertEqual(clean.returncode, 0, clean.stderr)

    def test_negative_controls_catch_first_candidate_and_lost_failures(self):
        selection = self.logic.replace(
            "return matches.count == 1 ? matches[0] : nil", "return candidates.isEmpty ? nil : 0")
        self.assertNotEqual(selection, self.logic)
        result = self.run_swift('''
let other = TaskViewportCandidate(frame: CGRect(x: 0, y: 0, width: 200, height: 200), identifier: "other", hasTaskMarker: false)
let tasks = TaskViewportCandidate(frame: CGRect(x: 250, y: 0, width: 200, height: 340), identifier: "today-task-viewport", hasTaskMarker: false)
precondition(TaskViewportSelection.index(in: [other, tasks], ownerFrames: []) == 1)
''', logic=selection)
        self.assertNotEqual(result.returncode, 0)
        forgotten = self.logic.replace("failures.append(message)", "failures = [message]")
        self.assertNotEqual(forgotten, self.logic)
        result = self.run_swift('''
var checks = ProbeAssertions()
_ = checks.check(false, "empty")
_ = checks.check(false, "dense")
precondition(checks.failures == ["empty", "dense"])
''', logic=forgotten)
        self.assertNotEqual(result.returncode, 0)

    def test_missing_and_ambiguous_owners_fail_closed(self):
        result = self.run_swift('''
let candidate = TaskViewportCandidate(frame: CGRect(x: 0, y: 0, width: 200, height: 300), identifier: "today-task-viewport", hasTaskMarker: false)
precondition(TaskViewportSelection.index(in: [], ownerFrames: []) == nil)
precondition(TaskViewportSelection.index(in: [candidate, candidate], ownerFrames: []) == nil)
''')
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
