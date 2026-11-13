#!/usr/bin/env bash
# macOS CI only: isolated actual-view snapshots; never changes user clipboard or preferences.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'This UI probe requires macOS.' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 -m unittest discover -s "$ROOT/scripts" -p test_clips_keyboard.py
OUT=${1:?usage: check_clips_layout.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$ROOT/Tests" "$PROBE/"
cp "$ROOT/scripts/clips_layout_probe.swift" "$PROBE/Sources/Perch/main.swift"
# Optional before evidence uses the same probe and the exact pre-fix view, never a hand-drawn substitute.
# Export that file to CLIPS_BEFORE_SOURCE to capture it without bringing old history into this branch.
if [[ -n ${CLIPS_BEFORE_SOURCE:-} ]]; then
    cp "$PROBE/Sources/PerchApp/Workspace/ClipsPage.swift" "$PROBE/after.swift"
    cp "$CLIPS_BEFORE_SOURCE" "$PROBE/Sources/PerchApp/Workspace/ClipsPage.swift"
    swift build --jobs 2 -Xswiftc -DPERCH_TESTING -Xswiftc -enable-testing --package-path "$PROBE" -c release --product Perch
    python3 "$ROOT/scripts/run_clips_probe.py" "$PROBE/.build/release/Perch" "$OUT/before"
    mv "$PROBE/after.swift" "$PROBE/Sources/PerchApp/Workspace/ClipsPage.swift"
fi
# The old view has no ClipPreview type; enable the new pixel regressions only for the exact-head view.
swift build --jobs 2 -Xswiftc -DPERCH_TESTING -Xswiftc -enable-testing --package-path "$PROBE" -c release --product Perch -Xswiftc -DCLIPS_PREVIEW_REGRESSION
python3 "$ROOT/scripts/run_clips_probe.py" "$PROBE/.build/release/Perch" "$OUT/after"
python3 "$ROOT/scripts/check_probe_results.py" clips "$OUT/after/clips-keyboard.json"
python3 "$ROOT/scripts/measure_clips_bounds.py" "$OUT/after"
