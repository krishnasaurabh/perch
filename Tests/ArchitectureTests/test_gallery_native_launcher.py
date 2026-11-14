"""The gallery's real-view action probe must own a native app lifecycle."""
import ast
from pathlib import Path
import re
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / "Tests/PerchAppTests/GalleryInteractionTests.swift"
PROBE = ROOT / "Tests/PerchAppTests/GalleryNativeProbe.swift"


class GalleryNativeLauncherTests(unittest.TestCase):
    def test_xctest_launches_the_real_view_outside_the_test_runner(self):
        source = LAUNCHER.read_text()
        for required in (
            '"GalleryNativeProbe.swift"', '"Package.swift", "Sources", "Tests"',
            '"Sources/Perch/main.swift"', '"\\nGalleryNativeProbe.run()\\n"',
            'process.terminationReason, .exit', 'process.terminationStatus, 0',
            'result.contains("PASS: Gallery native actions and visible state")',
        ):
            self.assertIn(required, source)
        self.assertNotIn("NSHostingView", source)
        self.assertNotIn("XCTSkip", source)

    def test_native_probe_has_a_real_lifecycle_and_bounded_key_window_requirement(self):
        source = PROBE.read_text()
        self.assertIn("app.setActivationPolicy(.regular)", source)
        self.assertIn("app.run()", source)
        self.assertIn("Bundle.main.bundleIdentifier == nil", source)
        self.assertIn("window.isKeyWindow", source)
        self.assertIn("ContinuousClock.now + .seconds(3)", source)
        self.assertIn("await activateKeyWindow(window)", source)
        self.assertIn("exit(1)", source)
        self.assertIn("GalleryPage(page: .motion)", source)
        self.assertNotRegex(source, r"(?m)^GalleryNativeProbe\.run\(\)")

    def test_build_and_execution_failures_cannot_be_ignored(self):
        source = LAUNCHER.read_text()
        match = re.search(r'#"""\n(.*?)\n\s*"""#', source, re.S)
        assert match is not None
        program = match.group(1)
        program = ast.parse(__import__("textwrap").dedent(program))
        for failing_call in (1, 2, 3):
            calls = []

            def checked(*args, **kwargs):
                calls.append((args, kwargs))
                if len(calls) == failing_call:
                    raise subprocess.CalledProcessError(1, args[0])
                return "/fixture/bin\n"

            fake_subprocess = SimpleNamespace(run=checked, check_output=checked)
            with self.subTest(failing_call=failing_call):
                with patch.dict(sys.modules, subprocess=fake_subprocess):
                    with patch.object(sys, "argv", ["launcher", "/fixture"]):
                        with self.assertRaises(subprocess.CalledProcessError):
                            exec(compile(program, "gallery-launcher", "exec"), {})
                self.assertEqual(len(calls), failing_call)
                for args, kwargs in calls:
                    self.assertGreater(kwargs["timeout"], 0)
                    if args[0][:2] != ["swift", "build"] or "--show-bin-path" not in args[0]:
                        self.assertIs(kwargs["check"], True)

    def test_success_uses_the_built_executable_and_isolated_storage(self):
        source = LAUNCHER.read_text()
        match = re.search(r'#"""\n(.*?)\n\s*"""#', source, re.S)
        assert match is not None
        program = ast.parse(__import__("textwrap").dedent(match.group(1)))
        calls = []

        def checked(*args, **kwargs):
            calls.append((args, kwargs))
            return "/fixture/bin\n"

        fake_subprocess = SimpleNamespace(run=checked, check_output=checked)
        with patch.dict(sys.modules, subprocess=fake_subprocess):
            with patch.object(sys, "argv", ["launcher", "/fixture"]):
                exec(compile(program, "gallery-launcher", "exec"), {})
        self.assertEqual(len(calls), 3)
        self.assertIn("-DGALLERY_NATIVE_PROBE", calls[0][0][0])
        self.assertEqual(calls[2][0][0], ["/fixture/bin/Perch"])
        self.assertEqual(calls[2][1]["env"]["PERCH_DATA"], "/fixture/data")

    def test_runtime_timeout_propagates_instead_of_becoming_a_pass(self):
        source = LAUNCHER.read_text()
        match = re.search(r'#"""\n(.*?)\n\s*"""#', source, re.S)
        assert match is not None
        program = ast.parse(__import__("textwrap").dedent(match.group(1)))
        calls = []

        def checked(*args, **kwargs):
            calls.append((args, kwargs))
            if len(calls) == 3:
                raise subprocess.TimeoutExpired(args[0], kwargs["timeout"])
            return "/fixture/bin\n"

        fake_subprocess = SimpleNamespace(run=checked, check_output=checked)
        with patch.dict(sys.modules, subprocess=fake_subprocess):
            with patch.object(sys, "argv", ["launcher", "/fixture"]):
                with self.assertRaises(subprocess.TimeoutExpired):
                    exec(compile(program, "gallery-launcher", "exec"), {})
        self.assertEqual(len(calls), 3)


if __name__ == "__main__":
    unittest.main()
