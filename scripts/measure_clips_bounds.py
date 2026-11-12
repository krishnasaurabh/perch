"""Gate real Clips PNGs: all painted content stays inside the card rectangle.

The fixture has an opaque black shell, no app window shadow, and a known 24pt
card inset. Testing the entire exterior is stricter than testing just the rope.
Pillow is used only by CI/evidence inspection, not by the app.
"""
import json
from pathlib import Path
import sys
from PIL import Image


def measure(folder):
    folder = Path(folder)
    records = json.loads((folder / 'captures.json').read_text())
    assert len(records) == 16, f'expected 2 appearances x 2 widths x 4 states, got {len(records)}'
    results = []
    for record in records:
        image = Image.open(folder / record['file']).convert('RGBA')
        sx, sy = image.width / record['width'], image.height / record['height']
        assert sx == sy, 'fixture scale differs on x/y'
        left, top, right, bottom = [round(n * sx) for n in record['card']]
        rgb = Image.new('RGBA', image.size, (0, 0, 0, 255))
        rgb.alpha_composite(image)
        rgb = rgb.convert('RGB')
        regions = [(0, 0, left, image.height), (right, 0, image.width, image.height),
                   (left, 0, right, top), (left, bottom, right, image.height)]
        outside = sum(max(pixel) > 8 for box in regions for pixel in rgb.crop(box).getdata())
        # The first 6pt after the rope's cap, before a clip's paper body, cannot
        # contain header text or the centered empty message. It must contain line ink.
        # The native probe measures the rope's left end from each actual-view
        # capture after toolbar reflow. Translate the original 7 x 34pt ROI only.
        rope_y = record['rope_y']
        rope_roi = (round(43 * sx), round((rope_y - 15) * sx),
                    round(50 * sx), round((rope_y + 19) * sx))
        rope_ink = sum(min(p) > 45 and max(p) - min(p) < 5 for p in rgb.crop(rope_roi).getdata())
        results.append(dict(file=record['file'], exterior_painted_pixels=outside,
                            left_rope_ink_pixels=rope_ink, scale=sx))
    return results


def main():
    folder = Path(sys.argv[1])
    results = measure(folder)
    (folder / 'pixel-check.json').write_text(json.dumps(results, indent=2) + '\n')
    failures = [r for r in results if r['exterior_painted_pixels'] or not r['left_rope_ink_pixels']]
    print(json.dumps({'snapshots': len(results), 'failures': failures}, indent=2))
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
