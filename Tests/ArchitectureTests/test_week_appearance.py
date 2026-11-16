"""Source contracts for Week appearance; rendered pixels require native visual QA."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Sources/PerchApp"


class WeekAppearanceTests(unittest.TestCase):
    def test_week_board_inherits_workspace_appearance(self):
        source = (APP / "Workspace/WorkspaceView.swift").read_text()
        page = source.split("@ViewBuilder private var page: some View {", 1)[1].split(
            "/// Runtime menu-bar height", 1)[0]
        week_host = page.split("case .week:", 1)[1].split("case .clips:", 1)[0]
        self.assertIn("DotGridSheet {", week_host)
        self.assertIn("WeekPage(workspaceShell: true)", week_host)
        self.assertNotIn(r"\.colorScheme", week_host,
                         "The production Week host must inherit the workspace appearance")
        self.assertNotIn(".preferredColorScheme", week_host)

    def test_light_appearance_flows_through_the_adaptive_sheet_to_the_board(self):
        source = (APP / "Workspace/WorkspaceView.swift").read_text()
        body = source.split("var body: some View {", 1)[1].split(
            "@ViewBuilder private var page:", 1)[0]
        self.assertIn("page.id(model.page)", body)
        self.assertIn(r".environment(\.colorScheme, PreviewAppearance.scheme ?? sheetScheme)", body)
        self.assertIn("WorkspaceAppearanceBridge { sheetScheme = $0 }", body)
        bridge = source.split("private struct WorkspaceAppearanceBridge:", 1)[1].split(
            "#if DEBUG || PERCH_TESTING", 1)[0]
        self.assertIn("let appearance = NSApp.effectiveAppearance", bridge)
        self.assertIn(
            "appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light", bridge)
        self.assertIn("self?.changed?(scheme)", bridge)

        preview = (APP / "App/AppDelegate+Preview.swift").read_text().split(
            "enum PreviewAppearance {", 1)[1]
        self.assertIn('guard let name = AppDelegate.previewOption("--appearance") else { return nil }', preview)
        self.assertIn('return name == "dark" ? .dark : .light', preview)

        week = (APP / "Workspace/WeekPage.swift").read_text()
        self.assertIn("if workspaceShell { WeekBoard() } else { LegacyWeekPage() }", week)
        for component in (week, (APP / "Workspace/Components/DotGridSheet.swift").read_text()):
            self.assertNotIn(r"\.colorScheme", component)
            self.assertNotIn(".preferredColorScheme", component)


if __name__ == "__main__":
    unittest.main()
