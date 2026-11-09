import json
from pathlib import Path
import tempfile
import unittest
from PIL import Image, ImageDraw
from measure_clips_bounds import measure


class ClipsBoundsTests(unittest.TestCase):
    def fixture(self, folder, scale=1, bleed=False):
        records = []
        for appearance in ['dark', 'light']:
            for width in [820, 640]:
                for state in ['empty', 'one', 'populated', 'cleared']:
                    name = f'{appearance}-{width}-{state}.png'
                    im = Image.new('RGB', (width * scale, 360 * scale))
                    draw = ImageDraw.Draw(im)
                    draw.rectangle((24 * scale, 24 * scale, (width - 24) * scale - 1,
                                    336 * scale - 1), fill=(29, 29, 29))
                    draw.line((44 * scale, 90 * scale, (width - 44) * scale, 90 * scale),
                              fill=(85, 85, 85), width=scale)
                    if bleed:
                        draw.point(((width - 20) * scale, 90 * scale), fill=(85, 85, 85))
                    im.save(folder / name)
                    records.append(dict(file=name, width=width, height=360,
                                        card=[24, 24, width - 24, 336]))
        (folder / 'captures.json').write_text(json.dumps(records))

    def testContainedAtOneAndTwoTimesScale(self):
        for scale in [1, 2]:
            with tempfile.TemporaryDirectory() as d:
                folder = Path(d)
                self.fixture(folder, scale)
                rows = measure(folder)
                self.assertEqual(len(rows), 16)
                self.assertTrue(all(r['exterior_painted_pixels'] == 0 for r in rows))
                self.assertTrue(all(r['left_rope_ink_pixels'] > 0 for r in rows))

    def testOneOutsidePixelIsNotIgnored(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            self.fixture(folder, bleed=True)
            self.assertTrue(all(r['exterior_painted_pixels'] == 1 for r in measure(folder)))

    def testMissingStatesFail(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            (folder / 'captures.json').write_text('[]')
            with self.assertRaises(AssertionError):
                measure(folder)


if __name__ == '__main__':
    unittest.main()
