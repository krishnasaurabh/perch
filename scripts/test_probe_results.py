"""Portable wrapper/report controls; synthetic payloads are not native evidence."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("probe_results", ROOT / "scripts/check_probe_results.py")
assert spec is not None and spec.loader is not None
results = importlib.util.module_from_spec(spec)
spec.loader.exec_module(results)


def integration_report():
    required = [f"settings {p} pane renders its content" for p in
                ("General", "Workspace", "Focus timer", "AI agents", "System")]
    required += [f"dashboard {p} tab renders its content" for p in
                 ("Upcoming", "History", "Insights", "Projects")]
    required += ["welcome never rewrites unreadable planner data", "failed details save keeps the draft",
                 "Command-Z restores the deleted project and its task links"]
    return {"passed": required + [f"fixture {i}" for i in range(60)], "failed": []}


def theme_report():
    rows = [{"page": p, "state": s} for p in results.THEME_PAGES for s in results.THEME_STATES]
    names = [f"{r['page']} [{r['state']}]: synthetic gate" for r in rows]
    return {"rows": rows, "passed": names + [f"fixture {i}" for i in range(330 - len(names))], "failed": []}


def clips_report():
    source = (ROOT / "scripts/clips_layout_probe.swift").read_text()
    array = source.split("let clipsKeyboardAssertions = [", 1)[1].split("]", 1)[0]
    labels = re.findall(r'"([^"]+)"', array)
    return [{"broken": "", "red": "", "ok": True, "passed": labels}]


class ProbeReportTests(unittest.TestCase):
    def test_complete_synthetic_reports(self):
        for kind, report in (("integration", integration_report()), ("theme", theme_report()),
                             ("clips", clips_report()),
                             ("allpage", {"passed": [f"gate {i}" for i in range(93)],
                                          "failed": [], "assertions": 93})):
            self.assertGreater(results.validate(kind, report), 0)

    def test_failures_and_missing_failure_lists_are_rejected(self):
        for kind, build in (("integration", integration_report), ("theme", theme_report)):
            for failure in (["deliberate red"], None):
                report = build()
                report["failed"] = failure
                with self.subTest(kind=kind, failure=failure), self.assertRaises(ValueError):
                    results.validate(kind, report)

    def test_every_theme_capture_is_mandatory_and_unique(self):
        for index in range(56):
            report = theme_report()
            report["rows"].pop(index)
            with self.subTest(index=index), self.assertRaises(ValueError):
                results.validate("theme", report)
        report = theme_report()
        report["rows"][-1] = report["rows"][0]
        with self.assertRaises(ValueError):
            results.validate("theme", report)
        report = theme_report()
        report["passed"] = report["passed"][:329]
        with self.assertRaises(ValueError):
            results.validate("theme", report)

    def test_every_keyboard_assertion_is_mandatory(self):
        for index in range(19):
            report = clips_report()
            report[0]["passed"].pop(index)
            with self.subTest(index=index), self.assertRaises(ValueError):
                results.validate("clips", report)
        for key, value in (("ok", False), ("red", "wrong")):
            report = clips_report()
            report[0][key] = value
            with self.assertRaises(ValueError):
                results.validate("clips", report)

    def test_keyboard_control_must_fail_its_exact_assertion(self):
        report = clips_report()
        report.append({"broken": "expected", "red": "different", "ok": True, "passed": []})
        with self.assertRaises(ValueError):
            results.validate("clips", report)

    def test_missing_report_cli_is_red(self):
        with tempfile.TemporaryDirectory() as directory:
            run = subprocess.run([sys.executable, str(ROOT / "scripts/check_probe_results.py"),
                                  "theme", str(Path(directory) / "absent.json")], capture_output=True, text=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn("FAIL: theme", run.stderr)

    def test_wrappers_fail_before_any_build_on_linux(self):
        with tempfile.TemporaryDirectory() as directory:
            uname = Path(directory) / "uname"
            uname.write_text("#!/bin/sh\nprintf 'Linux\\n'\n")
            uname.chmod(0o755)
            for name in ("integration", "theme", "clips_layout", "allpage_matrix"):
                run = subprocess.run(["bash", str(ROOT / f"scripts/check_{name}.sh"), directory],
                                     env=dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"]),
                                     capture_output=True, text=True)
                self.assertEqual(run.returncode, 2, run.stderr)
            self.assertFalse((Path(directory) / "planner.json").exists())

    def test_wrappers_enforce_native_reports_and_bounded_builds(self):
        for name, report in (("integration", "integration-matrix.json"), ("theme", "measured-states.json"),
                             ("clips_layout", "clips-keyboard.json"), ("allpage_matrix", "matrix-evidence.json")):
            source = (ROOT / f"scripts/check_{name}.sh").read_text()
            self.assertIn("set -euo pipefail", source)
            self.assertIn("check_probe_results.py", source)
            self.assertIn(report, source)
            for build in (line for line in source.splitlines() if "swift build" in line):
                self.assertIn("--jobs 2", build)
                self.assertIn("-enable-testing", build)

    def test_launchers_propagate_exit_and_timeout_and_disable_capture(self):
        for name in ("integration", "theme", "clips"):
            path = ROOT / ("scripts/run_clips_probe.py" if name == "clips" else f"scripts/check_{name}.sh")
            source = path.read_text()
            code = source if name == "clips" else source.split("<<'PY'\n", 1)[1].split("\nPY", 1)[0]
            with tempfile.TemporaryDirectory() as directory:
                with patch.object(sys, "argv", [str(path), "/synthetic-binary", directory]), \
                     patch("subprocess.run") as run:
                    exec(compile(code, str(path), "exec"), {})
                args, kwargs = run.call_args
                self.assertEqual(args[0][0], "/synthetic-binary")
                self.assertIs(kwargs["check"], True)
                self.assertGreaterEqual(kwargs["timeout"], 120)
                planner = json.loads(Path(kwargs["env"]["PERCH_DATA"]).read_text())
                self.assertIs(planner["preferences"]["catchCopies"], False)
                self.assertIs(planner["preferences"]["catchScreenshots"], False)
                for failure in (subprocess.CalledProcessError(1, "probe"),
                                subprocess.TimeoutExpired("probe", kwargs["timeout"])):
                    with patch.object(sys, "argv", [str(path), "/synthetic-binary", directory]), \
                         patch("subprocess.run", side_effect=failure), self.assertRaises(type(failure)):
                        exec(compile(code, str(path), "exec"), {})

    def test_integration_accumulator_keeps_every_failure(self):
        swift = shutil.which("swiftc")
        assert swift is not None, "Swift is required for accumulator controls"
        source = (ROOT / "scripts/integration_probe.swift").read_text()
        code = source[source.index("@MainActor\nenum MatrixChecks"):source.index("@MainActor\nfunc matrixSettle")]
        program = 'import Foundation\n' + code + '''
@main struct Entry {
    @MainActor static func main() {
        matrixRequire(false, "first red")
        matrixRequire(true, "green")
        matrixRequire(false, "second red")
        precondition(MatrixChecks.failures == ["first red", "second red"])
        precondition(MatrixChecks.passed == ["green"])
        exit(MatrixChecks.failures.isEmpty ? 0 : 1)
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.swift"
            path.write_text(program)
            binary = Path(directory) / "control"
            built = subprocess.run([swift, "-swift-version", "6", "-parse-as-library", str(path), "-o", str(binary)],
                                   capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 1)
            self.assertIn("first red", run.stderr)
            self.assertIn("second red", run.stderr)


if __name__ == "__main__":
    unittest.main()
