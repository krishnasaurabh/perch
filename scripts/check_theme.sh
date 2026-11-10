#!/usr/bin/env bash
# CI-only real SwiftUI rendering, including Insights glyph/series pixel gates in both appearances.
# Never modifies the user's appearance or live planner.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'This UI probe requires macOS.' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: check_theme.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
python3 "$ROOT/scripts/theme_contrast.py"
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$PROBE/"
cp -R "$ROOT/Tests" "$PROBE/"
cp "$ROOT/scripts/theme_probe.swift" "$PROBE/Sources/Perch/App/main.swift"
swift build --package-path "$PROBE" -c release --product Perch
python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import json, os, pathlib, subprocess, sys
binary, output = sys.argv[1:]
data = pathlib.Path(output) / 'planner.json'
data.write_text(json.dumps({'preferences': {'welcomeCompleted': True,
                                          'catchCopies': False, 'catchScreenshots': False}}))
env = dict(os.environ, PERCH_DATA=str(data), THEME_PROBE_OUTPUT=output)
subprocess.run([binary], env=env, check=True, timeout=90)
PY
python3 "$ROOT/scripts/theme_contrast.py" --pixels "$OUT"
