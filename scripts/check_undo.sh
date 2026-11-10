#!/usr/bin/env bash
set -euo pipefail
[[ $(uname -s) == Darwin ]] || exit 2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?output directory required}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$ROOT/Tests" "$PROBE/"
cp "$ROOT/scripts/undo_probe.swift" "$PROBE/Sources/Perch/main.swift"
swift build -Xswiftc -enable-testing --package-path "$PROBE" -j 2 -c release --product Perch
python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import os, pathlib, subprocess, sys, tempfile
binary, output = sys.argv[1:]
data = pathlib.Path(tempfile.mkdtemp(prefix='data-', dir=output)) / 'planner.json'
subprocess.run([binary], env=dict(os.environ, PERCH_DATA=str(data)), check=True, timeout=60)
PY
