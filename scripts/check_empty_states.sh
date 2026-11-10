#!/usr/bin/env bash
# macOS only. Build an isolated entry point against the real app sources, then exercise capture.
# Does not modify the app, the user's planner, preferences, or clipboard.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'This UI probe requires macOS.' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: check_empty_states.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$PROBE/"
cp -R "$ROOT/Tests" "$PROBE/"
cp "$ROOT/scripts/empty_states_probe.swift" "$PROBE/Sources/Perch/main.swift"
swift build -Xswiftc -enable-testing --package-path "$PROBE" -c release --product Perch
# The small watchdog makes a missing run loop / focus callback a failure rather than a stuck CI job.
python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import json, os, pathlib, subprocess, sys
binary, output = sys.argv[1:]
data = pathlib.Path(output) / 'planner.json'
data.write_text(json.dumps({'preferences': {'welcomeCompleted': True,
                                          'catchCopies': False, 'catchScreenshots': False}}))
env = dict(os.environ, PERCH_DATA=str(data), EMPTY_STATES_OUTPUT=output)
subprocess.run([binary], env=env, check=True, timeout=45)
PY
