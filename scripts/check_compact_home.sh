#!/usr/bin/env bash
# macOS only, isolated planner and temporary entry point; never changes the installed app.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'This UI probe requires macOS.' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: check_compact_home.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
if [[ -n ${2:-} ]]; then
    # Exact public baseline, capture-only. The helper is linked only for probe compilation;
    # baseline NotchGeometry/TasksCard remain unchanged and still use their old 470pt layout.
    git -C "$ROOT" archive "$2" Package.swift Sources Tests | tar -x -C "$PROBE"
    cp "$ROOT/Sources/PlannerCore/WorkspaceLayout.swift" "$PROBE/Sources/PlannerCore/"
    export COMPACT_HOME_BASELINE=1
else
    cp "$ROOT/Package.swift" "$PROBE/"
    cp -R "$ROOT/Sources" "$PROBE/"
    cp -R "$ROOT/Tests" "$PROBE/"
fi
cp "$ROOT/scripts/compact_home_probe.swift" "$PROBE/Sources/Perch/App/main.swift"
swift build --package-path "$PROBE" -c release --product Perch
python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import json, os, pathlib, subprocess, sys
binary, output = sys.argv[1:]
data = pathlib.Path(output) / 'planner.json'
data.write_text(json.dumps({'preferences': {'welcomeCompleted': True,
                                          'catchCopies': False, 'catchScreenshots': False}}))
env = dict(os.environ, PERCH_DATA=str(data), COMPACT_HOME_OUTPUT=output)
subprocess.run([binary], env=env, check=True, timeout=60)
PY
