"""The display regression must exercise the real pane in a native process."""
import ast
from pathlib import Path
import re
import subprocess
import sys
import textwrap
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Tests/PerchAppTests/SettingsDisplaySelectionTests.swift"
CASES = (
    "testStoredBuiltInIsSelectedAndAutomaticPersistsNil",
    "testDisconnectedDisplaySurvivesRenderingAndAutomaticClearsIt",
    "testAttachedExternalDisplayUsesItsExactName",
    "testDisconnectedBuiltInRetainsRawValueWithoutOfferingBuiltInChoice",
)


def launcher_program():
    match = re.search(r'#"""\n(.*?)\n\s*"""#', SOURCE.read_text(), re.S)
    assert match is not None
    return compile(ast.parse(textwrap.dedent(match.group(1))), "display-launcher", "exec")


class SettingsDisplayLauncherTests(unittest.TestCase):
    def test_four_native_cases_and_persistence_checks_remain_required(self):
        source = SOURCE.read_text()
        native, launcher = source.split("#else", 1)
        for case in CASES:
            with self.subTest(case=case):
                self.assertIn(f"try await {case}()", native)
                self.assertIn(f"static func {case}()", native)
                self.assertIn(f'"{case}"', launcher)
        for required in (
            "SettingsNotchPane(displays: { displays })",
            "app.setActivationPolicy(.regular)", "app.run()",
            "Bundle.main.bundleIdentifier == nil", "window.isKeyWindow",
            "let before = adapter.load()", "equal(adapter.load(), before,",
            "menu.performActionForItem(at: match.offset)",
            "equal(picker.titleOfSelectedItem, title,",
            "equal(store.prefs.showOnDisplay, expected,",
            "equal(try store.file.load().preferences.showOnDisplay, expected,",
            "equal(restored.prefs.showOnDisplay, expected,",
            "JSONDecoder().decode(DevicePreferences.self, from: encoded)",
        ):
            self.assertIn(required, native)
        self.assertEqual(native.count("try assertPersisted(nil, store: store, adapter: adapter)"), 4)
        for forbidden in ("picker.select(", "picker.sendAction(", "XCTSkip", "try? assertPersisted", "try? await check"):
            self.assertNotIn(forbidden, source)
        self.assertNotIn("XCTUnwrap(adapter.load())", source)
        self.assertIn("process.terminationReason, .exit", launcher)
        self.assertIn("process.terminationStatus, 0", launcher)
        self.assertIn('filter { $0 == "PASS: \\(name)" }.count, 1', launcher)

    def test_success_runs_built_app_with_isolated_storage_and_keyboard_mode(self):
        calls = []

        def checked(*args, **kwargs):
            calls.append((args, kwargs))
            return "/fixture/bin\n"

        fake = SimpleNamespace(run=checked, check_output=checked)
        with patch.dict(sys.modules, subprocess=fake), patch.object(sys, "argv", ["launcher", "/fixture"]):
            exec(launcher_program(), {})
        self.assertEqual(len(calls), 3)
        self.assertIn("-DSETTINGS_DISPLAY_SELECTION_PROBE", calls[0][0][0])
        self.assertIn("-enable-testing", calls[0][0][0])
        self.assertEqual(calls[2][0][0], ["/fixture/bin/Perch", "-AppleKeyboardUIMode", "3"])
        self.assertEqual(calls[2][1]["env"]["PERCH_DATA"], "/fixture/data")
        for args, kwargs in calls:
            self.assertGreater(kwargs["timeout"], 0)
            if "--show-bin-path" not in args[0]:
                self.assertIs(kwargs["check"], True)

    def test_failure_and_timeout_at_every_subprocess_propagate(self):
        for failing_call in (1, 2, 3):
            for error in (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                calls = []

                def checked(*args, **kwargs):
                    calls.append((args, kwargs))
                    if len(calls) == failing_call:
                        if error is subprocess.TimeoutExpired:
                            raise subprocess.TimeoutExpired(args[0], kwargs["timeout"])
                        raise subprocess.CalledProcessError(1, args[0])
                    return "/fixture/bin\n"

                with self.subTest(failing_call=failing_call, error=error):
                    fake = SimpleNamespace(run=checked, check_output=checked)
                    with patch.dict(sys.modules, subprocess=fake), patch.object(
                        sys, "argv", ["launcher", "/fixture"]
                    ):
                        with self.assertRaises(error):
                            exec(launcher_program(), {})
                    self.assertEqual(len(calls), failing_call)


if __name__ == "__main__":
    unittest.main()
