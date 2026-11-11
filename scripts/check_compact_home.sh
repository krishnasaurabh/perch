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
    if [[ ! -d "$PROBE/Sources/PerchApp" ]]; then
        cp "$ROOT/Sources/PerchUI/WorkspaceLayout.swift" "$PROBE/Sources/PlannerCore/"
    fi
    export COMPACT_HOME_BASELINE=1
else
    cp "$ROOT/Package.swift" "$PROBE/"
    cp -R "$ROOT/Sources" "$PROBE/"
    cp -R "$ROOT/Tests" "$PROBE/"
fi
if [[ -d "$PROBE/Sources/PerchApp" ]]; then
    APP_SOURCES="$PROBE/Sources/PerchApp"
    ENTRY="$PROBE/Sources/Perch/main.swift"
else
    APP_SOURCES="$PROBE/Sources/Perch"
    ENTRY="$APP_SOURCES/App/main.swift"
fi
cp "$ROOT/scripts/compact_home_probe.swift" "$ENTRY"
swift build -Xswiftc -DPERCH_TESTING -Xswiftc -enable-testing --package-path "$PROBE" -c release --product Perch
python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import json, os, pathlib, subprocess, sys
binary, output = sys.argv[1:]
data = pathlib.Path(output) / 'planner.json'
data.write_text(json.dumps({'preferences': {'welcomeCompleted': True,
                                          'catchCopies': False, 'catchScreenshots': False}}))
env = dict(os.environ, PERCH_DATA=str(data), COMPACT_HOME_OUTPUT=output)
subprocess.run([binary], env=env, check=True, timeout=150)
PY
if [[ -z ${2:-} ]]; then
    # Rebuild the identical real Home with only the cue attachment removed. Compare
    # actual AX bounds, not hand-maintained constants, to prove this overlay is layout-neutral.
    python3 - "$APP_SOURCES/Workspace/TasksCard.swift" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
attachment = '                    .background(TasksContinuationObserver())\n'
assert source.count(attachment) == 1
path.write_text(source.replace(attachment, ''))
PY
    swift build -Xswiftc -DPERCH_TESTING -Xswiftc -enable-testing --package-path "$PROBE" -c release --product Perch
    mkdir -p "$OUT/no-cue"
    COMPACT_HOME_GEOMETRY_ONLY=1 COMPACT_HOME_OUTPUT="$OUT/no-cue" PERCH_DATA="$OUT/no-cue/planner.json" \
        python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import json, os, pathlib, subprocess, sys
binary, output = sys.argv[1:]
pathlib.Path(os.environ['PERCH_DATA']).write_text(json.dumps({'preferences': {'welcomeCompleted': True,
    'catchCopies': False, 'catchScreenshots': False}}))
subprocess.run([binary], env=os.environ, check=True, timeout=100)
root = pathlib.Path(output)
def widths(path):
    return {r['scenario']: r for r in json.loads(path.read_text()) if r['scenario'].startswith('width-')}
actual = widths(root / 'layout-metrics.json')
reference = widths(root / 'no-cue/layout-metrics.json')
expected = {f'width-{w}-{state}' for w in (820, 620) for state in ('resting', 'running')}
assert set(actual) == set(reference) == expected
for name in sorted(expected):
    assert actual[name] == reference[name], (name, actual[name], reference[name])
    print(f'PASS: {name}: capture, Start focus and viewport bounds identical with/without cue')
(root / 'geometry-comparison.json').write_text(json.dumps({'verified': sorted(expected),
    'comparison': 'real AX bounds, identical view with cue attachment removed'}, indent=2))
PY
fi
