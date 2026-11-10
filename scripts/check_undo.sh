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
cp "$ROOT/scripts/undo_probe.swift" "$PROBE/Sources/Perch/App/main.swift"
swift build --package-path "$PROBE" -j 2 -c release --product Perch
PERCH_DATA="$OUT/planner.json" "$PROBE/.build/release/Perch"
