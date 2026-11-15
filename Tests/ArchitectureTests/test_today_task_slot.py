"""Keep the Today task slot independent of empty/populated list content.

These source contracts do not execute SwiftUI geometry. The native focus-entry
probe separately checks exact capture-frame equality before/after population.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TodayTaskSlotTests(unittest.TestCase):
    def setUp(self):
        self.card = (ROOT / "Sources/PerchApp/Workspace/TasksCard.swift").read_text()

    def test_viewport_reserves_the_same_height_as_its_cap(self):
        self.assertRegex(
            self.card,
            r"\.frame\(minHeight: WorkspaceLayout\.contentHeight, "
            r"maxHeight: WorkspaceLayout\.contentHeight\)"
            r"\s*\.accessibilityIdentifier\(\s*\"today-task-viewport\"\)",
        )

    def test_scroll_content_reserve_does_not_depend_on_population(self):
        slot = self.card.split("GeometryReader { viewport in", 1)[1].split(
            "TaskComposer(day:", 1
        )[0]
        reserves = re.findall(r"\.frame\(minHeight: ([^,]+), alignment: \.bottom\)", slot)
        self.assertEqual(reserves, ["WorkspaceLayout.contentHeight"])
        self.assertIn("ForEach(shown)", slot)
        self.assertIn("ScrollView {", slot)


if __name__ == "__main__":
    unittest.main()
