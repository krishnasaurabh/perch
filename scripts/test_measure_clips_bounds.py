import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from PIL import Image, ImageDraw
from measure_clips_bounds import main, measure


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
                    # Deliberately different synthetic anchors exercise reflow,
                    # independently of the anchor measured by the native probe.
                    rope_y = 125 if width == 640 else 90
                    draw.line((44 * scale, rope_y * scale, (width - 44) * scale, rope_y * scale),
                              fill=(85, 85, 85), width=scale)
                    if bleed:
                        draw.point(((width - 20) * scale, rope_y * scale), fill=(85, 85, 85))
                    im.save(folder / name)
                    records.append(dict(file=name, width=width, height=360, rope_y=rope_y,
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

    def testRopeRemovedFromScratchCopyFailsAtBothScales(self):
        for scale in [1, 2]:
            with tempfile.TemporaryDirectory() as d:
                folder = Path(d)
                self.fixture(folder, scale)
                records = json.loads((folder / 'captures.json').read_text())
                for record in records:
                    # Erase only rope pixels in generated scratch images, retaining
                    # their measured anchors and the rest of the card unchanged.
                    path = folder / record['file']
                    image = Image.open(path).convert('RGB')
                    y = record['rope_y'] * scale
                    ImageDraw.Draw(image).rectangle(
                        (43 * scale, y - 2 * scale, (record['width'] - 43) * scale, y + 2 * scale),
                        fill=(29, 29, 29))
                    image.save(path)
                rows = measure(folder)
                self.assertEqual(len(rows), 16)
                self.assertTrue(all(r['exterior_painted_pixels'] == 0 for r in rows))
                self.assertTrue(all(r['left_rope_ink_pixels'] == 0 for r in rows))
                output = io.StringIO()
                with patch.object(sys, 'argv', ['measure_clips_bounds.py', str(folder)]), contextlib.redirect_stdout(output):
                    self.assertTrue(main())
                self.assertEqual(len(json.loads(output.getvalue())['failures']), 16)

    def testOldAnchorCannotPassReflowedRope(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            self.fixture(folder)
            records = json.loads((folder / 'captures.json').read_text())
            for record in records:
                record['rope_y'] = 90
            (folder / 'captures.json').write_text(json.dumps(records))
            rows = measure(folder)
            self.assertTrue(all(r['left_rope_ink_pixels'] == 0 for r in rows if '-640-' in r['file']))
            self.assertTrue(all(r['left_rope_ink_pixels'] > 0 for r in rows if '-820-' in r['file']))

    def testMissingStatesFail(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            (folder / 'captures.json').write_text('[]')
            with self.assertRaises(AssertionError):
                measure(folder)


if __name__ == '__main__':
    unittest.main()
