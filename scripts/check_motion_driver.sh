#!/usr/bin/env bash
# Negative control uses the real app/AX tree. A missing Start focus cannot start a model timer.
set -euo pipefail
BIN=${1:?Perch binary}; OUT=${2:?output directory}
mkdir -p "$OUT"
PERCH_DATA="$OUT/negative-planner.json" PERCH_CANDIDATE_SHA="$GITHUB_SHA" \
PERCH_MOTION_AX_WAKE=inproc PERCH_MOTION_MISSING_CONTROL='Start focus' \
"$BIN" --motion-script "$OUT/markers.json" --motion-policy normal
python3 - "$OUT/markers.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); m={x['name']:x for x in j['markers']}
assert m['timer']['via']=='FAILED:missing-control:Start focus'
assert m['timer']['interaction_ok'] is False
assert m['timer']['settled_state']['timer_present'] is False
assert m['page']['via']=='ax-press:Week'
assert m['tick']['via']=='ax-press:Check off task'
assert m['timer']['policy']['resolved_reduce_motion'] is False
assert m['timer']['policy']['explicit_reduce_motion'] is False
print('PASS: real-driver missing-control negative; no timer model fallback')
PY
