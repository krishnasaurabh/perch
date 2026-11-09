#!/usr/bin/env bash
# homecards_shots.sh <out-dir>: deterministic Home side-card snapshots (macOS CI, after scripts/bundle.sh).
# Seeds a planner through the app's own --mcp, then pins the focus session to a PAUSED state with a fixed
# banked time, so the face shows an exact value: limit 45:00, banked 754 s -> "32:26" remaining.
#   timer-default    no workspaceTimerStyle key, so the shipped default face renders
#   timer-dotmatrix  the opt-in dot-matrix face, same value
#   notepad-heavy    notepad shown beside the timer, with more lines than fit (bottom edge fades)
#   notepad-fits     the same card with three short lines (no fade: every line at full ink)
# Each shot writes <out>/<name>/notch-*.png (in-process --snapshot) and <out>/<name>-screen.png (screencapture).
# The seed avoids clock times on purpose: "at 2pm" run after 2pm (hosted runners are UTC) moves the task to
# tomorrow, start_timer then finds nothing today, and the shots silently render an empty planner.
set -euo pipefail
OUT=${1:?usage: homecards_shots.sh OUTPUT_DIRECTORY}; mkdir -p "$OUT"
APP=dist/Perch.app/Contents/MacOS/Perch
SRC="$OUT/seed.json"; rm -f "$SRC"

python3 - > "$OUT/seed.jsonl" <<'EOF'
import json
lines = []
for i in range(1, 7):
    lines += [f"{i}. Idea: block Friday afternoons to look back on the week",
              "Check the rate limits with Sam ahead of launch",
              "Groceries: rice, dal, paneer, coriander, curd, onions",
              "Book flights for Dec 15 trip"]
calls = [["add_tasks", {"titles": ["Prep slides for the review !high #work", "Call mom", "Buy flowers"]}],
         ["start_timer", {"task": "Prep slides", "minutes": 45}],
         ["pause_timer", {}],
         ["write_notepad", {"mode": "replace", "text": "\n".join(lines)}]]
msgs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize",
         "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "ci", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"}]
for i, (tool, args) in enumerate(calls, 1):
    msgs.append({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": tool, "arguments": args}})
print("\n".join(json.dumps(m) for m in msgs))
EOF
PERCH_DATA="$SRC" "$APP" --mcp < "$OUT/seed.jsonl" > "$OUT/seed.log" 2>&1
# Every seeding call must succeed; otherwise the snapshots prove nothing.
python3 - "$OUT/seed.log" <<'EOF'
import json, sys
seen = set()
for line in open(sys.argv[1]):
    try: m = json.loads(line)
    except ValueError: continue
    if m.get("id", 0) > 0:
        seen.add(m["id"])
        r = m.get("result") or {}
        if "error" in m or r.get("isError"):
            sys.exit(f"seed call {m['id']} failed: {json.dumps(m)[:300]}")
if seen != {1, 2, 3, 4}: sys.exit(f"seed replies missing: got ids {sorted(seen)}")
print("seed: 4/4 calls ok")
EOF

variant() {  # variant <name> <python expression editing p>
  python3 - "$SRC" "$OUT/$1.json" "$2" <<'EOF'
import json, sys
src, dst, edit = sys.argv[1:]
p = json.load(open(src))
f = p["focus"]; assert f["state"] == "paused", f
f["banked"] = 754.0; f["limit"] = 2700.0          # 2700 - 754 = 1946 s -> "32:26"
prefs = p.setdefault("preferences", {}); prefs["welcomeCompleted"] = True
prefs.pop("workspaceTimerStyle", None)             # absent key = the decoder's default face
exec(edit)
json.dump(p, open(dst, "w"))
print(dst, "style:", prefs.get("workspaceTimerStyle", "<default>"), "hidden:", prefs.get("hiddenWorkspaceCards"),
      "notepad lines:", sum(n["text"].count("\n") + 1 for n in p.get("notes", [])))
EOF
}
variant timer-default "pass"
variant timer-dotmatrix "prefs['workspaceTimerStyle'] = 'dotMatrix'"
variant notepad-heavy "prefs['hiddenWorkspaceCards'] = []"
variant notepad-fits "prefs['hiddenWorkspaceCards'] = []; p['notes'][0]['text'] = 'Call the dentist\\nPick up dry cleaning\\nDraft the review notes'"

for name in timer-default timer-dotmatrix notepad-heavy notepad-fits; do
  dir="$OUT/$name"; rm -rf "$dir"; mkdir -p "$dir"
  PERCH_DATA="$OUT/$name.json" "$APP" --preview-open --page home --snapshot "$dir" > "$OUT/$name.log" 2>&1 &
  pid=$!; sleep 6
  screencapture -x "$OUT/$name-screen.png" || true
  kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
  ls "$dir"/*.png || { echo "no snapshot for $name"; exit 1; }
done
