"""Controls for the compact Insights measurement.

The capture itself only exists on a macOS runner, so these exercise the arithmetic on synthetic
PNGs: card boxes, the gutter, a clipped card, and the two failure modes the first real render
produced (antialiased pixels of the other card's fill moving a bounding box, and a card running
past the window). Corners are drawn flatter than the app's so the numbers stay about geometry the
measurement controls, not about the corner curve.
"""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

from PIL import Image, ImageDraw

from measure_compact_insights import measure

LAVENDER = (0x93, 0x8E, 0xAB)
SAGE = (0x87, 0x9E, 0x8D)
STROKE = (0x2F, 0x3D, 0x33)
INK = (0x09, 0x0C, 0x0A)


def card(draw, box, fill):
    """A card: the 1pt strokeBorder sits inside the rect, so the fill is the box inset by 1."""
    draw.rounded_rectangle(box, radius=4, fill=fill, outline=STROKE, width=1)


def text(draw, x, tops, width=300):
    for top in tops:
        draw.rectangle([x, top, x + width, top + 11], fill=INK)


def stacked(folder, momentum_bottom=350, strays=False):
    image = Image.new('RGB', (704, 351), (0, 0, 0))
    draw = ImageDraw.Draw(image)
    card(draw, [18, 48, 685, 200], LAVENDER)
    card(draw, [18, 208, 685, momentum_bottom], SAGE)
    text(draw, 32, [231, 262, 299, 326])
    if strays:
        # Antialiased glyph edges in the real render land inside the other card's colour range.
        draw.rectangle([300, 60, 302, 61], fill=SAGE)
        draw.rectangle([300, 330, 302, 331], fill=LAVENDER)
    image.save(folder / 'insights-compact.png')
    return dict(name='insights-compact', file='insights-compact.png', shell=[704, 351],
                pageWidth=668, layout='stacked', presented=[704, 351], ax=[])


def wide(folder):
    image = Image.new('RGB', (820, 351), (0, 0, 0))
    draw = ImageDraw.Draw(image)
    card(draw, [18, 48, 521, 337], LAVENDER)
    card(draw, [530, 48, 801, 337], SAGE)
    text(draw, 544, [228, 255, 282, 309], width=180)
    image.save(folder / 'insights-wide.png')
    return dict(name='insights-wide', file='insights-wide.png', shell=[820, 351],
                pageWidth=784, layout='twoColumn', presented=[820, 351], ax=[])


class CompactInsightsTests(unittest.TestCase):
    def testStackedCardsShareOneColumnWithAnEightPointGutter(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            result = measure(folder, stacked(folder))
            self.assertEqual(result['layout'], 'stacked')
            for key in ('chart', 'momentum'):
                self.assertAlmostEqual(result[key]['width'], 668, delta=2.5)
            self.assertTrue(result['same_column'])
            self.assertTrue(0 < result['gap'] <= 12, result['gap'])
            self.assertGreater(result['momentum']['top'], result['chart']['bottom'])

    def testCardRunningPastTheWindowIsReportedAsClipped(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            clipped = measure(folder, stacked(folder, momentum_bottom=350))
            fitting = measure(folder, stacked(folder, momentum_bottom=337))
            self.assertTrue(clipped['clipped'])
            self.assertTrue(clipped['past_page'])
            self.assertEqual(clipped['momentum']['bottom'], 351)
            self.assertFalse(fitting['clipped'])
            self.assertFalse(fitting['past_page'])

    def testStrayPixelsOfTheOtherFillDoNotMoveEitherCard(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            clean = measure(folder, stacked(folder))
            stray = measure(folder, stacked(folder, strays=True))
            for key in ('chart', 'momentum'):
                self.assertEqual(clean[key], stray[key], key)

    def testWideCaptureMeasuresItsOwnGeometry(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            result = measure(folder, wide(folder))
            self.assertAlmostEqual(result['chart']['width'], 504, delta=2.5)
            self.assertAlmostEqual(result['momentum']['width'], 272, delta=2.5)
            self.assertAlmostEqual(result['gap'], 8, delta=2.5)
            self.assertFalse(result['clipped'])

    def testAMeasurementThatIsNotTheCompactPageFailsTheStep(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            entry = stacked(folder)
            entry['pageWidth'] = 700
            (folder / 'geometry.json').write_text(json.dumps([entry, wide(folder)]))
            root = pathlib.Path(__file__).resolve().parent
            run = subprocess.run([sys.executable, str(root / 'measure_compact_insights.py'), str(folder)],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 1)
            self.assertIn('expected the compact 668pt', run.stdout)

    def testAFullStackedMeasurementPassesTheStep(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            (folder / 'geometry.json').write_text(json.dumps([stacked(folder), wide(folder)]))
            root = pathlib.Path(__file__).resolve().parent
            run = subprocess.run([sys.executable, str(root / 'measure_compact_insights.py'), str(folder)],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertTrue((folder / 'measurement.json').exists())


if __name__ == '__main__':
    unittest.main()
