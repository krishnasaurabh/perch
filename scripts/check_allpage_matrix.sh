#!/usr/bin/env bash
# macOS CI only: renders the real Settings, Dashboard, Welcome, Week, Clips and Details
# surfaces and drives them with real key events. Never writes the user's planner, clipboard,
# keyboard preferences or TCC state: PERCH_DATA is synthetic and the probe stays unbundled.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'This UI probe requires macOS.' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: check_allpage_matrix.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$ROOT/Tests" "$PROBE/"
cp "$ROOT/scripts/allpage_matrix_probe.swift" "$PROBE/Sources/Perch/main.swift"
swift build -Xswiftc -DPERCH_TESTING -Xswiftc -enable-testing --package-path "$PROBE" -c release --product Perch
python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import json, os, pathlib, subprocess, sys
binary, out = sys.argv[1:]
data = pathlib.Path(out) / 'planner.json'
data.write_text(json.dumps({'preferences': {
    'welcomeCompleted': True, 'catchCopies': False, 'catchScreenshots': False, 'remindersSync': False}}))
subprocess.run([binary], env=dict(os.environ, PERCH_DATA=str(data), MATRIX_OUTPUT=out),
               check=True, timeout=600)
PY
