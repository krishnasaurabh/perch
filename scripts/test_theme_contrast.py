"""Synthetic scanner controls; real SwiftUI images are checked separately by check_theme.sh."""
import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image, ImageDraw
import theme_contrast


class ControlPixelTests(unittest.TestCase):
    def fixture(self, directory):
        entries = []
        for appearance in ('light', 'dark'):
            for contrast in ('standard', 'increased'):
                for tone in ('sage', 'lavender', 'tile'):
                    light = tone != 'tile'
                    surface = {'sage': '#879E8D', 'lavender': '#938EAB', 'tile': '#1D1D1D'}[tone]
                    fill = '#9DADA1' if light else '#242424'
                    ink = '#090C0A' if light else '#F5F7F5'
                    ring = '#09263F' if light else '#90C7FF'
                    for state in ('rest', 'focused', 'disabled'):
                        for scale in (1, 2):
                            image = Image.new('RGB', (528, 318), surface)
                            draw = ImageDraw.Draw(image)
                            draw.rectangle((40, 100, 140, 131), fill=fill)
                            draw.rectangle((180, 100, 300, 131), fill=fill)
                            glyphs = Image.new('1', image.size)
                            ImageDraw.Draw(glyphs).text((190, 108), 'Unavailable', fill=1)
                            image.paste(ink, (0, 0), glyphs)
                            if state == 'focused':
                                draw.rectangle((36, 96, 144, 135), outline=ring, width=2)
                            name = f'{appearance}-{contrast}-{tone}-{state}-{scale}x.png'
                            image.resize((528 * scale, 318 * scale), Image.Resampling.NEAREST).save(directory / name)
                            entries.append({'file': name, 'tone': tone, 'state': state, 'scale': scale,
                                            'focused_control': 'continue' if state == 'focused' else 'before-pages',
                                            'frames': {'continue': [40, 100, 100, 32], 'unavailable': [180, 100, 120, 32]}})
        (directory / 'controls.json').write_text(json.dumps(entries))
        return entries

    def test_focus_identity_must_match_capture_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            rows = self.fixture(directory)
            for missing in (False, True):
                with self.subTest(missing=missing):
                    if missing:
                        rows[2].pop('focused_control', None)
                    else:
                        rows[2]['focused_control'] = 'segment-Today'
                    (directory / 'controls.json').write_text(json.dumps(rows))
                    with self.assertRaisesRegex(AssertionError, 'focus identity'):
                        theme_contrast.control_pixels(directory)

    def test_explicit_rendered_ring_does_not_claim_keyboard_focus(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            rows = self.fixture(directory)
            row = next(row for row in rows if row['state'] == 'focused')
            row.update(focused_control='after-pages', focus_evidence='rendered-ring',
                       focus_ring_target='continue', keyboardActivation='unverified-on-this-runner')
            (directory / 'controls.json').write_text(json.dumps(rows))
            self.assertEqual(len(theme_contrast.control_pixels(directory)), 72)
            for field, invalid in [('focus_ring_target', 'segment-Today'),
                                   ('keyboardActivation', 'verified-in-process-Tab-Space'),
                                   ('focused_control', '')]:
                with self.subTest(field=field):
                    original = row[field]
                    row[field] = invalid
                    (directory / 'controls.json').write_text(json.dumps(rows))
                    with self.assertRaises(AssertionError):
                        theme_contrast.control_pixels(directory)
                    row[field] = original
            (directory / 'controls.json').write_text(json.dumps(rows))
            target = directory / row['file']
            image = Image.open(target)
            ImageDraw.Draw(image).rectangle((36, 96, 144, 99), fill='#879E8D')
            image.save(target)
            with self.assertRaisesRegex(AssertionError, 'focus ring missing'):
                theme_contrast.control_pixels(directory)

    def test_complete_matrix_and_negative_controls(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            rows = self.fixture(directory)
            self.assertEqual(len(theme_contrast.control_pixels(directory)), 72)
            target = directory / 'light-standard-sage-focused-1x.png'
            good = target.read_bytes()
            Image.new('RGB', (528, 318), '#879E8D').save(target)
            with self.assertRaises(AssertionError):
                theme_contrast.control_pixels(directory)
            target.write_bytes(good)
            target = directory / 'dark-standard-tile-disabled-1x.png'
            image = Image.open(target)
            draw = ImageDraw.Draw(image)
            draw.rectangle((180, 100, 300, 131), fill='#242424')
            draw.text((190, 108), 'Unavailable', fill='#555555')
            image.save(target)
            with self.assertRaises(AssertionError):
                theme_contrast.control_pixels(directory)
            self.fixture(directory)
            (directory / 'controls.json').write_text(json.dumps(rows[:-1]))
            with self.assertRaises(AssertionError):
                theme_contrast.control_pixels(directory)


class DesignContrastTests(unittest.TestCase):
    def test_wcag_reference_values(self):
        self.assertEqual(theme_contrast.contrast((0, 0, 0), (1, 1, 1)), 21)
        self.assertEqual(theme_contrast.contrast((1, 1, 1), (1, 1, 1)), 1)

    def test_nearest_corrections_and_dark_focus(self):
        self.assertEqual(theme_contrast.nearest_passing_rgb(0xA9391F, 0xFFC89A, 4.5), 0xA4351E)
        self.assertEqual(theme_contrast.nearest_passing_rgb(0x2456C8, 0x0E0D0C, 3), 0x2456C9)
        # Keep a white tick neutral. #646464 is the nearest neutral passing value.
        ratio = lambda v: theme_contrast.contrast(theme_contrast.channels(v), theme_contrast.channels(0x6FCB98))
        self.assertGreaterEqual(ratio(0x646464), 3)
        self.assertLess(ratio(0x656565), 3)
        rows = theme_contrast.design_rows()
        focus = [r for r in rows if r['appearance'] == 'dark' and r['name'].startswith('focusRing/')]
        self.assertEqual(len(focus), 8)
        self.assertTrue(all(r['ratio'] >= 3 for r in focus))
        corrected = [r for r in rows if r['foreground'] != r['authored_foreground']]
        self.assertEqual(len(corrected), 3)
        self.assertTrue(all(r['authored_ratio'] < r['minimum'] <= r['ratio'] for r in corrected))


if __name__ == '__main__':
    unittest.main()
