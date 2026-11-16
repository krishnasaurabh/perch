#!/usr/bin/env bash
# macOS CI only: isolated actual-view snapshots; never changes user clipboard or preferences.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'This UI probe requires macOS.' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 -m unittest discover -s "$ROOT/scripts" -p test_clips_keyboard.py
OUT=${1:?usage: check_clips_layout.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$ROOT/Tests" "$PROBE/"
cp "$ROOT/scripts/clips_layout_probe.swift" "$PROBE/Sources/Perch/main.swift"
# Build the actual shelf plus the preserved Week and new shelf keyboard matrix.
swift build --jobs 2 -Xswiftc -DPERCH_TESTING -Xswiftc -enable-testing --package-path "$PROBE" -c release --product Perch -Xswiftc -DCLIPS_PREVIEW_REGRESSION
python3 "$ROOT/scripts/run_clips_probe.py" "$PROBE/.build/release/Perch" "$OUT/after"
python3 "$ROOT/scripts/check_probe_results.py" clips "$OUT/after/clips-keyboard.json"
python3 "$ROOT/scripts/measure_clips_bounds.py" "$OUT/after"
