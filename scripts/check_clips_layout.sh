#!/usr/bin/env bash
# macOS CI only: isolated actual-view snapshots; never changes user clipboard or preferences.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'This UI probe requires macOS.' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: check_clips_layout.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$ROOT/Tests" "$PROBE/"
cp "$ROOT/scripts/clips_layout_probe.swift" "$PROBE/Sources/Perch/App/main.swift"
# Optional before evidence uses the same probe and the exact pre-fix view, never a hand-drawn substitute.
# Export that file to CLIPS_BEFORE_SOURCE to capture it without bringing old history into this branch.
if [[ -n ${CLIPS_BEFORE_SOURCE:-} ]]; then
    cp "$PROBE/Sources/Perch/Workspace/WeekAndClips.swift" "$PROBE/after.swift"
    cp "$CLIPS_BEFORE_SOURCE" "$PROBE/Sources/Perch/Workspace/WeekAndClips.swift"
    swift build --package-path "$PROBE" -c release --product Perch
    python3 "$ROOT/scripts/run_clips_probe.py" "$PROBE/.build/release/Perch" "$OUT/before"
    mv "$PROBE/after.swift" "$PROBE/Sources/Perch/Workspace/WeekAndClips.swift"
fi
swift build --package-path "$PROBE" -c release --product Perch
python3 "$ROOT/scripts/run_clips_probe.py" "$PROBE/.build/release/Perch" "$OUT/after"
python3 "$ROOT/scripts/measure_clips_bounds.py" "$OUT/after"
