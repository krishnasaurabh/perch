#!/usr/bin/env bash
# macOS only. Build an isolated entry point against the real app sources, render the Today capture field
# resting/focused (empty and three tasks) plus Week, then measure rendered prompt and icon contrast (review F02).
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
cp "$ROOT/scripts/capture_contrast_probe.swift" "$PROBE/Sources/Perch/App/main.swift"
swift build --package-path "$PROBE" -c release --product Perch
python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import json, os, pathlib, subprocess, sys
binary, output = sys.argv[1:]
data = pathlib.Path(output) / 'planner.json'
data.write_text(json.dumps({'preferences': {'welcomeCompleted': True,
                                          'catchCopies': False, 'catchScreenshots': False}}))
env = dict(os.environ, PERCH_DATA=str(data), CAPTURE_CONTRAST_OUTPUT=output)
subprocess.run([binary], env=env, check=True, timeout=60)
PY
python3 "$ROOT/scripts/measure_capture_contrast.py" \
  "$OUT/empty-home-unfocused" "$OUT/empty-home-focused" "$OUT/three-home-unfocused" "$OUT/three-home-focused" \
  | tee "$OUT/contrast.json"
