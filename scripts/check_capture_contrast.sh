#!/usr/bin/env bash
# macOS only. Build an isolated entry point against the real app sources, render the Today capture field
# resting/focused (empty and three tasks) plus Week, then measure rendered prompt and icon contrast (review F02).
# Week's collapsed Add footer prompts are captured and gated in both appearances.
# Does not modify the app, the user's planner, preferences, or clipboard.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'This UI probe requires macOS.' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: check_capture_contrast.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$PROBE/"
cp -R "$ROOT/Tests" "$PROBE/"
# Keep geometry-only backgrounds outside production. Their native frames select
# the actual collapsed footer band; no bitmap baseline or guessed pixel ROI.
python3 - "$PROBE" "$ROOT/scripts/capture_contrast_probe.swift" <<'PY'
from pathlib import Path
import sys
root, probe = Path(sys.argv[1]), Path(sys.argv[2]).read_text()
start = probe.index('// BEGIN WEEK FOOTER MEASUREMENT')
end = probe.index('// END WEEK FOOTER MEASUREMENT') + len('// END WEEK FOOTER MEASUREMENT')
(root / 'Sources/PerchApp/Workspace/WeekFooterMeasure.swift').write_text(
    'import AppKit\nimport SwiftUI\n' + probe[start:end])
(root / 'Sources/Perch/main.swift').write_text(probe[:start] + probe[end:])
week = root / 'Sources/PerchApp/Workspace/WeekPage.swift'
source = week.read_text()
hook = r'.accessibilityIdentifier("week-add-\(day.raw)")'
assert source.count(hook) == 1, 'Week Add footer measurement hook changed'
week.write_text(source.replace(hook, hook + '\n                            .background(WeekFooterMeasure(day: day.raw))'))
PY
swift build -Xswiftc -DPERCH_TESTING -Xswiftc -enable-testing --package-path "$PROBE" -c release --product Perch
python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import json, os, pathlib, subprocess, sys
binary, output = sys.argv[1:]
data = pathlib.Path(output) / 'planner.json'
data.write_text(json.dumps({'preferences': {'welcomeCompleted': True,
                                          'catchCopies': False, 'catchScreenshots': False}}))
env = dict(os.environ, PERCH_DATA=str(data), CAPTURE_CONTRAST_OUTPUT=output)
subprocess.run([binary], env=env, check=True, timeout=60)
PY
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$ROOT/scripts" -p test_measure_capture_contrast.py
python3 "$ROOT/scripts/measure_capture_contrast.py" \
  "$OUT/empty-home-unfocused" "$OUT/empty-home-focused" "$OUT/three-home-unfocused" "$OUT/three-home-focused" \
  --week-board --week-dark "$OUT/week" --week-light "$OUT/week-light" \
  | tee "$OUT/contrast.json"
