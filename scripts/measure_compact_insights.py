"""Measure the compact stacked Insights render.

The layout probe job runs on the runner's 1024x768 display, so every other snapshot is 784pt wide
and Insights takes its two-column branch. scripts/check_compact_insights.sh renders the same real
page at the compact shell width (704pt shell -> 668pt page); this reads those PNGs and states, in
pixels: the chart card, the gutter, the momentum card, and where the momentum content is drawn.

Card fills are found by their opaque ThemeTokens colours (lavender for the chart card, sage for
momentum), so the measured card bounds do not assume their requested layout size. Anti-aliased
text produces a few stray pixels in either colour, so a card row is one where the colour covers a
row the way a card does, not one where the colour merely appears.

Compact cards must fit inside the page and shell. Each rendered momentum metric must leave ink
in its own grid cell; a heading or a neighbouring metric cannot stand in for missing content.
"""

import json
import sys
from pathlib import Path

from PIL import Image

LAVENDER = (0x93, 0x8E, 0xAB)  # ThemeTokens.lavender: the chart card (.card(.timer))
SAGE = (0x87, 0x9E, 0x8D)  # ThemeTokens.sage: the momentum card (.card(.tasks))
COLOR_TOLERANCE = 12
INK_LUMINANCE = 120  # near-black card ink; both pastel fills are far brighter
PAGE_BOTTOM_INSET = 13  # WorkspaceLayout.bottomInset, below the page
STROKE = 1  # strokeBorder is drawn inside the card edge, so a gap between fills is wider
GUTTER_BETWEEN_FILLS = 12  # 8pt gutter + stroke ring + corner arcs, measured between fills

# compactMomentum in InsightsPage.swift: a heading, then two stat rows. In the probe's
# single-line fixtures each row's tallest face is 15pt (Theme.heading or stat's value).
# Derive their line-box height from the measured card interior, not a fixed pixel y offset.
COMPACT_CONTENT_ROWS = 3
COMPACT_STAT_COLUMNS = 3
CARD_PADDING = 14  # ThemeTokens.cardPadding
COMPACT_ROW_GAP = 8  # outer VStack and Grid.verticalSpacing
COMPACT_COLUMN_GAP = 12  # Grid.horizontalSpacing


def rect(left, top, right, bottom, pixels):
    return dict(left=left, top=top, right=right, bottom=bottom,
                width=right - left, height=bottom - top, pixels=pixels)


def matches_fill(raw, width, x, y, color):
    """Whether this pixel is the card's opaque fill.

    Only the fill is matched. The 1pt strokeBorder is the same dark green on both cards, and blends
    of ink into either fill pass through that colour, so matching it makes every row of both cards
    look like card and nothing measures cleanly.
    """
    offset = (y * width + x) * 3
    return (abs(raw[offset] - color[0]) <= COLOR_TOLERANCE
            and abs(raw[offset + 1] - color[1]) <= COLOR_TOLERANCE
            and abs(raw[offset + 2] - color[2]) <= COLOR_TOLERANCE)


def card_rect(fill):
    """The card's own rect: its fill grows back over the 1pt strokeBorder on each side."""
    return rect(fill['left'] - STROKE, fill['top'] - STROKE, fill['right'] + STROKE,
                fill['bottom'] + STROKE, fill['pixels'])


def surfaces(width, height, raw):
    """Each card as its fill colour sees it: x from its widest row, y from an edge column.

    Text splits the fill horizontally, and antialiased glyphs put stray pixels of either fill colour
    across the window, so neither a global bounding box nor a per-row total works. A column a few
    points inside the card edge is fill for every row the card covers and nothing else ever paints
    there: card padding is 14pt, so no text reaches it. The fill sits 1pt inside the card's rect,
    so the reported rect is the fill box and a gap between two cards reads as the gutter plus both
    strokes.
    """
    found = {}
    for name, color in (('chart', LAVENDER), ('momentum', SAGE)):
        def matches(x, y):
            return matches_fill(raw, width, x, y, color)

        widest = None
        for y in range(height):
            run = 0
            start = 0
            for x in range(width):
                if matches(x, y):
                    if not run:
                        start = x
                    run += 1
                    if widest is None or run > widest[0]:
                        widest = (run, start, x + 1)
                else:
                    run = 0
        if widest is None or widest[0] < 40:
            continue
        left, right = widest[1], widest[2]
        columns = [left + 10, right - 11]
        covered = [y for y in range(height) if any(matches(x, y) for x in columns)]
        bands = []
        for y in covered:
            if bands and y - bands[-1][1] <= 2:
                bands[-1][1] = y
            else:
                bands.append([y, y])
        top, bottom = max(bands, key=lambda band: band[1] - band[0])
        pixels = sum(1 for y in range(top, bottom + 1) if any(matches(x, y) for x in columns))
        found[name] = rect(left, top, right, bottom + 1, pixels)
    return found


def ink_bands(gray, left, right, top, bottom):
    """Rows of dark ink inside a card, grouped into text lines (gaps of up to 3px merge)."""
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


def compact_stat_cells(gray, momentum, scale, entry):
    """Sample each required stat separately, excluding the heading and adjacent grid rows.

    All bounds are relative to the detected card. The capture name records whether the probe
    seeded calendar completions; in that fixture the fifth stat spans columns two and three.
    Keeping expected bounds even when ink is absent makes missing metrics diagnosable.
    """
    inset = CARD_PADDING * scale
    xgap, ygap = COMPACT_COLUMN_GAP * scale, COMPACT_ROW_GAP * scale
    left, right = momentum['left'] + inset, momentum['right'] - inset
    top, bottom = momentum['top'] + inset, momentum['bottom'] - inset
    column_width = (right - left - (COMPACT_STAT_COLUMNS - 1) * xgap) / COMPACT_STAT_COLUMNS
    row_height = (bottom - top - (COMPACT_CONTENT_ROWS - 1) * ygap) / COMPACT_CONTENT_ROWS

    def cell(name, row, column, span=1):
        x0 = round(left + column * (column_width + xgap))
        x1 = round(left + (column + span) * (column_width + xgap) - xgap)
        y0 = round(top + row * (row_height + ygap))
        y1 = round(top + row * (row_height + ygap) + row_height)
        bands = ink_bands(gray, max(0, x0), min(gray.width, x1),
                          max(0, y0), min(gray.height, y1))
        return dict(name=name, left=x0, right=x1, top=y0, bottom=y1, rows=[
            dict(top=start, bottom=end + 1, height=end - start + 1) for start, end in bands])

    cells = [cell(f'paired stat column {index + 1}', 1, index)
             for index in range(COMPACT_STAT_COLUMNS)]
    cells.append(cell('done today stat', 2, 0))
    if entry['name'] == 'insights-compact-calendar':
        cells.append(cell('calendar stat', 2, 1, span=2))
    return cells


def measure(folder, entry) -> dict:
    image = Image.open(Path(folder) / entry['file']).convert('RGBA')
    backdrop = Image.new('RGBA', image.size, (0, 0, 0, 255))
    backdrop.alpha_composite(image)
    rgb = backdrop.convert('RGB')
    gray = rgb.convert('L')
    width, height = rgb.size
    raw = rgb.tobytes()
    scale = width / entry['presented'][0]

    found = surfaces(width, height, raw)
    assert 'chart' in found and 'momentum' in found, f"{entry['name']}: both card fills must render"
    chart, momentum = card_rect(found['chart']), card_rect(found['momentum'])
    # Measured between the fills: the stroke ring and the rounded corners are not fill, so a
    # card-to-card gap reads a little wider than the 8pt gutter the layout asks for.
    gap = (momentum['top'] - chart['bottom'] if entry['layout'] == 'stacked'
           else momentum['left'] - chart['right'])
    # Ink inside the momentum card. The card's own stroke is dark, so the measured band is taken
    # off every edge by more than the stroke width.
    rows = []
    for top, bottom in ink_bands(gray, momentum['left'] + 6, momentum['right'] - 6,
                                 momentum['top'] + 12, min(momentum['bottom'], height) - 12):
        rows.append(dict(top=top, bottom=bottom + 1, height=bottom - top + 1))

    # The page sits `bottomInset` above the shell's bottom edge: a card drawn past it is covering
    # the space the shell reserves for its own edge, and a card past the window is cut by the shell.
    page_bottom = height - PAGE_BOTTOM_INSET * scale
    result = dict(name=entry['name'], file=entry['file'], layout=entry['layout'],
                  page_width=entry['pageWidth'], shell=[entry['shell'][0], entry['shell'][1]],
                  image=[width, height], scale=scale, page_bottom=page_bottom,
                  chart=chart, momentum=momentum, rows=rows,
                  clipped=momentum['bottom'] >= height,
                  past_page=momentum['bottom'] > page_bottom + 1)
    result['gap'] = gap
    if entry['layout'] == 'stacked':
        result['same_column'] = abs(chart['left'] - momentum['left']) <= 2 and abs(
            chart['right'] - momentum['right']) <= 2
        # Additive diagnostic: paired stats share a y band, so measure each third separately.
        # These are pixel sampling regions, not expected text positions or pass/fail gates.
        inset, gutter = round(14 * scale), round(12 * scale)
        left, right = momentum['left'] + inset, momentum['right'] - inset
        column_width = (right - left - 2 * gutter) / 3
        columns = []
        for index in range(3):
            x0 = round(left + index * (column_width + gutter))
            x1 = round(left + index * (column_width + gutter) + column_width)
            bands = ink_bands(gray, x0, x1, momentum['top'] + 12,
                              min(momentum['bottom'], height) - 12)
            columns.append(dict(left=x0, right=x1, rows=[
                dict(top=top, bottom=bottom + 1, height=bottom - top + 1)
                for top, bottom in bands]))
        result['momentum_detail'] = dict(fill=found['momentum'], columns=columns,
                                        stats=compact_stat_cells(gray, momentum, scale, entry))
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
        print(f"  chart card    x {r['chart']['left']}..{r['chart']['right']} "
              f"y {r['chart']['top']}..{r['chart']['bottom']} "
              f"({r['chart']['width']}x{r['chart']['height']})")
        print(f"  momentum card x {r['momentum']['left']}..{r['momentum']['right']} "
              f"y {r['momentum']['top']}..{r['momentum']['bottom']} "
              f"({r['momentum']['width']}x{r['momentum']['height']})")
        if r['layout'] == 'stacked':
            print(f"  stacked gap {r['gap']}px between the cards (8pt gutter), "
                  f"same column={r['same_column']}")
        else:
            print(f"  gutter {r['gap']}px between the cards (8pt gutter)")
        print(f"  page bottom {r['page_bottom']:.0f}, window bottom {r['image'][1]}, "
              f"momentum past the page={r['past_page']}, clipped by the shell={r['clipped']}")
        for row in r['rows']:
            print(f"    ink y {row['top']}..{row['bottom']} ({row['height']}px)")
        print(f"  momentum text lines drawn: {len(r['rows'])}")
        if 'momentum_detail' in r:
            detail = r['momentum_detail']
            fill = detail['fill']
            print(f"  momentum fill x {fill['left']}..{fill['right']} "
                  f"y {fill['top']}..{fill['bottom']}")
            for index, column in enumerate(detail['columns'], 1):
                print(f"    column {index} x {column['left']}..{column['right']}: "
                      + ', '.join(f"ink y {row['top']}..{row['bottom']}" for row in column['rows']))
            for stat in detail['stats']:
                print(f"    {stat['name']} x {stat['left']}..{stat['right']} "
                      f"y {stat['top']}..{stat['bottom']}: {len(stat['rows'])} ink rows")

    for r in compact:
        if abs(r['page_width'] - 668) > 0.5:
            failures.append(f"{r['name']}: page is {r['page_width']}pt, expected the compact 668pt")
        if not r['same_column']:
            failures.append(f"{r['name']}: stacked cards do not share one column")
        if r['momentum']['top'] <= r['chart']['top']:
            failures.append(f"{r['name']}: momentum is not below the chart")
        if not 0 < r['gap'] <= GUTTER_BETWEEN_FILLS:
            failures.append(f"{r['name']}: stacked gap is {r['gap']}px, expected the 8pt gutter")
        for card in ('chart', 'momentum'):
            if abs(r[card]['width'] - 668) > 2.5:
                failures.append(f"{r['name']}: {card} is {r[card]['width']}px wide, expected 668")
        if len(r['rows']) < 3:
            failures.append(f"{r['name']}: the momentum card drew {len(r['rows'])} text lines")
        if r['clipped']:
            failures.append(f"{r['name']}: momentum clipped by the shell: bottom "
                            f"{r['momentum']['bottom']}px >= shell bottom {r['image'][1]}px")
        if r['past_page']:
            failures.append(f"{r['name']}: momentum past the page bottom: bottom "
                            f"{r['momentum']['bottom']}px > page bottom {r['page_bottom']:g}px + 1px")
        for stat in r['momentum_detail']['stats']:
            if not stat['rows']:
                failures.append(f"{r['name']}: {stat['name']} has no ink rows in "
                                f"x {stat['left']}..{stat['right']}, y {stat['top']}..{stat['bottom']}px")

    if abs(reference['page_width'] - 784) > 0.5:
        failures.append(f"wide page is {reference['page_width']}pt, expected 784")
    if abs(reference['momentum']['width'] - 272) > 2.5:
        failures.append(f"wide momentum is {reference['momentum']['width']}px, expected 272")
    if abs(reference['chart']['width'] - (784 - 272 - 8)) > 2.5:
        failures.append(f"wide chart is {reference['chart']['width']}px, expected 504")
    if not 0 < reference['gap'] <= GUTTER_BETWEEN_FILLS:
        failures.append(f"wide gutter is {reference['gap']}px, expected 8pt")
    if reference['clipped']:
        failures.append('wide momentum card is clipped by the shell')

    print()
    for r in compact:
        damage = []
        if r['clipped']:
            damage.append('cut by the shell')
        elif r['past_page']:
            damage.append('drawn past the page bottom')
        print(f"{r['name']}: chart {r['chart']['height']}px, momentum {r['momentum']['height']}px "
              f"of its {r['page_bottom'] - r['momentum']['top']:.0f}px slot, "
              f"{len(r['rows'])} text lines drawn"
              + (f", {', '.join(damage)}" if damage else ''))
    print(json.dumps({'captures': len(results), 'failures': failures}, indent=2))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
