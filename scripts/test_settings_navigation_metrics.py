"""Replay navigation instrumentation; this is not native AppKit verification."""
import ast
import re
import unittest
from pathlib import Path
from unittest.mock import Mock

import test_settings_theme_navigation as navigation_tests

ROOT = Path(__file__).resolve().parents[1]


class SettingsNavigationMetricsTests(unittest.TestCase):
    run_swift = navigation_tests.SettingsThemeNavigationTests.run_swift

    def test_wrapper_keeps_a_hard_240_second_process_guard(self):
        wrapper = (ROOT / "scripts/check_theme.sh").read_text()
        program = wrapper.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        tree = ast.parse(program)
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Attribute)
                 and isinstance(node.func.value, ast.Name)
                 and node.func.value.id == "subprocess" and node.func.attr == "run"]
        self.assertEqual(len(calls), 1)
        subprocess = Mock()
        env = {"PERCH_DATA": "synthetic-planner.json", "THEME_PROBE_OUTPUT": "synthetic-output"}
        expr = ast.Expression(calls[0])
        eval(compile(expr, "check_theme.sh", "eval"),
             {"subprocess": subprocess, "binary": "probe-binary", "env": env})
        subprocess.run.assert_called_once_with(
            ["probe-binary", "-AppleKeyboardUIMode", "3"], env=env, check=True, timeout=240)
        self.assertIn('check_probe_results.py" theme', wrapper)
        self.assertIn('theme_contrast.py" --pixels', wrapper)

    def test_capture_reports_actual_tabs_arrows_and_elapsed_time_once(self):
        source = (ROOT / "scripts/theme_probe.swift").read_text()
        measured = source.split("@MainActor func measureEffectiveStates(", 1)[1]
        start = measured.index("            if let pane = page.settingsPane {")
        end = measured.index("            await wakeControlAccessibility()", start)
        block = measured[start:end]
        self.assertIn("for _ in 0..<16", block)
        self.assertIn("arrowPresses: &arrowPresses", block)
        self.assertIn("ProcessInfo.processInfo.systemUptime", block)
        self.assertIn("fflush(nil)", block)
        program = r'''
import Foundation
class NSView {}
class NSWindow { func makeFirstResponder(_ responder: NSView?) {} }
enum SettingsView {
    enum Pane: String, CaseIterable { case general, notch, calendar, agents, data }
}
@MainActor class SettingsNavigation { var pane = SettingsView.Pane.general }
@MainActor enum Replay {
    static var tabTarget = 0
    static var tabs = 0
    static var arrows = 0
    static var extraArrow = 0
    static var navigation = SettingsNavigation()
}
@MainActor enum Measured {
    static func check(_ ok: Bool, _ message: String) { precondition(ok, message) }
}
@MainActor func key(_ code: Int, _ text: String, in window: NSWindow) {
    precondition(code == 48 && text == "\t")
    Replay.tabs += 1
}
@MainActor func settingsSidebarFocused(_ host: NSView, pane: SettingsView.Pane) -> Bool {
    Replay.tabs >= Replay.tabTarget && Replay.navigation.pane == pane
}
@MainActor func settle() async { await Task.yield() }
@MainActor func advanceSettingsSidebar(
    to pane: SettingsView.Pane, host: NSView, window: NSWindow,
    navigation: SettingsNavigation, label: String, arrowPresses: inout Int
) async -> Bool {
    let presses = 1 + Replay.extraArrow
    Replay.arrows += presses
    arrowPresses += presses
    navigation.pane = pane
    return true
}
@MainActor func capture(_ pane: SettingsView.Pane, tabs: Int, extraArrow: Int) async {
    Replay.tabTarget = tabs
    Replay.tabs = 0
    Replay.arrows = 0
    Replay.extraArrow = extraArrow
    Replay.navigation = SettingsNavigation()
    let navigation = Replay.navigation
    let page = (name: "settings-\(pane.rawValue)", settingsPane: Optional(pane))
    let label = "\(page.name) [fixture]"
    let window = NSWindow(), host = NSView()
''' + block + r'''
    precondition(Replay.tabs == tabs)
    precondition(navigation.pane == pane)
}
Task { @MainActor in
    for pane in SettingsView.Pane.allCases {
        for tabs in [0, 1, 16] {
            await capture(pane, tabs: tabs, extraArrow: tabs == 16 ? 1 : 0)
        }
    }
    exit(0)
}
dispatchMain()
'''
        output = self.run_swift(program)
        lines = output.splitlines()
        panes = ["general", "notch", "calendar", "agents", "data"]
        expected = [(pane, tabs, index * (2 if tabs == 16 else 1))
                    for index, pane in enumerate(panes) for tabs in (0, 1, 16)]
        self.assertEqual(len(lines), len(expected), output)
        for line, (pane, tabs, arrows) in zip(lines, expected):
            match = re.fullmatch(
                rf"MEASURED: settings-{pane} \[fixture\] navigation {tabs} tabs, "
                rf"{arrows} arrows, ([0-9.eE+\-]+) s", line)
            self.assertIsNotNone(match, line)
            assert match is not None
            self.assertGreaterEqual(float(match[1]), 0)


if __name__ == "__main__":
    unittest.main()
