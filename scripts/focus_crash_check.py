#!/usr/bin/env python3
"""Focus timer crash recovery, end to end against the real app binary (macOS CI or a real Mac).

  focus_crash_check.py <release-binary> <workdir> [instrumented-snapshot-binary]

1. Launch the app on an empty planner, then start a 30 min timer through `Perch --mcp`.
2. While it runs, check the app's 1 s tick banks a checkpoint every 30 s (timer keeps running).
3. kill -9 the app mid-stretch, wait, relaunch it without diagnostic flags.
4. Banked time must be >= elapsed - 30 s, the offline gap must not count, and the timer must come back paused.
The instrumented binary renders the recovered state separately, after Release checks pass.
Writes <workdir>/focus-crash.json (report) and <workdir>/snap/*.png. Exit 1 on any failed check.
"""
import json, os, signal, subprocess, sys, time
from datetime import datetime, timezone

BIN, WORK = sys.argv[1], sys.argv[2]
SNAPSHOT_BIN = sys.argv[3] if len(sys.argv) > 3 else BIN
os.makedirs(WORK, exist_ok=True)
DATA = os.path.join(WORK, "crash.json")
for p in (DATA, DATA + ".lock"):
    if os.path.exists(p): os.remove(p)
with open(DATA, "w") as f:
    json.dump({"preferences": {"welcomeCompleted": True, "catchCopies": False,
                               "catchScreenshots": False, "remindersSync": False}}, f)
ENV = dict(os.environ, PERCH_DATA=DATA)
KILL_AT = 80      # s after start: 20 s past the 60 s checkpoint, so a real unbanked tail is at stake
OFFLINE = 5       # s the app stays dead; none of it may be credited
report: dict = {"probes": []}
failures = []


def check(ok, msg):
    print(("ok   " if ok else "FAIL ") + msg)
    if not ok: failures.append(msg)


def epoch(s):  # PlannerFile writes 2026-11-09T08:00:00.123456789Z
    base, _, frac = s.rstrip("Z").partition(".")
    t = datetime.strptime(base, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    return t + (float("0." + frac) if frac else 0.0)


def planner():
    with open(DATA) as f: return json.load(f)


def logged(p): return sum(epoch(s["end"]) - epoch(s["start"]) for s in p.get("focusSegments", []))


def sleep_until(t):
    time.sleep(max(0.0, t - time.time()))


def finish():
    with open(os.path.join(WORK, "focus-crash.json"), "w") as f: json.dump(report, f, indent=2)
    print(json.dumps(report, indent=2))
    sys.exit(1 if failures else 0)


app = subprocess.Popen([BIN], env=ENV)
time.sleep(4)  # launch (and its startup recovery pass) happens before the timer exists
check(app.poll() is None, "app is running before the timer starts")

rpc = "\n".join(json.dumps(m) for m in [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "crash-check", "version": "1"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "start_timer", "arguments": {"minutes": 30}}},
]) + "\n"
out = subprocess.run([BIN, "--mcp"], input=rpc, env=ENV, capture_output=True, text=True, timeout=30).stdout
check("Started the timer" in out, "start_timer over MCP: " + out.strip().splitlines()[-1][:160])
p = planner()
t0 = epoch(p["focus"]["startedAt"])
report["startedAt"] = p["focus"]["startedAt"]

# The app's tick (not this script) must bank checkpoints while the timer keeps running.
for at, want in ((40, 30), (70, 60)):
    sleep_until(t0 + at)
    p = planner(); f = p["focus"]
    probe = {"at": round(time.time() - t0, 2), "state": f["state"], "banked": f["banked"], "logged": round(logged(p), 3),
             "segments": len(p.get("focusSegments", []))}
    report["probes"].append(probe)
    check(f["state"] == "running", f"t+{at}s timer still running (got {f['state']})")
    check(f["banked"] >= want, f"t+{at}s tick banked >= {want}s while running (banked {f['banked']:.2f})")
    check(abs(logged(p) - f["banked"]) < 0.01, f"t+{at}s focus log matches banked ({logged(p):.2f} vs {f['banked']:.2f})")

sleep_until(t0 + KILL_AT)
os.kill(app.pid, signal.SIGKILL)
killed = time.time(); app.wait()
elapsed = killed - t0
p = planner()
report.update(elapsed=round(elapsed, 3), bankedAtKill=p["focus"]["banked"], stateAtKill=p["focus"]["state"])
check(p["focus"]["banked"] >= elapsed - 30, f"on disk at kill -9: banked {p['focus']['banked']:.2f}s >= elapsed {elapsed:.2f}s - 30s")

time.sleep(OFFLINE)
snap = os.path.join(WORK, "snap")
app = subprocess.Popen([BIN], env=ENV)
time.sleep(6)
p = planner(); f = p["focus"]
report.update(afterRelaunch={"state": f["state"], "banked": f["banked"], "resumedAt": f.get("resumedAt"), "logged": round(logged(p), 3)})
check(f["state"] == "paused" and f.get("resumedAt") is None, f"relaunch recovered the timer as paused (got {f['state']}, resumedAt {f.get('resumedAt')})")
check(f["banked"] >= elapsed - 30, f"after relaunch: banked {f['banked']:.2f}s >= elapsed {elapsed:.2f}s - 30s")
check(f["banked"] <= elapsed + 0.5, f"after relaunch: offline gap not credited (banked {f['banked']:.2f}s <= elapsed {elapsed:.2f}s)")
check(abs(logged(p) - f["banked"]) < 0.01, f"after relaunch: focus log matches banked ({logged(p):.2f} vs {f['banked']:.2f})")
before = f["banked"]
time.sleep(3)
later = planner()["focus"]
report["afterRelaunch"]["bankedLater"] = later["banked"]
check(later["banked"] == before, f"paused timer stays put on later ticks ({before:.2f} -> {later['banked']:.2f})")
check(later["banked"] <= elapsed + 0.5, f"9 s after relaunch: offline gap still not credited (banked {later['banked']:.2f}s)")
check(app.poll() is None, "relaunched Release app is still running")
app.terminate(); app.wait(timeout=10)
app = subprocess.Popen([SNAPSHOT_BIN, "--snapshot", snap], env=ENV)
time.sleep(6)
check(planner()["focus"] == later, "instrumented render preserves recovered focus state")
pngs = sorted(x for x in os.listdir(snap) if x.endswith(".png")) if os.path.isdir(snap) else []
report["snapshots"] = pngs
check(bool(pngs), f"instrumented app rendered recovered state ({pngs})")
check(app.poll() is None, "instrumented app is still running")
app.terminate(); app.wait(timeout=10)
finish()