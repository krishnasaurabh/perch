#!/usr/bin/env bash
set -euo pipefail
[[ $(uname -s) == Darwin ]] || exit 2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 -m unittest discover -s "$ROOT/scripts" -p test_probe_results.py
OUT=${1:?output directory required}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$ROOT/Tests" "$PROBE/"
cp "$ROOT/scripts/integration_probe.swift" "$PROBE/Sources/Perch/main.swift"
swift build --jobs 2 -Xswiftc -DPERCH_TESTING -Xswiftc -enable-testing --package-path "$PROBE" -c release --product Perch
python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import json, os, pathlib, subprocess, sys
binary, out = sys.argv[1:]
data = pathlib.Path(out) / 'planner.json'
data.write_text(json.dumps({'preferences': {'welcomeCompleted': True, 'catchCopies': False, 'catchScreenshots': False}}))
# Keyboard traversal, OCR, and all page failures execute in this same child.
(pathlib.Path(out) / 'integration-matrix.json').unlink(missing_ok=True)
subprocess.run([binary, '-AppleKeyboardUIMode', '3'], env=dict(os.environ, PERCH_DATA=str(data), INTEGRATION_OUTPUT=out), check=True, timeout=180)
PY
python3 "$ROOT/scripts/check_probe_results.py" integration "$OUT/integration-matrix.json"
# All-page native matrix (Settings panes and their failure paths, Dashboard tabs and keyboard
# actions, Welcome and Details error/history states, Week and Clips keyboard including Escape
# and focus return, effective enlarged type and contrast). Its own package copy and its own
# synthetic planner, so the two probes never share state. Reuses this job's existing step.
bash "$ROOT/scripts/check_allpage_matrix.sh" "$OUT/allpage"

