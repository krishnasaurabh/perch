"""Keep product writes inside the typed command boundary."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MutationBoundaryTests(unittest.TestCase):
    def test_domain_identity_is_uuid_only(self):
        source = (ROOT / "Sources/PlannerCore/PlannerEngine.swift").read_text()
        self.assertIn("public internal(set) var planner: Planner", source)
        self.assertNotRegex(source, r"func (complete|reopen|rename|delete|move|update|snooze)\(_ ref: String")
        self.assertNotIn("localizedCaseInsensitiveContains", source)
        self.assertNotIn("uuidString.lowercased().hasPrefix", source)

    def test_app_and_mcp_do_not_write_raw_planners(self):
        for target in ("PerchApp", "PerchMCP", "PerchCLI"):
            for path in (ROOT / "Sources" / target).rglob("*.swift"):
                source = path.read_text()
                self.assertNotRegex(source, r"\bfile\.(mutate|save)\s*[(\{]", str(path))
                self.assertNotRegex(source, r"\b(e|engine|commands)\.planner\.\w+\s*=", str(path))
                self.assertNotIn("inout PlannerEngine", source, str(path))

    def test_view_appearance_does_not_materialize_or_carry(self):
        for path in (ROOT / "Sources/PerchApp/Workspace").glob("*.swift"):
            source = path.read_text()
            self.assertNotIn("applyRepeats", source)
            self.assertNotIn("applyCarryMode", source)
            self.assertNotIn("showsDays", source)
            self.assertNotRegex(source, r"onAppear\s*\{[^}]*materializeRepeats", str(path))

    def test_system_integrations_have_injectable_boundaries(self):
        for name in ("CalendarAccess", "RemindersAccess", "NotificationAccess", "PasteboardAccess"):
            source = (ROOT / "Sources/PerchApp/Services" / f"{name}.swift").read_text()
            self.assertIn(f"protocol {name}", source)
        pipeline = (ROOT / "Sources/PlannerCore/PlannerCommands.swift").read_text()
        self.assertIn("protocol PlannerClock", pipeline)
        self.assertIn("case user, background", pipeline)


if __name__ == "__main__":
    unittest.main()
