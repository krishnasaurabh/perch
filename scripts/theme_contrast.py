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
    source = (ROOT / 'Sources/PerchApp/Workspace/Theme.swift').read_text()
    surface = (ROOT / 'Sources/PerchApp/Workspace/Components/CardSurface.swift').read_text()
    pills = (ROOT / 'Sources/PerchApp/Workspace/Components/SegmentPills.swift').read_text()
    palette = (ROOT / 'Sources/PerchUI/ThemeTokens.swift').read_text()
    def token(name, mode, background=None):
        aliases = dict(rope='cardStroke', priorityHigh='warning', done='success',
                       prominent='accent', fill='control', fillStrong='controlHover',
                       fillPressed='controlPressed', selectedPill='selected')
        name = aliases.get(name, name)
        match = re.search(rf'static let {mode} = Palette\((.*?)\)\n', palette, re.S)
        assert match, f'Missing palette {mode}'
        field = re.search(rf'\b{name}: 0x([A-Fa-f0-9]+)', match[1])
        if field:
            return channels(int(field[1], 16))
        match = re.search(rf'static let {name}: UInt32 = 0x([A-Fa-f0-9]+)', palette)
        if match:
            return channels(int(match[1], 16))
        match = re.search(rf'static let {name} = Color.dynamic\(light: \(0x([A-Fa-f0-9]+), ([.0-9]+)\), dark: \(0x([A-Fa-f0-9]+), ([.0-9]+)\)\)', source)
        assert match, f'Unknown token {name}'
        raw, alpha = match.groups()[0:2] if mode == 'light' else match.groups()[2:4]
        return blend(channels(int(raw, 16)), background or (0, 0, 0), float(alpha))

    # Retain original production-boundary coverage, but bind the ink to its shared values.
    for name in ('text', 'secondary', 'tertiary', 'danger', 'info'):
        assert rf'static let {name} = ink(\.{name})' in source
    for name in ('sage', 'lavender', 'tile', 'tileStrong', 'chartCompleted', 'chartPlanned'):
        assert f'static let {name} = color(ThemeTokens.{name})' in source
    assert 'case .high: return warning' in source
    assert 'Theme.selectedPill' in pills and '.isSelected' in pills
    assert 'Theme.fill)' not in pills, 'Nested segment track fill returned'
    tasks = (ROOT / 'Sources/PerchApp/Workspace/TasksCard.swift').read_text()
    week = (ROOT / 'Sources/PerchApp/Workspace/WeekPage.swift').read_text()
    assert '.strokeBorder(Theme.inputStroke, lineWidth: focused ? 2 : 1)' in tasks
    assert '.strokeBorder(Theme.cardStroke, lineWidth: 1)' in surface
    assert '.strokeBorder(Theme.cardStroke)' in week
    assert '.strokeBorder(Theme.inputStroke, lineWidth: 1)' in week
    clips = (ROOT / 'Sources/PerchApp/Workspace/ClipsPage.swift').read_text()
    assert '.stroke(Theme.rope,' in clips
    rows = []
    def add(mode, label, foreground, background, minimum):
        ratio = contrast(foreground, background)
        assert ratio >= minimum, (mode, label, ratio, minimum)
        rows.append(dict(appearance=mode, name=label, foreground=hex_rgb(foreground),
                         background=hex_rgb(background), ratio=round(ratio, 4), minimum=minimum))
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
            ('text/card', 'text', card, 4.5), ('secondary/card', 'secondary', card, 4.5),
        ]:
            add(mode, label, token(name, mode, bg), bg, minimum)
        backgrounds = [('card', card), ('alternate', alternate), ('shell', (0, 0, 0))] if mode == 'dark' else [
            ('card', card), ('alternate', alternate), ('window', channels(0xF5F5F5)), ('form', (1, 1, 1))]
        for label, bg in backgrounds:
            for name in ('text', 'secondary', 'tertiary', 'success', 'danger', 'warning', 'info'):
                add(mode, f'{name}/{label} readable', token(name, mode), bg, 4.5)
        for state, name in [('rest', 'fill'), ('hover', 'fillStrong'), ('pressed', 'fillPressed'), ('selected', 'selectedPill')]:
            bg = token(name, mode)
            for ink in ('text', 'secondary', 'tertiary'):
                add(mode, f'{ink}/control-{state}', token(ink, mode), bg, 4.5)
        for label, bg in [('card', card), ('alternate', alternate)]:
            for state, fill in [('rest', 'inputFill'), ('focused', 'inputFillFocused')]:
                add(mode, f'input-text/{label}-{state}', token('text', mode), token(fill, mode, bg), 4.5)
            add(mode, f'focus-ring/{label}', token('info', mode), bg, 3)
        add(mode, 'prominent-label', token('onAccent', mode), token('prominent', mode), 4.5)
        # Chart colors do not vary with the desktop appearance. Both series must
        # contrast with the timer card AND with each other where they overlap.
        lavender = token('lavender', mode)
        add(mode, 'planned-chart/lavender', token('chartPlanned', mode), lavender, 3)
        add(mode, 'completed-chart/lavender', token('chartCompleted', mode), lavender, 3)
        add(mode, 'completed-chart/planned-chart', token('chartCompleted', mode), token('chartPlanned', mode), 3)
        if mode == 'light':
            add(mode, 'focus-progress/track', token('text', mode), token('chartPlanned', mode), 3)
    assert len({(r['appearance'], r['name']) for r in rows}) == len(rows)
    return rows


def design_palette():
    source = (ROOT / 'Sources/PerchUI/DesignTokens.swift').read_text()
    pairs = re.findall(r'case \.(\w+):\s*return AdaptiveColor\(light: 0x([0-9A-Fa-f]+), dark: 0x([0-9A-Fa-f]+)\)', source)
    palette = {name: dict(light=int(light, 16), dark=int(dark, 16)) for name, light, dark in pairs}
    assert len(palette) == 27, 'Incomplete design palette'
    fixes = re.findall(r'if self == \.(\w+) && background == \.(\w+) && appearance == \.(\w+) \{.*?return 0x([0-9A-Fa-f]+)', source, re.S)
    corrections = {(mode, foreground, background): int(value, 16)
                   for foreground, background, mode, value in fixes}
    assert len(corrections) == 3, 'Missing pair-specific contrast corrections'
    return palette, corrections


def design_rows():
    """Gate text and meaningful graphics; retain authored values alongside corrections.

    Card edges and the dot grid are decorative, not control boundaries. They are
    reported without claiming the 3:1 threshold. Band text is white, not light ink.
    """
    palette, corrections = design_palette()
    surfaces = ('sheet', 'paper', 'butter', 'blush', 'apricot', 'mint', 'field')
    rows = []
    def add(mode, foreground, background, minimum):
        original = palette[foreground][mode]
        fg = corrections.get((mode, foreground, background), original)
        bg = palette[background][mode]
        actual = contrast(channels(fg), channels(bg))
        assert actual >= minimum, (mode, foreground, background, actual, minimum)
        rows.append(dict(appearance=mode, name=f'{foreground}/{background}',
                         foreground=hex_rgb(channels(fg)), background=hex_rgb(channels(bg)),
                         authored_foreground=hex_rgb(channels(original)),
                         authored_ratio=contrast(channels(original), channels(bg)),
                         ratio=actual, minimum=minimum))
    for mode in ('light', 'dark'):
        for surface in surfaces:
            for ink in ('ink', 'ink2', 'brandText', 'carried', 'doneText'):
                add(mode, ink, surface, 4.5)
            for graphic in ('focusRing', 'brandFill', 'doneFill'):
                add(mode, graphic, surface, 3)
        for surface in ('sheet', 'paper', 'butter', 'mint'):
            add(mode, 'ink3', surface, 4.5)
        add(mode, 'onBrand', 'brandFill', 4.5)
        add(mode, 'onDone', 'doneFill', 3)
        add(mode, 'white', 'switchOff', 3)
        add(mode, 'paper', 'ink', 4.5)  # Selected segment label.
        add(mode, 'white', 'band', 4.5)
        add(mode, 'focusRing', 'band', 3)
        add(mode, 'dot', 'sheet', 0)
        for surface in ('paper', 'butter', 'blush', 'apricot', 'mint'):
            add(mode, surface + 'Edge', surface, 0)
    assert len({(r['appearance'], r['name']) for r in rows}) == len(rows)
    return rows


def nearest_passing_rgb(foreground, background, minimum):
    """Exact nearest 8-bit sRGB color by squared channel distance; ties use hex order."""
    import bisect
    linear = [v / 255 / 12.92 if v / 255 <= .04045 else ((v / 255 + .055) / 1.055) ** 2.4 for v in range(256)]
    original = tuple((foreground >> shift) & 255 for shift in (16, 8, 0))
    luminance = sum(w * linear[(background >> s) & 255] for w, s in zip((.2126, .7152, .0722), (16, 8, 0)))
    best = None
    for red in range(256):
        for green in range(256):
            partial = .2126 * linear[red] + .7152 * linear[green]
            low = ((luminance + .05) / minimum - .05 - partial) / .0722
            high = (minimum * (luminance + .05) - .05 - partial) / .0722
            for blue in (min(original[2], bisect.bisect_right(linear, low) - 1),
                         max(original[2], bisect.bisect_left(linear, high))):
                if not 0 <= blue <= 255:
                    continue
                value = red << 16 | green << 8 | blue
                distance = sum((a - b) ** 2 for a, b in zip(original, (red, green, blue)))
                if best is None or (distance, value) < best:
                    best = (distance, value)
    assert best is not None, 'No color reaches the threshold'
    return best[1]


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
    palette = (ROOT / 'Sources/PerchUI/ThemeTokens.swift').read_text()
    dark = re.search(r'static let dark = Palette\((.*?)\)\n', palette, re.S)
    assert dark, 'Missing dark palette'
    control = re.search(r'\bcontrol: 0x([A-Fa-f0-9]+)', dark[1])
    assert control, 'Missing Week control fill'
    week_fill = tuple(round(v * 255) for v in channels(int(control[1], 16)))
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
            'week_capture': edge(week, (153,153,153), week_fill),
        }
        # A 2 pt focused outline must contain appreciably more ink than the 1 pt resting edge.
        def count(image, color):
            colors = image.getcolors(image.width*image.height)
            assert colors is not None
            return sum(n for n,c in colors if near(c, color))
        resting_count, focused_count = count(home, (41,53,45)), count(focused, (41,53,45))
        assert focused_count > resting_count * 1.3, ('Capture did not focus', mode, resting_count, focused_count)
        assert count(home, (53,33,0)) >= 8, ('High-priority Home marker missing', mode)
        assert count(week, (242,193,102)) >= 8, ('High-priority Week marker missing', mode)
        selection_count = count(home, (157,173,161))
        assert selection_count > 50, ('Single opaque selected pill missing', mode)
        evidence[mode].update(resting_stroke_pixels=resting_count, focused_stroke_pixels=focused_count,
                              selected_fill_pixels=selection_count)
    return evidence


def control_pixels(directory):
    """Measure real disabled button labels and the independent, unclipped focus ring."""
    from collections import Counter
    from PIL import Image
    manifest = json.loads((directory / 'controls.json').read_text())
    expected = {f'{a}-{c}-{t}-{s}-{k}x.png' for a in ('light', 'dark')
                for c in ('standard', 'increased') for t in ('sage', 'lavender', 'tile')
                for s in ('rest', 'focused', 'disabled') for k in (1, 2)}
    assert len(manifest) == len(expected) and {r['file'] for r in manifest} == expected
    results = []
    for row in manifest:
        expected_focus = 'continue' if row['state'] == 'focused' else 'before-pages'
        if row.get('focus_evidence') == 'rendered-ring':
            # A rendered production ring proves its pixels, not native keyboard focus.
            assert row['state'] == 'focused' and row.get('focus_ring_target') == 'continue', (row['file'], 'ring target')
            assert row.get('focused_control'), (row['file'], 'missing observed focus identity')
            assert row.get('keyboardActivation') == 'unverified-on-this-runner', (row['file'], 'keyboard claim')
        else:
            assert row.get('focus_evidence', 'native-focus') == 'native-focus', (row['file'], 'focus evidence')
            assert row.get('focused_control') == expected_focus, (row['file'], 'focus identity', row.get('focused_control'))
        image = Image.open(directory / row['file']).convert('RGB')
        scale = row['scale']
        assert image.size == (528 * scale, 318 * scale), (row['file'], image.size)
        light = row['tone'] != 'tile'
        ink = (9, 12, 10) if light else (245, 247, 245)
        focus = (9, 38, 63) if light else (144, 199, 255)
        x, y, w, h = row['frames']['unavailable']
        assert w >= 28 and h >= 32
        crop = image.crop((round((x+5)*scale), round((y+4)*scale), round((x+w-5)*scale), round((y+h-4)*scale)))
        colors = Counter(p for p in crop.get_flattened_data() if isinstance(p, tuple))
        background = colors.most_common(1)[0][0]
        candidates = [(n, c) for c, n in colors.items() if max(abs(a-b) for a, b in zip(c, ink)) <= 5]
        assert candidates and sum(n for n, c in candidates) >= 5 * scale, (row['file'], 'disabled glyphs missing')
        foreground = max(candidates)[1]
        ratio = contrast(tuple(v/255 for v in foreground), tuple(v/255 for v in background))
        assert ratio >= 4.5, (row['file'], 'disabled label', ratio)
        x, y, w, h = row['frames']['continue']
        assert x >= 4 and y >= 4 and x+w+4 <= 528 and y+h+4 <= 318, 'Focus ring clipped'
        top = image.getpixel((round((x+w/2)*scale), round((y-3)*scale)))
        gap = image.getpixel((round((x+w/2)*scale), round((y-1)*scale)))
        assert isinstance(top, tuple) and isinstance(gap, tuple)
        if row['state'] == 'focused':
            assert max(abs(a-b) for a,b in zip(top,focus)) <= 5, (row['file'], 'focus ring missing', top, focus)
            ring_ratio = contrast(tuple(v/255 for v in top), tuple(v/255 for v in gap))
            assert ring_ratio >= 3, (row['file'], 'focus separation', ring_ratio)
        else:
            assert max(abs(a-b) for a,b in zip(top,focus)) > 5, (row['file'], 'unfocused ring visible')
        results.append(dict(file=row['file'], disabled_ratio=round(ratio, 4), focus_sample=top))
    return results


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
        for scale in (1, 2):
            image = Image.open(directory / f"{mode}-swatches{'-2x' if scale == 2 else ''}.png").convert('RGB')
            assert image.size == (360 * scale, len(entry['rows']) * 30 * scale), image.size
            for i, row in enumerate(entry['rows']):
                fg, bg = [image.getpixel((x * scale, (i * 30 + 15) * scale)) for x in (30, 90)]
                assert isinstance(fg, tuple) and isinstance(bg, tuple)
                ratio = contrast(tuple(v/255 for v in fg), tuple(v/255 for v in bg))
                want = next(r for r in expected if r['appearance'] == mode and r['name'] == row['name'])
                for actual, field in ((fg, 'foreground'), (bg, 'background')):
                    reference = tuple(int(want[field][j:j+2], 16) for j in (1, 3, 5))
                    assert max(abs(a-b) for a,b in zip(actual, reference)) <= 2, (mode, row['name'], actual, reference)
                assert row['minimum'] == want['minimum'], (mode, row['name'], 'gate changed')
                assert ratio >= want['minimum'], (mode, row['name'], ratio, want['minimum'])
                # Require actual readable glyph interiors, not just two color swatches.
                glyphs = image.crop((140*scale, i*30*scale, 340*scale, (i+1)*30*scale))
                matches = sum(max(abs(a-b) for a,b in zip(p,fg)) <= 5 for p in glyphs.get_flattened_data() if isinstance(p, tuple))
                assert matches >= 8 * scale, (mode, row['name'], scale, 'missing glyphs', matches)
                result.append(dict(appearance=mode, name=row['name'], scale=scale, foreground=hex_rgb(tuple(v/255 for v in fg)),
                                   background=hex_rgb(tuple(v/255 for v in bg)), ratio=round(ratio, 4), minimum=row['minimum']))
    assert len(result) == len(expected) * 2, 'Incomplete rendered color coverage'
    images = {}
    for mode in ('light', 'dark'):
        for page in ('home', 'week', 'settings'):
            path = directory / f'{mode}-{page}.png'
            with Image.open(path) as image:
                image.verify()
            images[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    report = dict(rows=result, images=images, ui=ui_pixels(directory), controls=control_pixels(directory), failures=[])
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
    parser.add_argument('--design', action='store_true', help='report the appearance-aware design palette')
    args = parser.parse_args()
    design = design_rows()  # Always gate the new palette, including native legacy probes.
    rows = design if args.design else source_rows()
    if args.pixels:
        assert not args.design, 'The legacy pixel probe does not render design tokens'
        rows = rendered_rows(args.pixels, rows)
    print(table(rows))
    if not args.design:
        print("\nAppearance-aware palette:")
        print(table(design))
    for row in design:
        if row['authored_foreground'] != row['foreground']:
            print(f"Correction: {row['appearance']} {row['name']}: "
                  f"{row['authored_foreground']} ({row['authored_ratio']:.6f}:1) -> "
                  f"{row['foreground']} ({row['ratio']:.6f}:1)")
    print(f'PASS: {len(rows)} reported pairs; text >=4.5:1 and meaningful graphics >=3:1.')
