#!/usr/bin/env bash
# In-process macOS policy/transaction regression probe, not presentation-layer video evidence.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'This UI probe requires macOS.' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: check_motion.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
# Guard the exact production wiring, including removal of every idle blink scheduler.
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
theme = (root / 'Sources/Perch/Workspace/Theme.swift').read_text()
owl = theme.split('struct OwlMark: View {', 1)[1].split('struct Triangle:', 1)[0]
for forbidden in ['@State', '.task', 'withAnimation', 'Task.sleep', 'Timer', 'repeatForever']:
    assert forbidden not in owl, f'Owl regained autonomous motion: {forbidden}'
notch = (root / 'Sources/Perch/Notch/NotchRootView.swift').read_text()
assert '.transition(motionPolicy.workspaceTransition)' in notch
assert '.motionBoundary()' in notch
chart = (root / 'Sources/Perch/Workspace/InsightsPage.swift').read_text()
assert '.animation(Self.growth(series, index: i, policy: policy)' in chart
assert 'return policy.animation(Motion.bar.delay' in chart
print('PASS: root policy wiring, no owl scheduler, chart reduced animation remains nil')
PY
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$PROBE/"
cp -R "$ROOT/Tests" "$PROBE/"
cp "$ROOT/scripts/motion_probe.swift" "$PROBE/Sources/Perch/App/main.swift"
swift build --package-path "$PROBE" -c release --product Perch
python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import json, os, pathlib, subprocess, sys
binary, output = sys.argv[1:]
data = pathlib.Path(output) / 'planner.json'
data.write_text(json.dumps({'preferences': {'welcomeCompleted': True,
                                          'catchCopies': False, 'catchScreenshots': False}}))
env = dict(os.environ, PERCH_DATA=str(data), MOTION_PROBE_OUTPUT=output)
subprocess.run([binary], env=env, check=True, timeout=60)
PY
