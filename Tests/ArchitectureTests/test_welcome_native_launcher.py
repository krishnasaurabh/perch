"""Welcome's exact-copy probe must own a native app lifecycle."""
import ast
from pathlib import Path
import re
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / "Tests/PerchAppTests/WelcomeNativeLauncherTests.swift"
PROBE = ROOT / "Tests/PerchAppTests/WelcomeNativeProbe.swift"


class WelcomeNativeLauncherTests(unittest.TestCase):
    def test_xctest_launches_the_real_view_outside_the_test_runner(self):
        source = LAUNCHER.read_text()
        for required in (
            '"WelcomeNativeProbe.swift"', '"Package.swift", "Sources", "Tests"',
            '"Sources/Perch/main.swift"', '"\\nWelcomeNativeProbe.run()\\n"',
            'process.terminationReason, .exit', 'process.terminationStatus, 0',
            'result.contains("PASS: Welcome native accessibility copy")',
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
        self.assertIn("rootView: WelcomeView {}.environmentObject(store)", source)
        self.assertNotRegex(source, r"(?m)^WelcomeNativeProbe\.run\(\)")

    def test_every_required_string_and_both_negatives_remain_exact(self):
        source = PROBE.read_text()
        expected = [
            "A calmer way through a busy day",
            "Perch sits in your Mac's notch. Three small habits do most of the work.",
            "Write it down", "Give it time", "Park the rest",
            "Start with three things", "Look around first",
            "Click the notch for everything", "Hover for a quick peek",
            "Nothing to allow yet", "Calendar", "Notifications", "Microphone",
            "Your tasks stay on this Mac.",
        ]
        required = re.search(r"private static let requiredCopy = (\[.*?\])", source, re.S)
        forbidden = re.search(r"private static let forbiddenCopy = (\[.*?\])", source, re.S)
        self.assertIsNotNone(required)
        self.assertIsNotNone(forbidden)
        assert required is not None and forbidden is not None
        self.assertEqual(ast.literal_eval(required.group(1)), expected)
        self.assertEqual(ast.literal_eval(forbidden.group(1)), ["Add new screenshots to Clips", "Allow"])
        self.assertIn("missing = requiredCopy.filter { !observed.contains($0) }", source)
        self.assertIn("forbidden = forbiddenCopy.filter { observed.contains($0) }", source)
        self.assertIn("if !forbidden.isEmpty { break }", source)
        self.assertIn("if missing.isEmpty { return }", source)
        self.assertIn("throw WelcomeCopyError.invalidCopy", source)
        self.assertIn("dumpAccessibility(in: window)", source)
        self.assertNotIn("XCTSkip", source)

    def test_native_host_primes_before_constructing_the_real_view(self):
        source = PROBE.read_text()
        self.assertTrue(source.startswith("#if WELCOME_NATIVE_PROBE\n"))
        self.assertIn(".environment(\\.accessibilityEnabled, true)", source)
        self.assertIn("preferences: MemoryPlannerPreferences()", source)
        self.assertIn("watching: false", source)
        self.assertLess(source.index("await primeAccessibility()"), source.index("rootView: WelcomeView"))
        self.assertIn("DispatchQueue.global().async", source)
        self.assertIn("AXUIElementCreateApplication(getpid())", source)
        self.assertIn('primer.title = "Welcome accessibility fixture"', source)
        for edge in ("accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"):
            self.assertIn(edge, source)
        self.assertIn("view.subviews", source)
        self.assertIn("window.contentView", source)
        self.assertIn("seen.insert(ObjectIdentifier(node)).inserted", source)
        self.assertIn("if let attributed = value as? NSAttributedString { return attributed.string }", source)

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
                            exec(compile(program, "welcome-launcher", "exec"), {})
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
                exec(compile(program, "welcome-launcher", "exec"), {})
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0][0][0], [
            "swift", "build", "--jobs", "2", "--package-path", "/fixture",
            "-Xswiftc", "-DWELCOME_NATIVE_PROBE", "-Xswiftc", "-enable-testing",
            "--product", "Perch",
        ])
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
                    exec(compile(program, "welcome-launcher", "exec"), {})
        self.assertEqual(len(calls), 3)


if __name__ == "__main__":
    unittest.main()
