#!/usr/bin/env bash
# week_shots.sh <out-dir>: macOS CI, after scripts/bundle.sh. Snapshots the Week page with a busy today
# (12 tasks seeded through the app's own MCP server, one repeating, two done) so the overflow fade,
# the "+N more" line and the pinned Add field are visible. Also writes the seeded planner for inspection.
set -u
OUT=${1:?usage: week_shots.sh OUTPUT_DIRECTORY}; mkdir -p "$OUT"
APP=dist/Perch.app/Contents/MacOS/Perch
DATA="$OUT/week-heavy.json"; rm -f "$DATA"
python3 - <<'EOF' | PERCH_DATA="$DATA" "$APP" --mcp > "$OUT/week-seed.log" 2>&1
import json
today = ["Outline the onboarding guide for new contributors covering setup, testing and the release checklist #work",
         "Refill the bird feeder every 3 days", "Text Sam about Saturday at 4pm", "Pay the water bill !high",
         "Return library books", "Phone the landlord at 6pm", "Buy a USB-C charger", "Prep 1:1 agenda",
         "Update insurance card !high", "Read chapter 6 for book club", "Schedule car service",
         "Fix flaky FocusSession test"]
calls = [("add_tasks", {"titles": today}), ("complete_task", {"task": "Buy a USB-C charger"}),
         ("complete_task", {"task": "Return library books"}),
         ("add_tasks", {"titles": ["Ship v1.1", "Standup notes"], "date": "tomorrow"})]
msgs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize",
         "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "ci", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"}]
msgs += [{"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": n, "arguments": a}} for i, (n, a) in enumerate(calls, 1)]
print("\n".join(json.dumps(m) for m in msgs))
EOF
python3 - "$DATA" <<'EOF'
import json, sys, datetime
p = json.load(open(sys.argv[1])); p.setdefault("preferences", {})["welcomeCompleted"] = True
json.dump(p, open(sys.argv[1], "w"))
today = datetime.date.today().isoformat()
on = [t for t in p["tasks"] if t.get("day") == today]
print(f"seeded {len(p['tasks'])} tasks, {len(on)} today, {sum(bool(t.get('repeatRule')) for t in on)} repeating")
assert len(on) >= 10, "need at least 10 tasks today"
EOF
[ $? -eq 0 ] || exit 1
SNAP="$OUT/week-heavy"; rm -rf "$SNAP"; mkdir -p "$SNAP"
PERCH_DATA="$DATA" "$APP" --preview-open --page week --snapshot "$SNAP" > "$OUT/week-heavy.log" 2>&1 &
PID=$!; sleep 6
screencapture -x "$OUT/week-heavy-screen.png" || true
kill $PID 2>/dev/null; wait $PID 2>/dev/null
ls "$SNAP"/*.png || { echo "no Week snapshot"; exit 1; }
