#!/usr/bin/env bash
# Own-process macOS UI test. Isolated planner; never drives an installed app.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'This UI probe requires macOS.' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: check_focus_entry.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$PROBE/"
cp -R "$ROOT/Tests" "$PROBE/"
cp "$ROOT/scripts/focus_entry_probe.swift" "$PROBE/Sources/Perch/main.swift"
git -C "$ROOT" rev-parse HEAD > "$OUT/source-sha.txt"
swift build -Xswiftc -DPERCH_TESTING -Xswiftc -enable-testing --package-path "$PROBE" -c release --product Perch
python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import json, os, pathlib, subprocess, sys
binary, output = sys.argv[1:]
data = pathlib.Path(output) / 'planner.json'
data.write_text(json.dumps({'preferences': {'welcomeCompleted': True,
    'catchCopies': False, 'catchScreenshots': False, 'defaultFocusMinutes': 25}}))
env = dict(os.environ, PERCH_DATA=str(data), FOCUS_ENTRY_OUTPUT=output)
subprocess.run([binary], env=env, check=True, timeout=150)
result = json.loads((pathlib.Path(output) / 'results.json').read_text())
assert result['activation'] == 'real-own-process-AX-press-no-model-fallback'
assert {row['defaultMinutes'] for row in result['metrics']} == {25, 40}
# Persisted final state must come from the existing real task button, not the entry fixture.
saved = json.loads(data.read_text())
assert saved['focus']['state'] == 'running' and saved['focus']['limit'] == 720
assert saved['focus']['taskID'] == saved['tasks'][0]['id'] and saved['tasks'][0]['minutes'] == 12
print(json.dumps(result, indent=2))
print('PASS: persisted task identity, estimate, and UI-started session agree')
PY
