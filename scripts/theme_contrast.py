#!/usr/bin/env python3
"""Compute WCAG contrast from production tokens; optionally verify real CI pixels."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def channels(value):
    return tuple(((value >> shift) & 255) / 255 for shift in (16, 8, 0))


def blend(foreground, background, alpha):
    return tuple(f * alpha + b * (1 - alpha) for f, b in zip(foreground, background))


def contrast(a, b):
    def luminance(rgb):
        return sum(weight * (v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4)
                   for weight, v in zip((.2126, .7152, .0722), rgb))
    lo, hi = sorted((luminance(a), luminance(b)))
    return (hi + .05) / (lo + .05)


def hex_rgb(rgb):
    return '#' + ''.join(f'{round(v * 255):02X}' for v in rgb)


def source_rows():
    source = (ROOT / 'Sources/Perch/Workspace/Theme.swift').read_text()
    def token(name, mode, background=None):
        match = re.search(rf'static let {name} = Color.dynamic\(light: \(0x([A-Fa-f0-9]+), ([.0-9]+)\), dark: \(0x([A-Fa-f0-9]+), ([.0-9]+)\)\)', source)
        if match:
            raw, alpha = match.groups()[0:2] if mode == 'light' else match.groups()[2:4]
            return blend(channels(int(raw, 16)), background or (0, 0, 0), float(alpha))
        match = re.search(rf'static let {name} = Color\(hex: "#([A-Fa-f0-9]+)"\)', source)
        assert match, f'Unknown token shape: {name}'
        return channels(int(match[1], 16))

    # These roles are intentionally unchanged, including translucent ink and surface fills.
    for expected in [
        'static let text = Color.dynamic(light: (0x000000, 0.90), dark: (0xFFFFFF, 0.92))',
        'static let secondary = Color.dynamic(light: (0x000000, 0.74), dark: (0xFFFFFF, 0.62))',
        'static let tertiary = Color.dynamic(light: (0x000000, 0.62), dark: (0xFFFFFF, 0.45))',
        'static let danger = Color.dynamic(light: (0x5C110B, 1), dark: (0xFF6B6B, 1))',
        'case .high: return priorityHigh',
        'static let selectedPill = Color.dynamic(light: (0x9DADA1, 1), dark: (0x333333, 1))',
        '.background(Capsule().fill(on ? Theme.selectedPill : .clear))',
    ]:
        assert expected in source, expected
    pills = source.split('struct SegmentPills', 1)[1].split('struct GlassButton', 1)[0]
    assert 'Theme.fill)' not in pills, 'Nested segment track fill returned'
    # Cover the production wiring, not just a disconnected palette.
    tasks = (ROOT / 'Sources/Perch/Workspace/TasksCard.swift').read_text()
    week = (ROOT / 'Sources/Perch/Workspace/WeekAndClips.swift').read_text()
    assert '.strokeBorder(Theme.inputStroke, lineWidth: focused ? 2 : 1)' in tasks
    assert '.strokeBorder(Theme.cardStroke, lineWidth: 1)' in source
    assert '.strokeBorder(Theme.cardStroke)' in week
    assert '.strokeBorder(Theme.inputStroke, lineWidth: 1)' in week
    assert '.stroke(Theme.rope,' in week
    rows = []
    for mode in ('light', 'dark'):
        card = token('sage' if mode == 'light' else 'tile', mode)
        alternate = token('lavender' if mode == 'light' else 'tileStrong', mode)
        for label, name, bg, minimum in [
            ('card silhouette/body', 'sage' if mode == 'light' else 'cardStroke', (0, 0, 0), 3),
            ('alternate silhouette/body', 'lavender' if mode == 'light' else 'cardStroke', (0, 0, 0), 3),
            ('cardStroke/card', 'cardStroke', card, 3),
            ('cardStroke/alternate', 'cardStroke', alternate, 3),
            ('inputStroke/card', 'inputStroke', card, 3),
            ('inputStroke/resting', 'inputStroke', token('inputFill', mode, card), 3),
            ('inputStroke/focused', 'inputStroke', token('inputFillFocused', mode, card), 3),
            ('inputStroke/miniComposer', 'inputStroke', blend((1, 1, 1), card, .05), 3),
            ('inputStroke/alternateFocused', 'inputStroke', token('inputFillFocused', mode, alternate), 3),
            ('rope/card', 'rope', card, 3), ('rope/alternate', 'rope', alternate, 3),
            ('priority/card', 'priorityHigh', card, 3), ('priority/alternate', 'priorityHigh', alternate, 3),
            ('selected/card (informational)', 'selectedPill', card, 0),
            ('text/card (unchanged)', 'text', card, 4.5),
            ('secondary/card (unchanged)', 'secondary', card, 4.5),
        ]:
            fg = token(name, mode, bg)
            ratio = contrast(fg, bg)
            assert ratio >= minimum, (mode, label, ratio, minimum)
            rows.append(dict(appearance=mode, name=label, foreground=hex_rgb(fg),
                             background=hex_rgb(bg), ratio=round(ratio, 4), minimum=minimum))
    return rows


def ui_pixels(directory):
    """Gate actual edges, plus the filled selected pill, in production Home/Week."""
    from PIL import Image
    def near(a, b):
        return max(abs(x-y) for x,y in zip(a,b)) <= 2
    def edge(image, foreground, background):
        pixels = image.load()
        scale = max(1, round(image.width / 868))
        matches = []
        for y in range(3*scale, image.height-3*scale):
            for x in range(3*scale, image.width-3*scale):
                fg = pixels[x,y]
                if not near(fg, foreground):
                    continue
                for dx,dy in ((2*scale,0),(-2*scale,0),(0,2*scale),(0,-2*scale)):
                    bg = pixels[x+dx,y+dy]
                    if near(bg, background):
                        matches.append(contrast(tuple(v/255 for v in fg), tuple(v/255 for v in bg)))
                        break
        assert len(matches) >= 30, ('Missing production boundary', foreground, background, len(matches))
        assert min(matches) >= 3, ('Low production boundary contrast', min(matches))
        return {'adjacent_samples': len(matches), 'minimum_ratio': round(min(matches), 4)}
    evidence = {}
    for mode in ('light', 'dark'):
        home = Image.open(directory / f'{mode}-home.png').convert('RGB')
        focused = Image.open(directory / f'{mode}-home-focused.png').convert('RGB')
        week = Image.open(directory / f'{mode}-week.png').convert('RGB')
        evidence[mode] = {
            'home_card': edge(home, (47,61,51), (135,158,141)),
            'home_capture_resting': edge(home, (41,53,45), (124,145,130)),
            'home_capture_focused': edge(focused, (41,53,45), (119,139,124)),
            'week_card': edge(week, (133,133,133), (29,29,29)),
            'week_capture': edge(week, (153,153,153), (40,40,40)),
        }
        # A 2 pt focused outline must contain appreciably more ink than the 1 pt resting edge.
        def count(image, color):
            colors = image.getcolors(image.width*image.height)
            assert colors is not None
            return sum(n for n,c in colors if near(c, color))
        resting_count, focused_count = count(home, (41,53,45)), count(focused, (41,53,45))
        assert focused_count > resting_count * 1.3, ('Capture did not focus', mode, resting_count, focused_count)
        assert count(home, (39,61,46)) >= 8, ('High-priority Home marker missing', mode)
        assert count(week, (185,198,186)) >= 8, ('High-priority Week marker missing', mode)
        selection_count = count(home, (157,173,161))
        assert selection_count > 50, ('Single opaque selected pill missing', mode)
        evidence[mode].update(resting_stroke_pixels=resting_count, focused_stroke_pixels=focused_count,
                              selected_fill_pixels=selection_count)
    return evidence


def insights_measurements(image, mode):
    """Measure actual production glyphs, not swatches or RGBA arithmetic.

    The fixture is the CI seven-day Tasks chart at the normal workspace size.
    Locate its lavender card, then sample label-only ROIs relative to that card;
    bars/swatch pixels cannot satisfy a text gate. Each day is measured separately
    so a bold Today cannot conceal a faint earlier date. The foreground is the
    darkest RGB occurring >=5 times (>=2 for a single date digit), as in the
    capture audit. Antialiased edge pixels are not claimed to meet WCAG.
    Cards intentionally resolve to light ink under BOTH host appearances.
    """
    from collections import Counter
    pixels = image.load()
    scale = image.width / 868
    assert scale in (1, 2), ('Unexpected Insights backing scale', image.size)
    lavender = (147, 142, 171)
    points = [(x, y) for y in range(image.height) for x in range(image.width)
              if pixels[x, y] == lavender]
    assert points, 'Missing Insights lavender card'
    left, top = min(x for x, y in points), min(y for x, y in points)
    right, bottom = max(x for x, y in points) + 1, max(y for x, y in points) + 1
    assert 498 <= (right-left)/scale <= 506 and 294 <= (bottom-top)/scale <= 302, (
        'Unexpected Insights card bounds', (left, top, right, bottom))

    def box(x0, y0, x1, y1):
        return tuple(round(v) for v in (left+x0*scale, top+y0*scale,
                                        left+x1*scale, top+y1*scale))
    width, height = (right-left)/scale, (bottom-top)/scale
    regions = {
        'scale': box(13, 50, 95, 68),
        'date-range': box(width-180, 16, width-13, 38),
        'legend-completed': box(27, height-31, 91, height-11),
        'legend-planned': box(112, height-31, 166, height-11),
    }
    stride = (width-26+14)/7
    for i in range(7):
        x = 13 + i*stride
        regions[f'weekday-{i}'] = box(x, height-68, x+stride-14, height-50)
        regions[f'date-{i}'] = box(x, height-50, x+stride-14, height-32)
    rows = []
    for name, roi in regions.items():
        counts = Counter(image.crop(roi).getdata())
        bg = counts.most_common(1)[0][0]
        assert bg == lavender, (mode, name, 'ROI not on the chart surface', bg)
        repeated = 2 if name.startswith('date-') and name != 'date-range' else 5
        ink = [p for p, n in counts.items() if n >= repeated*scale*scale
               and max(abs(a-b) for a,b in zip(p,bg)) > 8]
        assert ink, (mode, name, 'Missing rendered glyphs', roi)
        fg = max(ink, key=lambda p: contrast(tuple(v/255 for v in p), tuple(v/255 for v in bg)))
        rows.append(dict(appearance=mode, name=name, roi=list(roi),
                         foreground=hex_rgb(tuple(v/255 for v in fg)),
                         background=hex_rgb(tuple(v/255 for v in bg)),
                         ink_count=counts[fg], ratio=contrast(tuple(v/255 for v in fg), tuple(v/255 for v in bg)), minimum=4.5))
    # Flat bar interiors in the matching CI fixture: no gridline, text, or rounded edge.
    planned_box, completed_box = box(20, 76, 52, 110), box(20, 146, 52, 210)
    planned = Counter(image.crop(planned_box).getdata()).most_common(1)[0][0]
    completed = Counter(image.crop(completed_box).getdata()).most_common(1)[0][0]
    for name, fg, bg, minimum, roi in (
        ('planned/card', planned, lavender, 3, planned_box),
        ('completed/planned', completed, planned, 1.5, completed_box),
    ):
        rows.append(dict(appearance=mode, name=name, roi=list(roi),
                         foreground=hex_rgb(tuple(v/255 for v in fg)),
                         background=hex_rgb(tuple(v/255 for v in bg)),
                         ratio=contrast(tuple(v/255 for v in fg), tuple(v/255 for v in bg)), minimum=minimum))
    return rows


def gate_insights(rows):
    expected = {'scale', 'date-range', 'legend-completed', 'legend-planned',
                'planned/card', 'completed/planned'} | {f'{kind}-{i}' for kind in ('weekday', 'date') for i in range(7)}
    assert len(rows) == len(expected) and {r['name'] for r in rows} == expected, 'Incomplete Insights coverage'
    for row in rows:
        minimum = {'planned/card': 3, 'completed/planned': 1.5}.get(row['name'], 4.5)
        assert row['minimum'] == minimum, ('Insights gate changed', row)
        assert row['ratio'] >= minimum, ('Insights contrast', row)


def insights_pixels(directory):
    from PIL import Image
    result = []
    for mode in ('light', 'dark'):
        image = Image.open(directory / f'{mode}-insights.png').convert('RGB')
        rows = insights_measurements(image, mode)
        gate_insights(rows)
        # Fail-closed negative controls on the real bitmap. Every text ROI must
        # independently reject both blank glyphs and the original low-contrast ink.
        negatives = 0
        for row in rows:
            if row['minimum'] != 4.5:
                continue
            for fill in ((147, 142, 171), (56, 54, 65)):
                bad = image.copy()
                x0,y0,x1,y1 = row['roi']
                pixels = bad.load()
                assert pixels is not None
                for y in range(y0, y1):
                    for x in range(x0, x1):
                        if pixels[x,y] != (147, 142, 171):
                            pixels[x,y] = fill
                try:
                    gate_insights(insights_measurements(bad, mode))
                except AssertionError:
                    negatives += 1
                else:
                    raise AssertionError(('Insights negative accepted', mode, row['name'], fill))
        assert negatives == 36
        result.extend(rows)
    return result


def rendered_rows(directory, expected):
    from PIL import Image
    manifest = json.loads((directory / 'swatches.json').read_text())
    result = []
    assert len(manifest) == 2 and {e['appearance'] for e in manifest} == {'light', 'dark'}
    for entry in manifest:
        mode = entry['appearance']
        expected_names = {r['name'] for r in expected if r['appearance'] == mode}
        assert len(entry['rows']) == len(expected_names)
        assert {r['name'] for r in entry['rows']} == expected_names
        image = Image.open(directory / f'{mode}-swatches.png').convert('RGB')
        scale = image.width / 120
        assert image.height == round(len(entry['rows']) * 30 * scale)
        for i, row in enumerate(entry['rows']):
            fg, bg = [image.getpixel((round(x * scale), round((i * 30 + 15) * scale))) for x in (30, 90)]
            assert isinstance(fg, tuple) and isinstance(bg, tuple) and len(fg) == len(bg) == 3
            ratio = contrast(tuple(v/255 for v in fg), tuple(v/255 for v in bg))
            want = next(r for r in expected if r['appearance'] == mode and r['name'] == row['name'])
            for actual, field in ((fg, 'foreground'), (bg, 'background')):
                reference = tuple(int(want[field][j:j+2], 16) for j in (1, 3, 5))
                assert max(abs(a-b) for a,b in zip(actual, reference)) <= 2, (mode, row['name'], actual, reference)
            assert row['minimum'] == want['minimum'], (mode, row['name'], 'gate changed')
            assert ratio >= want['minimum'], (mode, row['name'], ratio, want['minimum'])
            result.append(dict(appearance=mode, name=row['name'], foreground=hex_rgb(tuple(v/255 for v in fg)),
                               background=hex_rgb(tuple(v/255 for v in bg)), ratio=round(ratio, 4), minimum=row['minimum']))
    assert len(result) == len(expected), 'Incomplete rendered color coverage'
    images = {}
    for mode in ('light', 'dark'):
        for page in ('home', 'week', 'settings', 'insights'):
            path = directory / f'{mode}-{page}.png'
            with Image.open(path) as image:
                image.verify()
            images[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    report = dict(rows=result, images=images, ui=ui_pixels(directory),
                  insights=insights_pixels(directory), insights_negative_controls=72, failures=[])
    (directory / 'pixel-contrast.json').write_text(json.dumps(report, indent=2) + '\n')
    return result


def table(rows):
    output = ['| Appearance | Token / background | Foreground | Background | Ratio | Gate |',
              '|---|---|---|---|---:|---:|']
    for row in rows:
        output.append(f"| {row['appearance']} | {row['name']} | `{row['foreground']}` | `{row['background']}` | {row['ratio']:.3f}:1 | {str(row['minimum']) + ':1' if row['minimum'] else 'informational'} |")
    return '\n'.join(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--pixels', type=Path)
    args = parser.parse_args()
    rows = source_rows()
    if args.pixels:
        rows = rendered_rows(args.pixels, rows)
    print(table(rows))
    if args.pixels:
        report = json.loads((args.pixels / 'pixel-contrast.json').read_text())
        print(table(report['insights']))
        print('PASS: 36 rendered small labels, both appearances; Planned/card >=3:1; 72 negative controls.')
    print(f'PASS: {len(rows)} pairs; all boundary/priority and unchanged ink gates met.')
