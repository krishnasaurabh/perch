"""Keyboard fixture setup and portable restoration tests.

The integration launcher loads this file from its copied test tree so the
preference is set before the child initializes AppKit, not after it is cached.
"""
import subprocess
import unittest
from unittest.mock import patch


def run_with_keyboard_access(command, *, env, check, timeout):
    previous = subprocess.run(
        ["defaults", "read", "-g", "AppleKeyboardUIMode"],
        capture_output=True, text=True, check=False)
    if previous.returncode not in (0, 1):
        previous.check_returncode()
    value = previous.stdout.strip() if previous.returncode == 0 else None
    if value is not None and value not in {"0", "1", "2", "3"}:
        raise ValueError("Unrecognized prior keyboard access mode")
    try:
        subprocess.run(["defaults", "write", "-g", "AppleKeyboardUIMode", "-int", "3"], check=True)
        return subprocess.run(command, env=env, check=check, timeout=timeout)
    finally:
        restore = (["defaults", "delete", "-g", "AppleKeyboardUIMode"] if value is None else
                   ["defaults", "write", "-g", "AppleKeyboardUIMode", "-int", value])
        subprocess.run(restore, check=True)


class IntegrationKeyboardEnvironmentTests(unittest.TestCase):
    def invoke(self, previous: str | None = "0", child_error=None, setup_error=None):
        calls = []
        child_result = subprocess.CompletedProcess(["probe"], 0)

        def run(command, **kwargs):
            calls.append((command, kwargs))
            if command[:2] == ["defaults", "read"]:
                return subprocess.CompletedProcess(command, 1 if previous is None else 0, previous or "", "")
            if command == ["probe"]:
                if child_error:
                    raise child_error
                return child_result
            if setup_error and command == ["defaults", "write", "-g", "AppleKeyboardUIMode", "-int", "3"]:
                raise setup_error
            return subprocess.CompletedProcess(command, 0, "", "")

        with patch.object(subprocess, "run", side_effect=run):
            try:
                result = run_with_keyboard_access(["probe"], env={"PERCH_DATA": "fixture.json"}, check=True, timeout=180)
            except BaseException as error:
                return calls, error
        return calls, result

    def test_sets_global_mode_before_launch_and_preserves_child_options(self):
        calls, result = self.invoke()
        self.assertIsInstance(result, subprocess.CompletedProcess)
        self.assertEqual(calls[1][0], ["defaults", "write", "-g", "AppleKeyboardUIMode", "-int", "3"])
        self.assertTrue(calls[1][1]["check"])
        self.assertEqual(calls[2], (["probe"], {"env": {"PERCH_DATA": "fixture.json"}, "check": True, "timeout": 180}))

    def test_restores_each_existing_mode_after_success(self):
        for previous in ["0", "1", "2", "3"]:
            with self.subTest(previous=previous):
                calls, result = self.invoke(previous)
                self.assertIsInstance(result, subprocess.CompletedProcess)
                self.assertEqual(calls[-1][0], ["defaults", "write", "-g", "AppleKeyboardUIMode", "-int", previous])
                self.assertTrue(calls[-1][1]["check"])

    def test_removes_preference_when_it_was_absent(self):
        calls, result = self.invoke(None)
        self.assertIsInstance(result, subprocess.CompletedProcess)
        self.assertEqual(calls[-1][0], ["defaults", "delete", "-g", "AppleKeyboardUIMode"])

    def test_restores_preference_and_propagates_child_failure(self):
        error = subprocess.CalledProcessError(7, ["probe"])
        calls, result = self.invoke("2", child_error=error)
        self.assertIs(result, error)
        self.assertEqual(calls[-1][0][-1], "2")

    def test_restores_absence_and_propagates_timeout(self):
        error = subprocess.TimeoutExpired(["probe"], 180)
        calls, result = self.invoke(None, child_error=error)
        self.assertIs(result, error)
        self.assertEqual(calls[-1][0], ["defaults", "delete", "-g", "AppleKeyboardUIMode"])

    def test_does_not_launch_when_setup_fails(self):
        error = subprocess.CalledProcessError(1, ["defaults", "write"])
        calls, result = self.invoke("2", setup_error=error)
        self.assertIs(result, error)
        self.assertNotIn(["probe"], [command for command, _ in calls])
        self.assertEqual(calls[-1][0][-1], "2")

    def test_does_not_overwrite_an_unrecognized_prior_value(self):
        calls, result = self.invoke("not an integer")
        self.assertIsInstance(result, ValueError)
        self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
