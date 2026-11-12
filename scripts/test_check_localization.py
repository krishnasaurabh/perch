"""Portable negative controls for the packaged-executable localization check."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from check_localization import LOCALIZED, RAW_KEYS, check, run_check


class PackagedLocalizationCheckTests(unittest.TestCase):
    def test_runs_the_packaged_executable_with_isolated_storage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = subprocess.CompletedProcess([], 0, json.dumps(LOCALIZED), "")
            with patch("check_localization.subprocess.run", return_value=result) as run:
                run_check(root / "Perch.app", root / "data", LOCALIZED)
            args, kwargs = run.call_args
            self.assertEqual(args[0], [str(root / "Perch.app/Contents/MacOS/Perch"), "--check-localization"])
            self.assertEqual(kwargs["env"]["PERCH_DATA"], str(root / "data/planner.json"))
            self.assertEqual(kwargs["timeout"], 15)
            self.assertEqual(list((root / "data").iterdir()), [])

    def test_crash_raw_fallback_and_invalid_output_fail_the_positive_check(self):
        for result in (
            subprocess.CompletedProcess([], -5, "", "resource accessor trapped"),
            subprocess.CompletedProcess([], 0, json.dumps(RAW_KEYS), ""),
            subprocess.CompletedProcess([], 0, "not JSON", ""),
        ):
            with self.subTest(result=result), tempfile.TemporaryDirectory() as directory:
                with patch("check_localization.subprocess.run", return_value=result):
                    with self.assertRaises((AssertionError, json.JSONDecodeError)):
                        run_check(Path(directory) / "Perch.app", Path(directory) / "data", LOCALIZED)

    def test_storage_writes_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            def write_storage(*args, **kwargs):
                Path(kwargs["env"]["PERCH_DATA"]).write_text("{}")
                return subprocess.CompletedProcess([], 0, json.dumps(LOCALIZED), "")
            with patch("check_localization.subprocess.run", side_effect=write_storage):
                with self.assertRaisesRegex(AssertionError, "opened planner storage"):
                    run_check(Path(directory) / "Perch.app", Path(directory) / "data", LOCALIZED)

    def test_relocation_and_resource_removal_modify_only_the_copies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "source/Perch.app"
            resources = app / "Contents/Resources"
            for name in ("Perch_PerchApp.bundle", "Perch_PerchUI.bundle"):
                bundle = resources / name
                bundle.mkdir(parents=True)
                (bundle / "Localizable.json").write_text("{}")
            (resources / "Localizable.json").write_text("{}")
            observed = []
            def observe(candidate, data, expected):
                observed.append((candidate, expected))
                present = list((candidate / "Contents/Resources").rglob("Localizable.json"))
                self.assertEqual(len(present), {"original-data": 3, "data":
                    0 if expected == RAW_KEYS else (3 if candidate.parent.name == "relocated" else 1)}[data.name])
            with patch("check_localization.run_check", side_effect=observe):
                with patch("check_localization.subprocess.run") as signing:
                    check(app, root / "output")
            self.assertEqual([expected for _, expected in observed], [LOCALIZED, LOCALIZED, LOCALIZED, RAW_KEYS])
            self.assertEqual(len(list(resources.rglob("Localizable.json"))), 3)
            self.assertEqual(signing.call_count, 2)
            for call in signing.call_args_list:
                self.assertEqual(call.args[0][:4], ["codesign", "--force", "--sign", "-"])
                self.assertNotEqual(Path(call.args[0][-1]), app)


if __name__ == "__main__":
    unittest.main()
