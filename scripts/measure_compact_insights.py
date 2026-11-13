"""Measure the compact stacked Insights render.

The layout probe job runs on the runner's 1024x768 display, so every snapshot it takes is 784pt
wide and Insights takes its two-column branch. scripts/check_compact_insights.sh renders the same
real page at the compact shell width (704pt -> 668pt page); this reads those PNGs and states, in
pixels: the chart card fill, the gutter, the momentum card fill, and where every momentum row is
drawn relative to that fill.

Card fills are found by their opaque ThemeTokens colours (lavender for the chart card, sage for
momentum), so nothing here restates a constant that the layout could disagree with. Native
accessibility frames are cross-checked when the probe could read them and are reported as
corroboration, never used as the gate: the PNG is the artifact.

Fit of the momentum content is reported, not asserted. The compact stack cannot be fixed by width,
so whether the rows fit is a design decision for the manager (see the card that owns this capture).
"""

import json
import sys
from pathlib import Path

from PIL import Image

LAVENDER = (0x93, 0x8E, 0xAB)  # ThemeTokens.lavender: the chart card (.card(.timer))
SAGE = (0x87, 0x9E, 0x8D)  # ThemeTokens.sage: the momentum card (.card(.tasks))
COLOR_TOLERANCE = 10
INK_LUMINANCE = 120  # near-black card ink; both pastel fills are far brighter
STROKE = 1  # strokeBorder is drawn inside the card's edge
ROW_PREFIXES = ('tasks done this week', 'focused this week', 'streak', 'done today',
                'calendar events checked off today')


def rect(left, top, right, bottom, pixels):
    return dict(left=left, top=top, right=right, bottom=bottom,
                width=right - left, height=bottom - top, pixels=pixels)


def surfaces(image):
    """Bounding box of each card's opaque fill, in image pixels."""
    width, height = image.size
    raw = image.tobytes()
    found = {}
    for name, color in (('chart', LAVENDER), ('momentum', SAGE)):
        left = top = 10 ** 9
        right = bottom = -1
        count = 0
        for offset in range(0, len(raw), 3):
            if (abs(raw[offset] - color[0]) <= COLOR_TOLERANCE
                    and abs(raw[offset + 1] - color[1]) <= COLOR_TOLERANCE
                    and abs(raw[offset + 2] - color[2]) <= COLOR_TOLERANCE):
                count += 1
                x, y = (offset // 3) % width, (offset // 3) // width
                left = min(left, x)
                right = max(right, x + 1)
                top = min(top, y)
                bottom = max(bottom, y + 1)
        if count and right > 0:
            found[name] = rect(left, top, right, bottom, count)
    return found


def layout_rect(fill):
    """The card's layout rect: the fill bbox grows back over its 1pt stroke."""
    return rect(fill['left'] - STROKE, fill['top'] - STROKE, fill['right'] + STROKE,
                fill['bottom'] + STROKE, fill['pixels'])


def ink_bands(gray, left, right, top, bottom):
    """Rows of dark ink inside a card, grouped into text lines (gaps of up to 2px merge)."""
    pixels = gray.load()
    rows = []
    for y in range(top, bottom):
        count = 0
        for x in range(left, right):
            if pixels[x, y] < INK_LUMINANCE:
                count += 1
        if count >= 4:
            rows.append(y)
    bands = []
    for y in rows:
        if bands and y - bands[-1][1] <= 3:
            bands[-1][1] = y
        else:
            bands.append([y, y])
    return bands


def measure(folder, entry):
    image = Image.open(Path(folder) / entry['file'])
    alpha = image.convert('RGBA')
    backdrop = Image.new('RGBA', alpha.size, (0, 0, 0, 255))
    backdrop.alpha_composite(alpha)
    rgb = backdrop.convert('RGB')
    gray = rgb.convert('L')
    presented_width, presented_height = entry['presented']
    scale = rgb.width / presented_width

    found = surfaces(rgb)
    assert 'chart' in found and 'momentum' in found, f"{entry['name']}: both card fills must render"
    chart, momentum = layout_rect(found['chart']), layout_rect(found['momentum'])

    # Ink inside the momentum card only. The card's own stroke is dark, so the measured band is
    # taken off every edge by more than the stroke width. Anything a row draws past the fill shows
    # up as an accessibility frame with no matching band, i.e. laid out but not painted in the card.
    rows = []
    for top, bottom in ink_bands(gray, momentum['left'] + 6, momentum['right'] - 6,
                                 momentum['top'] + 12, momentum['bottom'] - 12):
        rows.append(dict(top=top, bottom=bottom, height=bottom - top + 1,
                         inside=top >= momentum['top'] and bottom < momentum['bottom'],
                         source='ink'))
    for label in entry.get('ax', []):
        if not any(prefix in label['label'] for prefix in ROW_PREFIXES):
            continue
        x, y, w, h = [value * scale for value in label['rect']]
        candidates = [row for row in rows if 'label' not in row and abs(row['top'] - y) <= 8]
        if candidates:
            min(candidates, key=lambda row: abs(row['top'] - y))['label'] = label['label']
            continue
        rows.append(dict(label=label['label'], top=y, bottom=y + h, height=h,
                         inside=y >= momentum['top'] - 1.5 and y + h <= momentum['bottom'] + 1.5,
                         source='layout only'))
    rows.sort(key=lambda row: row['top'])

    result = dict(name=entry['name'], file=entry['file'], layout=entry['layout'],
                  page_width=entry['pageWidth'], shell=[entry['shell'][0], entry['shell'][1]],
                  image=[rgb.width, rgb.height], scale=scale,
                  chart=chart, momentum=momentum, rows=rows)
    if entry['layout'] == 'stacked':
        result['gap'] = momentum['top'] - chart['bottom']
        result['same_column'] = abs(chart['left'] - momentum['left']) <= 1 and abs(
            chart['right'] - momentum['right']) <= 1
    else:
        result['gap'] = momentum['left'] - chart['right']
    return result


def main():
    folder = Path(sys.argv[1])
    geometry = json.loads((folder / 'geometry.json').read_text())
    results = [measure(folder, entry) for entry in geometry]
    (folder / 'measurement.json').write_text(json.dumps(results, indent=2) + '\n')

    compact = [r for r in results if r['layout'] == 'stacked']
    wide = [r for r in results if r['layout'] == 'twoColumn']
    assert compact, 'no capture took the compact stacked branch'
    assert wide, 'no wide capture to compare the compact geometry against'
    reference = wide[0]

    failures = []
    for r in results:
        print(f"{r['name']}: {r['layout']} page={r['page_width']}pt shell={r['shell']} "
              f"image={r['image']} scale={r['scale']}")
        print(f"  chart fill    x {r['chart']['left']}..{r['chart']['right']} "
              f"y {r['chart']['top']}..{r['chart']['bottom']} "
              f"({r['chart']['width']}x{r['chart']['height']})")
        print(f"  momentum fill x {r['momentum']['left']}..{r['momentum']['right']} "
              f"y {r['momentum']['top']}..{r['momentum']['bottom']} "
              f"({r['momentum']['width']}x{r['momentum']['height']})")
        if r['layout'] == 'stacked':
            print(f"  stacked gap {r['gap']}px (Theme.gutter 8pt), same column={r['same_column']}")
        else:
            print(f"  gutter {r['gap']}px (Theme.gutter 8pt)")
        for row in r['rows']:
            state = 'inside ' if row['inside'] else 'OUTSIDE'
            print(f"    {state} y {row['top']}..{row['bottom']} ({row['height']}px) "
                  f"{row.get('source', '')} {row.get('label', 'unlabelled')}")
        outside = [row for row in r['rows'] if not row['inside']]
        print(f"  momentum rows: {len(r['rows']) - len(outside)} drawn inside the fill, "
              f"{len(outside)} laid out past it")
        lowest = max((row['bottom'] for row in r['rows']), default=0)
        print(f"  lowest momentum row bottom {lowest:.0f} vs fill bottom {r['momentum']['bottom']}")

    for r in compact:
        if abs(r['page_width'] - 668) > 0.5:
            failures.append(f"{r['name']}: page is {r['page_width']}pt, expected the compact 668pt")
        if not r['same_column']:
            failures.append(f"{r['name']}: stacked cards do not share one column")
        if r['momentum']['top'] <= r['chart']['top']:
            failures.append(f"{r['name']}: momentum is not below the chart")
        if abs(r['gap'] - 8) > 1.5:
            failures.append(f"{r['name']}: stacked gap is {r['gap']}px, expected the 8pt gutter")
        for card in ('chart', 'momentum'):
            if abs(r[card]['width'] - 668) > 1.5:
                failures.append(f"{r['name']}: {card} is {r[card]['width']}px wide, expected 668")
        if not [row for row in r['rows'] if row['inside']]:
            failures.append(f"{r['name']}: momentum card rendered no content inside its fill")

    if abs(reference['page_width'] - 784) > 0.5:
        failures.append(f"wide page is {reference['page_width']}pt, expected 784")
    if abs(reference['momentum']['width'] - 272) > 1.5:
        failures.append(f"wide momentum is {reference['momentum']['width']}px, expected 272")
    if abs(reference['chart']['width'] - (784 - 272 - 8)) > 1.5:
        failures.append(f"wide chart is {reference['chart']['width']}px, expected 504")
    if abs(reference['gap'] - 8) > 1.5:
        failures.append(f"wide gutter is {reference['gap']}px, expected 8pt")
    stray = [row for row in reference['rows'] if not row['inside']]
    if stray:
        failures.append(f"wide layout, a correct render, has momentum rows outside its fill: {stray}")

    print()
    for r in compact:
        outside = [row for row in r['rows'] if not row['inside']]
        if outside:
            print(f"OVERFLOW {r['name']}: the momentum card fill is {r['momentum']['height']}px tall; "
                  f"{len(outside)} row(s) are laid out past its bottom "
                  f"{[row['label'] for row in outside]}. The compact stack cannot be fixed by width; "
                  f"this capture reports the measurement for the design decision.")
        else:
            print(f"FIT {r['name']}: every momentum row is painted inside the "
                  f"{r['momentum']['height']}px card fill.")
    print(json.dumps({'captures': len(results), 'failures': failures}, indent=2))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
