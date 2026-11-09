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
        '.background(Capsule().fill(on ? Theme.selectedPill : .clear))',
    ]:
        assert expected in source, expected
    pills = source.split('struct SegmentPills', 1)[1].split('struct GlassButton', 1)[0]
    assert 'Theme.fill)' not in pills, 'Nested segment track fill returned'
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


def rendered_rows(directory, expected):
    from PIL import Image
    manifest = json.loads((directory / 'swatches.json').read_text())
    result = []
    for entry in manifest:
        mode = entry['appearance']
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
            assert ratio >= row['minimum'], (mode, row['name'], ratio, row['minimum'])
            result.append(dict(appearance=mode, name=row['name'], foreground=hex_rgb(tuple(v/255 for v in fg)),
                               background=hex_rgb(tuple(v/255 for v in bg)), ratio=round(ratio, 4), minimum=row['minimum']))
    images = {}
    for mode in ('light', 'dark'):
        for page in ('home', 'week', 'settings'):
            path = directory / f'{mode}-{page}.png'
            with Image.open(path) as image:
                image.verify()
            images[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    report = dict(rows=result, images=images, failures=[])
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
    print(f'PASS: {len(rows)} pairs; all boundary/priority and unchanged ink gates met.')
