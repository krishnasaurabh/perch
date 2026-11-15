import json
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_select as s  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


class SelectTests(unittest.TestCase):
    def test_core_only_change_skips_macos(self):
        r = s.select(["Sources/PlannerCore/TaskCapture.swift", "Tests/PlannerCoreTests/TaskCaptureTests.swift"])
        self.assertFalse(r["full"])
        self.assertFalse(r["macos"])
        self.assertEqual(r["suites"], [])

    def test_week_change_runs_week_probes_and_skips_unrelated_native_tests(self):
        r = s.select(["Sources/PerchApp/Workspace/WeekPage.swift"])
        self.assertFalse(r["full"])
        self.assertTrue(r["macos"])
        self.assertIn("week", r["suites"])
        self.assertIn("week_inbox", r["suites"])
        self.assertNotIn("WeekInboxKeyboardTests", r["skip_native"])
        self.assertIn("GalleryInteractionTests", r["skip_native"])
        self.assertTrue(r["layout"])
        self.assertFalse(r["behavior"])

    def test_undo_change_runs_undo_probe(self):
        r = s.select(["Sources/PlannerCore/PlannerUndo.swift"])
        self.assertEqual(r["suites"], ["undo"])
        self.assertTrue(r["behavior"])

    def test_unmapped_source_fails_open_to_full(self):
        r = s.select(["Sources/PerchApp/Workspace/BrandNewPage.swift"])
        self.assertTrue(r["full"])
        r = s.select(["Sources/NewModule/Thing.swift"])
        self.assertTrue(r["full"])
        self.assertEqual(r["skip_native"], "")

    def test_plumbing_runs_full(self):
        for path in ["Package.swift", ".github/workflows/ci.yml", "scripts/bundle.sh", "Sources/Perch/main.swift"]:
            self.assertTrue(s.select([path])["full"], path)

    def test_full_never_skips_and_includes_evidence(self):
        r = s.plan(full=True, reason="x")
        self.assertEqual(r["skip_native"], "")
        self.assertIn("motion_evidence", r["suites"])
        self.assertIn("large_desktop", r["suites"])

    def test_targeted_never_includes_full_only_suites(self):
        r = s.select(["scripts/motion_capture.sh", "Sources/PerchApp/Notch/NotchRootView.swift"])
        self.assertNotIn("motion_evidence", r["suites"])

    def test_docs_only(self):
        r = s.select(["README.md", "docs/guide.md"])
        self.assertFalse(r["macos"])

    def test_every_source_file_is_mapped(self):
        files = subprocess.check_output(["git", "ls-files", "Sources", "Tests", "scripts", "Resources"],
                                        cwd=ROOT, text=True).split()
        unmapped = [f for f in files if not s.matches(f, s.FULL_TRIGGERS) and not s.matches(f, s.CORE_ONLY)
                    and not any(s.matches(f, pats) for pats, _ in s.RULES)]
        # Unmapped files run the full suite, which is safe but slow: keep the list short and deliberate.
        self.assertLessEqual(len(unmapped), 10, unmapped)

    def test_full_due_every_ten(self):
        self.assertTrue(s.full_due([False] * 9))
        self.assertFalse(s.full_due([False] * 8 + [True]))
        self.assertFalse(s.full_due([True] + [False] * 8))
        self.assertTrue(s.full_due([]))

    def test_push_base_is_newest_verified_commit(self):
        history = [("c3", set()), ("c2", {"Main verified"}), ("c1", {"Main verified", "Full suite"})]
        self.assertEqual(s.push_base(history), "c2")
        self.assertEqual(s.push_base([("c3", set())]), "")

    def test_skip_regex_names_real_test_classes(self):
        for cls in s.NATIVE.values():
            self.assertTrue((ROOT / "Tests/PerchAppTests" / f"{cls}.swift").exists(), cls)

    def test_ci_workflow_names_every_suite(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        for suite in set(s.BEHAVIOR) | set(s.LAYOUT):
            self.assertIn(f"'{suite}') }}}}", workflow, suite)

    def test_cli_writes_outputs(self):
        out = subprocess.check_output([sys.executable, str(ROOT / "scripts/ci_select.py"), "--event",
                                       "workflow_dispatch", "--force-full", "true"], cwd=ROOT, text=True)
        self.assertTrue(json.loads(out)["full"])


if __name__ == "__main__":
    unittest.main()
