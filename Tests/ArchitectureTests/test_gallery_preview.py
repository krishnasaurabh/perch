"""The component gallery stays isolated from the everyday workspace."""
from pathlib import Path
import re
import shlex
import unittest

ROOT = Path(__file__).resolve().parents[2]
GALLERY = ROOT / "Sources/PerchApp/Workspace/GalleryPage.swift"


class GalleryPreviewTests(unittest.TestCase):
    def test_gallery_is_preview_only_and_registered_once(self):
        source = GALLERY.read_text()
        self.assertIn("#if DEBUG || PERCH_TESTING", source)
        registry = (ROOT / "Sources/PerchApp/App/AppDelegate+Preview.swift").read_text()
        self.assertEqual(registry.count('"gallery":'), 1)
        self.assertIn('GalleryPage.show()', registry)
        self.assertNotIn("PlannerStore", source)
        self.assertNotIn("performMutation", source)
        self.assertNotIn("Timer.publish", source)

    def test_both_pages_are_captured_by_the_same_preview_target(self):
        rows = {}
        for line in (ROOT / "scripts/redesign_shots.list").read_text().splitlines():
            words = shlex.split(line, comments=True)
            if words:
                rows[words[0]] = words[1:]
        self.assertEqual(rows["system"], ["--scenario", "empty", "--open", "gallery"])
        self.assertEqual(rows["motion"], ["--scenario", "timer", "--open", "gallery"])

    def test_gallery_reuses_foundations_and_routes_motion_through_tokens(self):
        source = GALLERY.read_text()
        for component in ("DotGridSheet", "Card(", "PerchButton(", "PerchCheckbox(",
                          "PerchSwitch(", "PerchSegmented(", "PerchPill(" ):
            self.assertIn(component, source)
        self.assertIn(".designMotion(", source)
        for forbidden in (".animation(", "withAnimation(", "ViewThatFits", ".font(.system", "Color(hex:"):
            self.assertNotIn(forbidden, source)
        self.assertNotRegex(source, r"(?:\.frame\([^)]*(?:width|height)|cornerRadius|spacing|duration):\s*\d")

    def test_checklist_has_one_keyboard_stop_and_navigation(self):
        source = GALLERY.read_text()
        self.assertIn("keyboardFocusable: false", source)
        self.assertIn(".focused($checklistFocused)", source)
        for key in (".upArrow", ".downArrow", ".home", ".end", ".space"):
            self.assertIn(f".onKeyPress({key})", source)


if __name__ == "__main__":
    unittest.main()
