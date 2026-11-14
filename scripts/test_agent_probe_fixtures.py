"""Check native probe permission seeds without running a native app."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parent


class BeforeNativeLaunch(BaseException):
    """Stop after the actual fixture initializer has written its data."""


class AgentProbeFixtureTests(unittest.TestCase):
    def test_crash_probe_explicitly_allows_its_timer_setup(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as directory:
            def before_launch(*args, **kwargs):
                seed = json.loads(Path(kwargs["env"]["PERCH_DATA"]).read_text())
                self.assertIs(seed["preferences"].get("agentsCanControlTime"), True)
                self.assertNotIn("agentsCanReadParkingLot", seed["preferences"])
                self.assertNotIn("confirmAgentDeletes", seed["preferences"])
                self.assertIs(seed["preferences"]["catchCopies"], False)
                self.assertIs(seed["preferences"]["catchScreenshots"], False)
                raise BeforeNativeLaunch

            with patch.object(sys, "argv", ["focus_crash_check.py", "unused-app", directory]), \
                    patch("subprocess.Popen", side_effect=before_launch), \
                    self.assertRaises(BeforeNativeLaunch):
                runpy.run_path(str(SCRIPTS / "focus_crash_check.py"), run_name="__main__")

    def test_homecards_probe_seeds_permissions_before_mcp_setup(self):
        # Execute the real shell preamble, stopping before the first native call.
        source = (SCRIPTS / "homecards_shots.sh").read_text()
        preamble, separator, _ = source.partition('PERCH_DATA="$SRC" "$APP" --mcp')
        self.assertTrue(separator, "The native launch boundary must remain identifiable")
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as directory:
            result = subprocess.run(
                ["bash", "-c", preamble, "homecards_shots.sh", directory],
                cwd=directory, capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            seed_path = Path(directory) / "seed.json"
            self.assertTrue(seed_path.exists(), "Permissions must be seeded before MCP starts")
            seed = json.loads(seed_path.read_text())
            self.assertIs(seed["preferences"].get("agentsCanControlTime"), True)
            self.assertIs(seed["preferences"].get("agentsCanReadParkingLot"), True)
            self.assertNotIn("confirmAgentDeletes", seed["preferences"])
            messages = [json.loads(line) for line in (Path(directory) / "seed.jsonl").read_text().splitlines()]
            calls = [message["params"]["name"] for message in messages if message["method"] == "tools/call"]
            self.assertEqual(calls, ["add_tasks", "start_timer", "pause_timer", "write_notepad"])


if __name__ == "__main__":
    unittest.main()
