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
                                            'frames': {'continue': [40, 100, 100, 32], 'unavailable': [180, 100, 120, 32]}})
        (directory / 'controls.json').write_text(json.dumps(entries))
        return entries

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


if __name__ == '__main__':
    unittest.main()
