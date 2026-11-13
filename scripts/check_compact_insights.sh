#!/usr/bin/env bash
# macOS only, isolated planner and temporary entry point; never changes the installed app.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'This UI probe requires macOS.' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: check_compact_insights.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$PROBE/"
cp -R "$ROOT/Tests" "$PROBE/"
if [[ -d "$PROBE/Sources/PerchApp" ]]; then
    ENTRY="$PROBE/Sources/Perch/main.swift"
else
    ENTRY="$PROBE/Sources/Perch/App/main.swift"
fi
mkdir -p "$(dirname "$ENTRY")"
cp "$ROOT/scripts/compact_insights_probe.swift" "$ENTRY"
swift build -Xswiftc -DPERCH_TESTING -Xswiftc -enable-testing --package-path "$PROBE" -c release --product Perch
python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import json, os, pathlib, subprocess, sys
binary, output = sys.argv[1:]
data = pathlib.Path(output) / 'planner.json'
data.write_text(json.dumps({'preferences': {'welcomeCompleted': True,
                                           'catchCopies': False, 'catchScreenshots': False}}))
env = dict(os.environ, PERCH_DATA=str(data), COMPACT_INSIGHTS_OUTPUT=output)
subprocess.run([binary], env=env, check=True, timeout=300)
PY
python3 "$ROOT/scripts/measure_compact_insights.py" "$OUT"
