"""Preserve bounded task scrolling and complete native geometry diagnostics."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class WorkspaceTaskViewportTests(unittest.TestCase):
    def test_legacy_task_viewport_is_capped_without_changing_shell_budget(self):
        card = (ROOT / "Sources/PerchApp/Workspace/TasksCard.swift").read_text()
        self.assertRegex(card, r"\.frame\(minHeight: 0, maxHeight: WorkspaceLayout\.contentHeight\)")
        self.assertIn('enclosing.setAccessibilityIdentifier("today-task-viewport")', card)
        self.assertNotRegex(card, r'\.accessibilityIdentifier\(\s*"today-task-viewport"\)')
        layout = (ROOT / "Sources/PerchUI/WorkspaceLayout.swift").read_text()
        self.assertIn("public static let contentHeight: CGFloat = 300", layout)
        self.assertIn("public static let sheetHeight: CGFloat = 510", layout)

    def test_probe_records_all_candidates_before_any_scenario_assertion(self):
        source = (ROOT / "scripts/compact_home_probe.swift").read_text()
        loop = source.split('for scenario in ["empty"', 1)[1].split("if !baseline {\n                    // Regression", 1)[0]
        self.assertLess(loop.index("recordGeometry("), loop.index("require("))
        for key in ('"workspaceHeight"', '"shell"', '"capture"', '"scrollCandidates"',
                    '"accessibilityIdentifier"', '"documentHeight"'):
            self.assertIn(key, source)
        self.assertIn('"layout-metrics.json"', source)
        self.assertIn('"geometry-diagnostics.json"', source)
        self.assertIn("GeometryDiagnostics.flush(output: output)", source)

    def test_probe_selection_never_guesses_leftmost_and_failure_is_terminal(self):
        source = (ROOT / "scripts/compact_home_probe.swift").read_text()
        self.assertNotIn("// Pick the leftmost scroll view", source)
        self.assertNotRegex(source, r"\.min\s*\{\s*\$0\.convert")
        self.assertIn("TaskViewportSelection.index", source)
        require = source.split("func require(", 1)[1].split("func settle()", 1)[0]
        self.assertIn("ProbeCheckLog.assertions.check", require)
        self.assertNotIn("exit(1)", require)
        ending = source.split('to: output.appendingPathComponent("layout-metrics.json"))', 1)[1]
        self.assertLess(ending.index("guard ProbeCheckLog.assertions.succeeded"),
                        ending.index('print("Compact Home layout probes passed.")'))
        self.assertIn("exit(1)", ending)
        for invariant in ("listFrame.height <= WorkspaceLayout.contentHeight",
                          "shell.contains(listFrame)", "!listFrame.intersects(capture)",
                          "visibleCapture.height >= 12 && shell.contains(visibleCapture)"):
            self.assertIn(invariant, source)


if __name__ == "__main__":
    unittest.main()
