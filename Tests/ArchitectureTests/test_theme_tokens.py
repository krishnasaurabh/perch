"""Shared token contract: all readable tiers, status hues and original boundaries remain gated."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("theme_contrast", ROOT / "scripts/theme_contrast.py")
assert SPEC is not None and SPEC.loader is not None
THEME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(THEME)


class ThemeContrastTests(unittest.TestCase):
    def test_permitted_palette_and_existing_boundary_coverage(self):
        rows = THEME.source_rows()
        identities = {(r['appearance'], r['name']) for r in rows}
        self.assertEqual(len(identities), len(rows))
        for mode in ('light', 'dark'):
            for name in ('cardStroke/card', 'inputStroke/resting', 'inputStroke/focused',
                         'inputStroke/miniComposer', 'rope/alternate', 'priority/card',
                         'tertiary/card readable', 'danger/alternate readable',
                         'text/control-pressed', 'input-text/alternate-focused', 'prominent-label'):
                self.assertIn((mode, name), identities)
            for name in ('planned-chart/lavender', 'completed-chart/lavender', 'completed-chart/planned-chart'):
                self.assertIn((mode, name), identities)
        self.assertIn(('light', 'focus-progress/track'), identities)
        self.assertTrue(all(r['ratio'] >= r['minimum'] for r in rows))

    def test_low_contrast_adjacent_series_are_rejected(self):
        original = Path.read_text
        def altered(path, *args, **kwargs):
            value = original(path, *args, **kwargs)
            return value.replace('chartPlanned: UInt32 = 0xFFFFFF', 'chartPlanned: UInt32 = 0x423F50') if path.name == 'ThemeTokens.swift' else value
        with patch.object(Path, 'read_text', altered), self.assertRaisesRegex(AssertionError, 'completed-chart/planned-chart'):
            THEME.source_rows()

    def test_graphic_pairs_match_production_callers(self):
        home = (ROOT / 'Sources/PerchApp/Workspace/HomeCards.swift').read_text()
        chart = (ROOT / 'Sources/PerchApp/Workspace/InsightsPage.swift').read_text()
        surface = (ROOT / 'Sources/PerchApp/Workspace/Components/CardSurface.swift').read_text()
        self.assertIn('Capsule().fill(Theme.chartPlanned)', home)
        self.assertIn('Capsule().fill(Theme.text)', home)
        self.assertIn('.card(.timer)', home)
        self.assertIn('case .timer: return Theme.lavender', surface)
        self.assertIn('self == .tile ? .dark : .light', surface)
        self.assertIn('color: Theme.chartPlanned', chart)
        self.assertIn('color: Theme.chartCompleted', chart)

    def test_low_contrast_tertiary_is_rejected(self):
        original = Path.read_text
        def altered(path, *args, **kwargs):
            value = original(path, *args, **kwargs)
            return value.replace('tertiary: 0x232924', 'tertiary: 0x666666') if path.name == 'ThemeTokens.swift' else value
        with patch.object(Path, 'read_text', altered), self.assertRaises(AssertionError):
            THEME.source_rows()

    def test_lost_production_boundary_is_rejected(self):
        original = Path.read_text
        def altered(path, *args, **kwargs):
            value = original(path, *args, **kwargs)
            return value.replace('Theme.inputStroke', 'Theme.tertiary') if path.name == 'TasksCard.swift' else value
        with patch.object(Path, 'read_text', altered), self.assertRaises(AssertionError):
            THEME.source_rows()


if __name__ == '__main__':
    unittest.main()
