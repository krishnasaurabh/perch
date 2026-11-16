"""Gate drop-shelf captures and keyboard coverage, never native execution itself."""
from collections import Counter
import json
from pathlib import Path
import sys

SHELF_KEYBOARD_ASSERTIONS = (
    "week: Tab reaches the task-line actions menu",
    "week: Space opens the native task-line menu",
    "week: Escape closes the task-line menu",
    "week: focus returns to the task-line menu after Escape",
    "week: cancelling the task-line menu never mutates the task",
    "week: arrow keys and Return choose Details and attach the sheet",
    "week: nested Escape dismisses the details sheet",
    "week: focus returns to the task-line menu after the sheet closes",
    "week: cancelling the details sheet never mutates the task",
    "clips: Tab reaches the clip copy control",
    "clips: Space copies the clip once into the fake pasteboard",
    "clips: focus stays on the copy control after Space",
    "clips: Tab reaches Clear on the shelf",
    "clips: Space clears the shelf as one batch",
    "clips: Tab reaches shelf Undo",
    "clips: Space Undo restores persisted shelf identities and order",
    "clips: Tab returns to the shelf item",
    "clips: Delete removes only the focused shelf item",
    "clips: Return opens the kept file without changing its original",
)
FIXTURES = ("week fixture", "week fixture", "clips fixture", "clips fixture")


def validate_shelf_keyboard(report):
    if not isinstance(report, dict) or report.get("surface") != "drop-shelf":
        raise ValueError("missing shelf keyboard report")
    runs = report.get("runs")
    if not isinstance(runs, list) or not runs:
        raise ValueError("missing shelf keyboard runs")
    originals = [run for run in runs if run.get("broken") == ""]
    if len(originals) != 1:
        raise ValueError("exactly one unbroken shelf keyboard run is required")
    expected = Counter(SHELF_KEYBOARD_ASSERTIONS + FIXTURES)
    original = originals[0]
    if (original.get("ok") is not True or original.get("red") != ""
            or not isinstance(original.get("passed"), list)
            or Counter(original["passed"]) != expected):
        raise ValueError("shelf keyboard interactions are missing, duplicate, unexpected or red")
    for run in runs:
        if run.get("ok") is not True:
            raise ValueError("a shelf keyboard control failed")
        if run.get("broken") and (run["broken"] not in SHELF_KEYBOARD_ASSERTIONS or run.get("red") != run["broken"]):
            raise ValueError("shelf negative control did not fail its own assertion")
    return len(SHELF_KEYBOARD_ASSERTIONS)


def measure(folder):
    # Manifest validation is also used on runners without image dependencies.
    from PIL import Image

    folder = Path(folder)
    records = json.loads((folder / "captures.json").read_text())
    expected = {(appearance, width, state) for appearance in ("light", "dark")
                for width in (400, 640) for state in ("empty", "one", "populated", "cleared")}
    observed = [(r["appearance"], r["stripWidth"], r["state"]) for r in records]
    assert len(observed) == len(expected) and set(observed) == expected, "missing or duplicate shelf states"
    assert len({r["file"] for r in records}) == len(records), "duplicate capture paths"
    results = []
    for record in records:
        image = Image.open(folder / record["file"]).convert("RGBA")
        sx, sy = image.width / record["width"], image.height / record["height"]
        assert sx == sy and sx in (1, 2), "fixture scale differs on x/y or is unsupported"
        left, top, right, bottom = [round(n * sx) for n in record["card"]]
        assert 0 < left < right < image.width and 0 < top < bottom < image.height, "card must be bounded"
        assert abs((right - left) / sx - record["stripWidth"]) <= 1, "wrong strip width"
        rgb = Image.new("RGBA", image.size, (0, 0, 0, 255))
        rgb.alpha_composite(image)
        rgb = rgb.convert("RGB")
        regions = [(0, 0, left, image.height), (right, 0, image.width, image.height),
                   (left, 0, right, top), (left, bottom, right, image.height)]
        outside = sum(max(pixel) > 8 for box in regions for pixel in rgb.crop(box).getdata())
        ink = (0x5E, 0x45, 0x3A) if record["appearance"] == "light" else (0xD2, 0xC4, 0xB7)
        primary = (0x2A, 0x1B, 0x14) if record["appearance"] == "light" else (0xF6, 0xED, 0xE4)
        def count(box, color):
            return sum(max(abs(p[i] - color[i]) for i in range(3)) <= 8
                       for p in rgb.crop(box).getdata())
        slot = [round(n * sx) for n in record["slot"]]
        assert left <= slot[0] < slot[2] <= right and top <= slot[1] < slot[3] <= bottom, "slot outside shelf"
        slot_ink = count(slot, ink)
        header = (left, top, right, min(bottom, top + round(50 * sx)))
        title_ink = count(header, primary)
        results.append(dict(file=record["file"], exterior_painted_pixels=outside,
                            drop_slot_ink_pixels=slot_ink, title_ink_pixels=title_ink, scale=sx))
    return results


def main():
    folder = Path(sys.argv[1])
    results = measure(folder)
    (folder / "pixel-check.json").write_text(json.dumps(results, indent=2) + "\n")
    failures = [r for r in results if r["exterior_painted_pixels"]
                or not r["drop_slot_ink_pixels"] or not r["title_ink_pixels"]]
    print(json.dumps({"snapshots": len(results), "failures": failures}, indent=2))
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
