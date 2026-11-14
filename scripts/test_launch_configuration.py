"""Compile the real validator in all configurations, including optimized Release."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from check_release import TEST_FLAGS, assert_no_hooks

ROOT = Path(__file__).resolve().parents[1]


class LaunchConfigurationTests(unittest.TestCase):
    def test_compiled_configuration_matrix(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            main = root / "main.swift"
            main.write_text('''import Foundation
let args = Array(CommandLine.arguments.dropFirst())
do {
    try AppLaunchConfiguration.validate(arguments: args, environment: ProcessInfo.processInfo.environment)
} catch { exit(64) }
''')
            for variant in ("release", "DEBUG", "PERCH_TESTING"):
                binary = root / variant
                command = ["swiftc", "-swift-version", "6", "-O"]
                if variant != "release":
                    command += ["-D", variant]
                subprocess.run(command + [str(ROOT / "Sources/PlannerCore/AppLaunchConfiguration.swift"),
                                          str(main), "-o", str(binary)], check=True, capture_output=True)
                environment = dict(os.environ)
                environment.pop("PERCH_DATA", None)
                for key in tuple(environment):
                    if key.startswith("PERCH_MOTION_") or key == "PERCH_SCREENSHOT_FOLDER":
                        environment.pop(key)
                for args in ([], ["--mcp"]):
                    self.assertEqual(subprocess.run([binary, *args], env=environment).returncode, 0)
                for args in (["--demo"], ["--scenario", "three"], ["--motion-script", "out"], ["--check-localization"]):
                    self.assertEqual(subprocess.run([binary, *args], env=environment).returncode, 64)
                    with_data = dict(environment, PERCH_DATA=str(root / "planner.json"))
                    self.assertEqual(subprocess.run([binary, *args], env=with_data).returncode,
                                     64 if variant == "release" else 0)
                valid_previews = (["--appearance", "light"], ["--appearance", "dark"],
                                  ["--reduce-motion"], ["--open", "today"],
                                  ["--scenario", "today-running", "--open", "today"],
                                  ["--redesign-shots", "plan.json", "--appearance", "dark", "--reduce-motion"])
                invalid_previews = (["--appearance", "sepia"], ["--appearance"],
                                    ["--appearance", "light", "--appearance", "dark"],
                                    ["--open", ""], ["--open", "today", "--preview-open"],
                                    ["--redesign-shots", "plan.json", "--scenario", "three"],
                                    ["--reduce-motion", "--motion-script", "out", "--motion-policy", "normal"])
                for args in valid_previews:
                    self.assertEqual(subprocess.run([binary, *args], env=environment).returncode, 64)
                    self.assertEqual(subprocess.run([binary, *args], env=with_data).returncode,
                                     64 if variant == "release" else 0, args)
                for args in invalid_previews:
                    self.assertEqual(subprocess.run([binary, *args], env=with_data).returncode, 64, args)
                if variant == "release":
                    assert_no_hooks(binary)
                    for flag in TEST_FLAGS:
                        self.assertEqual(subprocess.run([binary, flag, "out"], env=environment).returncode, 64)
                else:
                    # Swift can encode short strings as instruction immediates; use behavior,
                    # not `strings`, as the positive control for compiled-in hooks.
                    environment["PERCH_DATA"] = str(root / "planner.json")
                    result = subprocess.run([binary, "--motion-script", "out", "--motion-policy", "normal"], env=environment)
                    self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
