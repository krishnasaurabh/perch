#!/usr/bin/env python3
"""Measure rendered contrast of the Today capture field in Perch snapshot PNGs (stdlib only).

Usage:
  measure_capture_contrast.py STATE_DIR...          gate: placeholder >= 4.5:1, plus/mic >= 3:1, and a
                                                    directory named *-focused / *-unfocused / *-passive
                                                    must show the matching focused / resting fill
  measure_capture_contrast.py --report STATE_DIR... same measurements, never fails
  measure_capture_contrast.py --diff A.png B.png [--outside-field]
                                                    count changed pixels (optionally outside the field)

Each STATE_DIR holds one `notch-*-open.png` written by `NotchController.snapshot(into:)`.

Method for measuring rendered capture-field contrast:
1. Field: the widest contiguous band of rows whose pixels match the capture fill, sage `#879E8D` with
   black 8 % (resting) or 12 % (focused) over it, +/-3 per channel. ROI = that band inset 2 px vertically
   and 4 px horizontally, so the rounded corners and the 1.5 pt focus stroke are excluded.
2. Background = the modal ROI colour. Ink = pixels differing from it by more than 8 in any channel.
3. Ink columns are split into clusters at gaps of >= 6 px: first = plus icon, last = mic, the rest = prompt.
   A 1-2 px column cluster whose vertical ink run spans >= 34 % of the band is a text caret, reported and excluded.
4. Primary ratio (same as the review's audit_evidence.py): the darkest colour occurring >= 5 times in the cluster
   versus the background, sRGB relative luminance (WCAG 2.x). Secondary "core": median colour of the darkest
   quartile of ink pixels, a stricter anti-aliasing-aware figure, reported but not gated.
This measures a settled own-window bitmap, not a physical display or every appearance.
"""
import json
import struct
import sys
import zlib
from collections import Counter
from pathlib import Path

SAGE = (0x87, 0x9E, 0x8D)
FILLS = {"resting": 0.08, "focused": 0.12}
PLACEHOLDER_MIN, CONTROL_MIN = 4.5, 3.0


def read_png(path):
    data = Path(path).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path}: not a PNG"
    pos, idat, w, h, bpp = 8, b"", 0, 0, 3
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and ctype in (2, 6) and interlace == 0, f"{path}: unsupported PNG format"
            bpp = 4 if ctype == 6 else 3
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    raw, stride, prev, rows, i = zlib.decompress(idat), w * bpp, bytearray(w * bpp), [], 0
    for _ in range(h):
        f, line = raw[i], bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 0xFF
            elif f == 2: line[x] = (line[x] + b) & 0xFF
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 0xFF
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        rows.append([tuple(line[x:x + 3]) for x in range(0, stride, bpp)])
        prev = line
    return rows


def luminance(rgb):
    def lin(v):
        c = v / 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return sum(k * lin(v) for k, v in zip((0.2126, 0.7152, 0.0722), rgb))


def ratio(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def near(p, q, tol):
    return all(abs(x - y) <= tol for x, y in zip(p, q))


def over_black(alpha):
    return tuple(round(v * (1 - alpha)) for v in SAGE)


def find_field(img):
    """Return (state, y0, y1, x0, x1) for the widest band of rows dominated by a capture fill."""
    best = None
    for state, alpha in FILLS.items():
        fill = over_black(alpha)
        good = [sum(near(p, fill, 3) for p in row) >= 0.3 * len(row) for row in img]
        y = 0
        while y < len(img):
            if not good[y]:
                y += 1
                continue
            y0 = y
            while y < len(img) and good[y]:
                y += 1
            if best is None or y - y0 > best[2] - best[1]:
                best = (state, y0, y, fill)
    assert best and best[2] - best[1] >= 12, "capture field not found"
    state, y0, y1, fill = best
    xs = [x for row in img[y0:y1] for x, p in enumerate(row) if near(p, fill, 3)]
    return state, y0, y1, min(xs), max(xs) + 1


def measure(path):
    img = read_png(path)
    state, fy0, fy1, fx0, fx1 = find_field(img)
    y0, y1, x0, x1 = fy0 + 2, fy1 - 2, fx0 + 4, fx1 - 4
    roi = [row[x0:x1] for row in img[y0:y1]]
    bg = Counter(p for row in roi for p in row).most_common(1)[0][0]
    ink = [[max(abs(a - b) for a, b in zip(p, bg)) > 8 for p in row] for row in roi]
    cols = [any(ink[y][x] for y in range(len(roi))) for x in range(x1 - x0)]
    clusters, x = [], 0
    while x < len(cols):
        if not cols[x]:
            x += 1
            continue
        s, gap = x, 0
        while x < len(cols) and gap < 6:
            gap = 0 if cols[x] else gap + 1
            x += 1
        clusters.append([s, x - gap])
    assert len(clusters) >= 3, f"{path}: expected plus, prompt and mic, got {len(clusters)} ink clusters"

    def longest_run(cx):
        best = run = 0
        for y in range(len(roi)):
            run = run + 1 if ink[y][cx] else 0
            best = max(best, run)
        return best

    caret = []
    text = []
    for s, e in clusters[1:-1]:
        if e - s <= 2 and max(longest_run(c) for c in range(s, e)) >= 0.34 * (fy1 - fy0):
            caret.append([x0 + s, x0 + e])
        else:
            text.append((s, e))
    assert text, f"{path}: no prompt glyphs found"

    def stats(spans):
        px = [roi[y][c] for s, e in spans for c in range(s, e) for y in range(len(roi)) if ink[y][c]]
        counts = Counter(px)
        dark = min((p for p, n in counts.items() if n >= 5), key=luminance, default=min(px, key=luminance))
        core = sorted(px, key=luminance)[: max(1, len(px) // 4)]
        median = core[len(core) // 2]
        return {"ink_rgb": "#%02X%02X%02X" % dark, "ink_count": counts[dark], "ratio": round(ratio(dark, bg), 3),
                "core_rgb": "#%02X%02X%02X" % median, "core_ratio": round(ratio(median, bg), 3),
                "ink_pixels": len(px), "x": [x0 + spans[0][0], x0 + spans[-1][1]]}

    return {
        "image": str(path), "size": [len(img[0]), len(img)], "field_state": state,
        "field_xyxy": [fx0, fy0, fx1, fy1], "roi_xyxy": [x0, y0, x1, y1], "background_rgb": "#%02X%02X%02X" % bg,
        "plus": stats([clusters[0]]), "placeholder": stats(text), "mic": stats([clusters[-1]]),
        "caret_columns_excluded": caret,
    }


def diff(a, b, outside_field):
    ia, ib = read_png(a), read_png(b)
    assert len(ia) == len(ib) and len(ia[0]) == len(ib[0]), "image sizes differ"
    box = None
    if outside_field:
        _, y0, y1, x0, x1 = find_field(ia)
        box = (x0 - 3, y0 - 3, x1 + 3, y1 + 3)
    changed, bounds = 0, None
    for y, (ra, rb) in enumerate(zip(ia, ib)):
        for x, (p, q) in enumerate(zip(ra, rb)):
            if p == q or (box and box[0] <= x < box[2] and box[1] <= y < box[3]):
                continue
            changed += 1
            bounds = [min(bounds[0], x), min(bounds[1], y), max(bounds[2], x + 1), max(bounds[3], y + 1)] if bounds else [x, y, x + 1, y + 1]
    return {"a": str(a), "b": str(b), "excluded_field_xyxy": list(box) if box else None,
            "changed_pixels": changed, "changed_bounds_xyxy": bounds}


def main(argv):
    if argv and argv[0] == "--diff":
        print(json.dumps(diff(argv[1], argv[2], "--outside-field" in argv), indent=2))
        return 0
    report = argv and argv[0] == "--report"
    dirs = argv[1:] if report else argv
    results, failures = {}, []
    for d in dirs:
        pngs = sorted(Path(d).glob("notch-*-open.png"))
        assert pngs, f"{d}: no notch-*-open.png"
        r = measure(pngs[0])
        name = Path(d).name
        results[name] = r
        # A directory named *-focused must show the focused fill, *-unfocused / *-passive the resting fill.
        want = "focused" if name.endswith("-focused") else "resting" if name.endswith(("-unfocused", "-passive")) else None
        if want and r["field_state"] != want:
            failures.append(f"{name}: field is {r['field_state']}, expected {want}")
        if r["placeholder"]["ratio"] < PLACEHOLDER_MIN:
            failures.append(f"{Path(d).name}: placeholder {r['placeholder']['ratio']}:1 < {PLACEHOLDER_MIN}:1")
        for k in ("plus", "mic"):
            if r[k]["ratio"] < CONTROL_MIN:
                failures.append(f"{Path(d).name}: {k} {r[k]['ratio']}:1 < {CONTROL_MIN}:1")
    print(json.dumps({"method": (__doc__ or "").split("Method")[-1].strip(), "results": results, "failures": failures}, indent=2))
    return 1 if failures and not report else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
