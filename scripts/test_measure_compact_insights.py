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


def wide(folder) -> dict:
    image = Image.new('RGB', (820, 351), (0, 0, 0))
    draw = ImageDraw.Draw(image)
    card(draw, [18, 48, 521, 337], LAVENDER)
    card(draw, [530, 48, 801, 337], SAGE)
    text(draw, 544, [228, 255, 282, 309], width=180)
    image.save(folder / 'insights-wide.png')
    return dict(name='insights-wide', file='insights-wide.png', shell=[820, 351],
                pageWidth=784, layout='twoColumn', presented=[820, 351], ax=[])


def compact_stats(folder, calendar=False, missing=(), momentum_bottom=336, offset_y=0, scale=1):
    """A fitting three-column grid with a heading and two 15pt-face stat rows.

    Deliberately keep heading ink over all three columns and the second-row neighbours intact:
    neither may hide an erased first-row metric. These boxes are independent synthetic pixels,
    not coordinates obtained from the detector under test.
    """
    name = 'insights-compact-calendar' if calendar else 'insights-compact'
    image = Image.new('RGB', (704, 351 + offset_y), (0, 0, 0))
    draw = ImageDraw.Draw(image)
    card(draw, [18, 48 + offset_y, 685, 228 + offset_y], LAVENDER)
    card(draw, [18, 238 + offset_y, 685, momentum_bottom + offset_y], SAGE)
    text(draw, 32, [254 + offset_y], width=600)
    for index, x in enumerate((32, 250, 468), 1):
        if f'column {index}' not in missing:
            text(draw, x, [282 + offset_y], width=170)
    if 'done today' not in missing:
        text(draw, 32, [309 + offset_y], width=100)
    if calendar and 'calendar' not in missing:
        text(draw, 250, [309 + offset_y], width=300)
    if scale != 1:
        image = image.resize((image.width * scale, image.height * scale), Image.Resampling.NEAREST)
    image.save(folder / f'{name}.png')
    return dict(name=name, file=f'{name}.png', shell=[704, 351 + offset_y],
                pageWidth=668, layout='stacked', presented=[704, 351 + offset_y], ax=[])


def run_measurement(folder, entries):
    (folder / 'geometry.json').write_text(json.dumps(entries))
    root = pathlib.Path(__file__).resolve().parent
    return subprocess.run([sys.executable, str(root / 'measure_compact_insights.py'), str(folder)],
                          capture_output=True, text=True)


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
            # The legacy stacked() fixture intentionally overflows and has no three-column grid.
            # Use a fitting populated card for this positive CLI control.
            (folder / 'geometry.json').write_text(json.dumps([compact_stats(folder), wide(folder)]))
            root = pathlib.Path(__file__).resolve().parent
            run = subprocess.run([sys.executable, str(root / 'measure_compact_insights.py'), str(folder)],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertTrue((folder / 'measurement.json').exists())

    def assertGateFailure(self, run, reason):
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        summary = json.loads(run.stdout[run.stdout.rfind('\n{') + 1:])
        self.assertTrue(any(reason in failure for failure in summary['failures']), run.stdout)

    def testClippedCompactCaptureFailsTheStep(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            entry = stacked(folder, momentum_bottom=350)
            result = measure(folder, entry)
            self.assertTrue(result['clipped'])
            self.assertTrue(result['past_page'])
            self.assertGreaterEqual(len(result['rows']), 3)
            run = run_measurement(folder, [entry, wide(folder)])
            self.assertGateFailure(run, 'insights-compact: momentum clipped by the shell')
            self.assertIn('bottom 351px >= shell bottom 351px', run.stdout)
            self.assertIn('bottom 351px > page bottom 338px + 1px', run.stdout)

    def testCompactCapturePastPageButNotClippedFailsTheStep(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            entry = compact_stats(folder, momentum_bottom=342)
            result = measure(folder, entry)
            self.assertFalse(result['clipped'])
            self.assertTrue(result['past_page'])
            self.assertGreaterEqual(len(result['rows']), 3)
            run = run_measurement(folder, [entry, wide(folder)])
            self.assertGateFailure(run, 'insights-compact: momentum past the page bottom')
            self.assertIn('bottom 343px > page bottom 338px + 1px', run.stdout)

    def testEachMissingCompactStatColumnFailsTheStep(self):
        for calendar in (False, True):
            for column in range(1, 4):
                with self.subTest(calendar=calendar, column=column), tempfile.TemporaryDirectory() as d:
                    folder = pathlib.Path(d)
                    entry = compact_stats(folder, calendar=calendar, missing=(f'column {column}',))
                    result = measure(folder, entry)
                    self.assertGreaterEqual(len(result['rows']), 3)
                    # Heading ink remains in this x band, so the old full-height diagnostic
                    # alone cannot prove that the first-row metric is still visible.
                    self.assertTrue(result['momentum_detail']['columns'][column - 1]['rows'])
                    run = run_measurement(folder, [entry, wide(folder)])
                    self.assertGateFailure(run, f"{entry['name']}: paired stat column {column} has no ink rows")

    def testMissingCalendarStatFailsTheStep(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            entry = compact_stats(folder, calendar=True, missing=('calendar',))
            result = measure(folder, entry)
            self.assertGreaterEqual(len(result['rows']), 3)
            # All other metrics, including the adjacent done-today row, remain in the image.
            run = run_measurement(folder, [entry, wide(folder)])
            self.assertGateFailure(run, 'insights-compact-calendar: calendar stat has no ink rows')

    def testMissingDoneTodayStatFailsEvenWithCalendarInkBesideIt(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            entry = compact_stats(folder, calendar=True, missing=('done today',))
            result = measure(folder, entry)
            self.assertGreaterEqual(len(result['rows']), 3)
            run = run_measurement(folder, [entry, wide(folder)])
            self.assertGateFailure(run, 'insights-compact-calendar: done today stat has no ink rows')

    def testAllRequiredCapturesWithEveryMetricPassTheStep(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            entries = [compact_stats(folder), compact_stats(folder, calendar=True), wide(folder)]
            run = run_measurement(folder, entries)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertEqual(json.loads(run.stdout[run.stdout.rfind('\n{') + 1:])['failures'], [])

    def testMetricRegionsFollowTheCardWhenItMoves(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            for missing in ((), ('calendar',)):
                with self.subTest(missing=missing):
                    entry = compact_stats(folder, calendar=True, missing=missing, offset_y=23)
                    run = run_measurement(folder, [entry, wide(folder)])
                    if missing:
                        self.assertGateFailure(run, 'insights-compact-calendar: calendar stat has no ink rows')
                    else:
                        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def testMetricSamplingUsesTheCaptureScale(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            for scale in (1, 2):
                for missing in ((), ('calendar',)):
                    with self.subTest(scale=scale, missing=missing):
                        entry = compact_stats(folder, calendar=True, missing=missing, scale=scale)
                        result = measure(folder, entry)
                        self.assertEqual(result['scale'], scale)
                        stats = result['momentum_detail']['stats']
                        self.assertEqual(len(stats), 5)
                        self.assertTrue(all(stat['rows'] for stat in stats[:4]))
                        self.assertEqual(bool(stats[4]['rows']), not missing)

    def testWideClippingCheckIsPreserved(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            entry = wide(folder)
            image = Image.open(folder / entry['file'])
            card(ImageDraw.Draw(image), [530, 48, 801, 350], SAGE)
            image.save(folder / entry['file'])
            run = run_measurement(folder, [compact_stats(folder), entry])
            self.assertGateFailure(run, 'wide momentum card is clipped by the shell')

    def testWidePastPageWithoutClippingKeepsItsExistingBehavior(self):
        with tempfile.TemporaryDirectory() as d:
            folder = pathlib.Path(d)
            entry = wide(folder)
            image = Image.open(folder / entry['file'])
            card(ImageDraw.Draw(image), [530, 48, 801, 342], SAGE)
            image.save(folder / entry['file'])
            result = measure(folder, entry)
            self.assertTrue(result['past_page'])
            self.assertFalse(result['clipped'])
            run = run_measurement(folder, [compact_stats(folder), entry])
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == '__main__':
    unittest.main()
