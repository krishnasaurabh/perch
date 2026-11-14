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


class DesignTokenContractTests(unittest.TestCase):
    def test_new_palette_checks_every_permitted_pair(self):
        rows = THEME.design_rows()
        identities = {(r['appearance'], r['name']) for r in rows}
        self.assertEqual(len(identities), len(rows))
        for appearance in ('light', 'dark'):
            for surface in ('sheet', 'paper', 'butter', 'blush', 'apricot', 'mint', 'field'):
                for ink in ('ink', 'ink2', 'brandText', 'carried', 'doneText'):
                    self.assertIn((appearance, f'{ink}/{surface}'), identities)
                for graphic in ('focusRing', 'brandFill', 'doneFill'):
                    self.assertIn((appearance, f'{graphic}/{surface}'), identities)
            for surface in ('sheet', 'paper', 'butter', 'mint'):
                self.assertIn((appearance, f'ink3/{surface}'), identities)
        self.assertTrue(all(r['ratio'] >= r['minimum'] for r in rows))
        corrected = {(r['appearance'], r['name']) for r in rows if r['authored_foreground'] != r['foreground']}
        self.assertEqual(corrected, {('dark', 'onDone/doneFill'), ('light', 'brandText/apricot'), ('light', 'focusRing/band')})

    def test_low_contrast_design_token_is_rejected(self):
        original = Path.read_text
        def altered(path, *args, **kwargs):
            value = original(path, *args, **kwargs)
            return value.replace('light: 0x2A1B14', 'light: 0xAAAAAA') if path.name == 'DesignTokens.swift' else value
        with patch.object(Path, 'read_text', altered), self.assertRaises(AssertionError):
            THEME.design_rows()

    def test_legacy_opacity_token_is_independent_of_design_fade(self):
        source = (ROOT / 'Sources/PerchApp/Workspace/Motion.swift').read_text()
        tokens = (ROOT / 'Sources/PerchUI/DesignTokens.swift').read_text()
        self.assertIn('static let reduced = Animation.easeInOut(duration: 0.15)', source)
        self.assertIn('public static let reducedFade: Double = 0.12', tokens)
        fade = source.split('static func fadeKeyframes', 1)[1].split('static var reduceMotion', 1)[0]
        self.assertIn('duration: DesignTokens.Motion.reducedFade', fade)
        self.assertNotIn('Motion.reduced', fade.replace('DesignTokens.Motion.reducedFade', ''))

    def test_token_motion_keeps_component_identity(self):
        source = (ROOT / 'Sources/PerchApp/Workspace/Motion.swift').read_text()
        modifier = source.split('private struct DesignMotionModifier', 1)[1].split('private struct MotionBoundary', 1)[0]
        self.assertNotIn('.id(', modifier)
        self.assertIn('.keyframeAnimator(initialValue: 1.0, trigger: value)', modifier)
        self.assertIn('Motion.fadeKeyframes(reduceMotion: reduceMotion)', modifier)
        self.assertIn('.transaction { policy.enforce(on: &$0) }', modifier)
        self.assertIn('LinearKeyframe(1.0, duration: DesignTokens.Motion.reducedFade, timingCurve: .easeOut)', source)

    def test_font_resources_and_packaging(self):
        import struct
        import plistlib
        folder = ROOT / 'Sources/PerchUI/Resources/Fonts'
        expected = {'Lexend-Regular.ttf': 400, 'Lexend-Medium.ttf': 500,
                    'Lexend-SemiBold.ttf': 600, 'Lexend-Bold.ttf': 700}
        for filename, weight in expected.items():
            data = (folder / filename).read_bytes()
            self.assertEqual(data[:4], b'\x00\x01\x00\x00')
            count = struct.unpack_from('>H', data, 4)[0]
            tables = {data[o:o+4]: struct.unpack_from('>II', data, o+8)
                      for o in range(12, 12 + count * 16, 16)}
            offset, _ = tables[b'OS/2']
            self.assertEqual(struct.unpack_from('>H', data, offset + 4)[0], weight)
        for weight in ('Regular', 'Medium', 'SemiBold', 'Bold'):
            data = (folder / f'PerchText-{weight}.ttf').read_bytes()
            count = struct.unpack_from('>H', data, 4)[0]
            tables = {data[o:o+4]: struct.unpack_from('>II', data, o+8)
                      for o in range(12, 12 + count * 16, 16)}
            offset, _ = tables[b'hhea']
            horizontal_metrics = struct.unpack_from('>H', data, offset + 34)[0]
            offset, _ = tables[b'hmtx']
            advances = {struct.unpack_from('>H', data, offset + index * 4)[0]
                        for index in range(horizontal_metrics)}
            self.assertGreater(len(advances), 1)  # Text stays proportional.
            # A compact product table pins the actual digit advances without font libraries.
            cmap, _ = tables[b'cmap']
            subtables = struct.unpack_from('>H', data, cmap + 2)[0]
            chosen = None
            for index in range(subtables):
                _, _, relative = struct.unpack_from('>HHI', data, cmap + 4 + index * 8)
                if struct.unpack_from('>H', data, cmap + relative)[0] == 4:
                    chosen = cmap + relative
                    break
            self.assertIsNotNone(chosen)
            assert chosen is not None
            segments = struct.unpack_from('>H', data, chosen + 6)[0] // 2
            ends = chosen + 14
            starts = ends + segments * 2 + 2
            deltas = starts + segments * 2
            ranges = deltas + segments * 2
            widths = []
            for code in range(ord('0'), ord('9') + 1):
                for index in range(segments):
                    start = struct.unpack_from('>H', data, starts + index * 2)[0]
                    end = struct.unpack_from('>H', data, ends + index * 2)[0]
                    if start <= code <= end:
                        delta = struct.unpack_from('>h', data, deltas + index * 2)[0]
                        distance = struct.unpack_from('>H', data, ranges + index * 2)[0]
                        glyph = ((code + delta) & 65535) if distance == 0 else struct.unpack_from(
                            '>H', data, ranges + index * 2 + distance + (code - start) * 2)[0]
                        if distance and glyph:
                            glyph = (glyph + delta) & 65535
                        widths.append(struct.unpack_from('>H', data, offset + min(glyph, horizontal_metrics - 1) * 4)[0])
                        break
            self.assertEqual(len(widths), 10)
            self.assertEqual(len(set(widths)), 1, weight)
        self.assertIn('SIL OPEN FONT LICENSE Version 1.1', (folder / 'OFL.txt').read_text())
        self.assertEqual(plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())['ATSApplicationFontsPath'], 'Fonts')
        self.assertIn('.copy("Resources/Fonts")', (ROOT / 'Package.swift').read_text())
        self.assertIn('Resources/Fonts/', (ROOT / 'scripts/bundle.sh').read_text())


if __name__ == '__main__':
    unittest.main()
