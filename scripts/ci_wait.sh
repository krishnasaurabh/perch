#!/usr/bin/env bash
# ci_wait.sh <branch>  -> waits for the newest CI run on <branch>, prints job/step results, downloads artifacts.
set -uo pipefail
BR="${1:?branch}"; REPO=krishnasaurabh/perch
T=$(python3 -c "
from urllib.parse import urlparse
for l in open('$HOME/.git-credentials'):
    u=urlparse(l.strip())
    if u.hostname and 'github.com' in u.hostname: print(u.password);break")
api(){ curl -s -H "Authorization: Bearer $T" "https://api.github.com/repos/$REPO/$1"; }
sleep 10
RID=$(api "actions/runs?branch=$BR&per_page=1" | python3 -c "import sys,json;r=json.load(sys.stdin)['workflow_runs'];print(r[0]['id'] if r else '')")
[ -z "$RID" ] && { echo "no run for $BR"; exit 2; }
echo "run: https://github.com/$REPO/actions/runs/$RID"
for i in $(seq 1 60); do
  ST=$(api "actions/runs/$RID" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])")
  [ "$ST" = completed ] && break; sleep 15; done
api "actions/runs/$RID/jobs" | python3 -c "
import sys,json
for j in json.load(sys.stdin)['jobs']:
    print(j['name'], '->', j['conclusion'])
    for s in j['steps']:
        if s['conclusion'] not in ('success','skipped',None): print('   FAILED:', s['name'], '(job', j['id'], ')')"
OUT="${TMPDIR:-/tmp}/ci-${BR//\//-}"; rm -rf "$OUT"; mkdir -p "$OUT"
for u in $(api "actions/runs/$RID/artifacts" | python3 -c "import sys,json;[print(a['archive_download_url']) for a in json.load(sys.stdin)['artifacts']]"); do
  curl -sL -H "Authorization: Bearer $T" -o "$OUT/a.zip" "$u" && (cd "$OUT" && unzip -oq a.zip && rm a.zip); done
echo "artifacts: $OUT"; find "$OUT" -name '*.png' -o -name '*.dmg' 2>/dev/null
echo "failed-job logs: curl -sL -H 'Authorization: Bearer <token>' https://api.github.com/repos/$REPO/actions/jobs/<job>/logs"
