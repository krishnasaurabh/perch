"""Keep layout probes on the current shell budget and legacy pages inset.

Native containment, focus, and pixel checks still run on macOS. These checks
catch a stale size API or lost inset before that run without weakening them.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class WorkspaceBudgetContractTests(unittest.TestCase):
    def test_compact_probe_uses_today_budget_and_runtime_band(self):
        source = (ROOT / "scripts/compact_home_probe.swift").read_text()
        check = source.split('"\\(scenario): capture fully inside compact shell"', 1)[1]
        check = check.split('"\\(scenario): actual geometry uses the compact budget"', 1)[0]
        self.assertIn("workspace.height", check)
        self.assertIn("WorkspaceLayout.preferredSize(", check)
        self.assertIn("page: .today", check)
        self.assertIn("menuBarHeight: geometry.workspacePresentation", check)
        self.assertRegex(check, r"\.height\)\s*< 1,")
        self.assertNotIn("preferredSize(notchHeight:", check)

    def test_legacy_pages_retain_their_insets_without_insetting_today_or_week(self):
        source = (ROOT / "Sources/PerchApp/Workspace/WorkspaceView.swift").read_text()
        pages = source.split("@ViewBuilder private var page:", 1)[1].split(
            "/// Runtime menu-bar height", 1)[0]
        self.assertIn("case .home: HomePage()", pages)
        for name, view in [("clips", "ClipsPage"), ("insights", "InsightsPage")]:
            branch = pages.split(f"case .{name}:", 1)[1].split("case .", 1)[0]
            self.assertRegex(branch, re.escape(view + "()") + r"\s*\.modifier\(WorkspaceLegacyPageInsets\(\)\)")
        self.assertNotIn("WorkspaceLegacyPageInsets", pages.split("case .clips:", 1)[0])
        insets = source.split("private struct WorkspaceLegacyPageInsets:", 1)[1].split(
            "/// Runtime", 1)[0]
        self.assertIn(".padding(.horizontal, ThemeTokens.gutter)", insets)
        self.assertIn(".padding(.bottom, WorkspaceLayout.bottomInset)", insets)
        self.assertIn(".environment(\\.colorScheme, .dark)", insets)


if __name__ == "__main__":
    unittest.main()
