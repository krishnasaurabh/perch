#!/usr/bin/env bash
# motion_capture.sh <out-dir> [path/to/Perch.app]
#
# Records real on-screen Perch motion for five transitions (open, close, page, tick, timer) on macOS:
#   1. `screencapture -V` records the whole screen while `Perch --motion-script` drives the transitions
#      through the app's own entry points (Sources/Perch/App/MotionScript.swift).
#   2. If the screen can't be recorded, it tries ffmpeg avfoundation, and always runs a second, separately
#      labelled pass of in-process own-window renders every 16 ms (`--motion-snapshots`), never mixed with (1).
#   3. Per clip: clip.mp4, frames/*.png, sheet.png (contact sheet), frames.json (timestamps + frame diffs).
#      Summary in summary.json / summary.md.
#
# POSTPROCESS_ONLY=1 motion_capture.sh <out-dir>  re-runs step 3 on an existing out-dir (works on Linux too).
#
# Exit 0 = the driver fired every transition. summary.md's first line says whether motion frames were
# RECORDED or are UNVERIFIED (no recorder/ffmpeg on this host). Exit 3 = driver wiring broken.
set -uo pipefail
OUT="${1:?out dir}"; APP="${2:-dist/Perch.app}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
LOG="$OUT/capture.log"; : >"$LOG"
log() { echo "[motion] $*" | tee -a "$LOG"; }

need_ffmpeg() {
  command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null && return 0
  if command -v brew >/dev/null; then
    log "installing ffmpeg via Homebrew (post-processing only)"
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 brew install --quiet ffmpeg >>"$LOG" 2>&1
  fi
  command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null
}

# SwiftUI only builds a macOS app's accessibility tree once an AX client talks to it, so on a VM with no
# VoiceOver the driver's in-process button presses find nothing. Once the driver writes its "reopen" marker,
# act as that client: System Events (osascript has the Accessibility grant on GitHub's macOS images) sets
# AXManualAccessibility on Perch and counts its windows' elements (AXEnhancedUserInterface is left alone:
# it changes how apps animate). Output -> ax-wake.txt.
ax_wake() {
  local MK="$1" LOGF="$2"
  case "${PERCH_MOTION_AX_WAKE:-both}" in external|both) ;; *) echo "skipped (PERCH_MOTION_AX_WAKE=${PERCH_MOTION_AX_WAKE:-})" >"$LOGF"; return 0 ;; esac
  for _ in $(seq 1 80); do grep -q '"reopen"' "$MK" 2>/dev/null && break; sleep 0.1; done
  { echo "reopen seen: $(python3 -c 'import time;print(repr(time.time()))')"
    # No coreutils `timeout` on stock macOS: a watchdog kills osascript after 8 s.
    osascript - >"$LOGF.osa" 2>&1 <<'OSA' &
tell application "System Events"
  set out to {}
  tell process "Perch"
    try
      set value of attribute "AXManualAccessibility" to true
      set end of out to "AXManualAccessibility=set"
    on error e
      set end of out to "AXManualAccessibility error: " & e
    end try
    try
      set end of out to "windows=" & (count of windows)
      set end of out to "top-level elements=" & (count of UI elements of window 1)
    on error e
      set end of out to "walk error: " & e
    end try
  end tell
  set AppleScript's text item delimiters to linefeed
  return out as text
end tell
OSA
    local O=$!; ( sleep 8; kill $O 2>/dev/null ) & local WD=$!
    wait $O; local ORC=$?; kill $WD 2>/dev/null; cat "$LOGF.osa"; rm -f "$LOGF.osa"
    echo "osascript exit=$ORC at $(python3 -c 'import time;print(repr(time.time()))')"; } >"$LOGF"
}

record() {
  local BIN="$APP/Contents/MacOS/Perch"
  [ -x "$BIN" ] || { log "no app binary at $BIN"; return 1; }
  local DATA="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/motion-planner.json"

  # Pass 1: real screen recording (compositor output, includes the menu bar and desktop).
  rm -f "$DATA" "$OUT/screen.mov"
  python3 -c 'import time;print(repr(time.time()))' >"$OUT/record_start_epoch.txt"
  screencapture -x -V 24 "$OUT/screen.mov" >>"$LOG" 2>&1 &
  local SC=$!
  sleep 2
  PERCH_MOTION_AX_WAKE="${PERCH_MOTION_AX_WAKE:-both}" PERCH_DATA="$DATA" "$BIN" --motion-script "$OUT/markers.json" >>"$LOG" 2>&1 &
  local P=$!
  ax_wake "$OUT/markers.json" "$OUT/ax-wake.txt" &
  for _ in $(seq 1 40); do kill -0 $P 2>/dev/null || break; sleep 0.5; done
  kill $P 2>/dev/null
  wait $SC; local RC=$?
  log "screencapture exit=$RC size=$(stat -f%z "$OUT/screen.mov" 2>/dev/null || echo none)"
  if [ ! -s "$OUT/screen.mov" ] && command -v ffmpeg >/dev/null; then
    log "screencapture produced no video; trying ffmpeg avfoundation"
    ffmpeg -hide_banner -f avfoundation -list_devices true -i "" >>"$LOG" 2>&1
    rm -f "$DATA"
    python3 -c 'import time;print(repr(time.time()))' >"$OUT/record_start_epoch.txt"
    ffmpeg -hide_banner -y -f avfoundation -framerate 60 -capture_cursor 0 -i "Capture screen 0:none" -t 24 \
      -c:v libx264 -preset ultrafast -crf 12 "$OUT/screen.mov" >>"$LOG" 2>&1 &
    local FF=$!; sleep 2
    PERCH_DATA="$DATA" "$BIN" --motion-script "$OUT/markers.json" >>"$LOG" 2>&1 &
    P=$!
    for _ in $(seq 1 40); do kill -0 $P 2>/dev/null || break; sleep 0.5; done
    kill $P 2>/dev/null; wait $FF; log "ffmpeg avfoundation exit=$? size=$(stat -f%z "$OUT/screen.mov" 2>/dev/null || echo none)"
  fi

  # Pass 2: in-process own-window renders every 16 ms. Separate run so the extra main-thread work can't
  # disturb the recording above. Labelled "in-process-snapshot" everywhere.
  rm -f "$DATA"; mkdir -p "$OUT/in-process"
  # In-process AX wake only here (no external query), so the two passes show which wake works on this host.
  PERCH_MOTION_AX_WAKE="${PERCH_MOTION_AX_WAKE_PASS2:-inproc}" PERCH_DATA="$DATA" "$BIN" --motion-script "$OUT/in-process/markers.json" --motion-snapshots "$OUT/in-process" >>"$LOG" 2>&1 &
  P=$!
  for _ in $(seq 1 60); do kill -0 $P 2>/dev/null || break; sleep 0.5; done
  kill $P 2>/dev/null
  rm -f "$DATA"
  return 0
}

if [ "${POSTPROCESS_ONLY:-0}" != 1 ]; then
  [ "$(uname)" = Darwin ] || { log "recording needs macOS; use POSTPROCESS_ONLY=1 elsewhere"; exit 2; }
  need_ffmpeg || log "ffmpeg unavailable: no clips, sheets or frame diffs; summary still lists markers and raw frames"
  record || exit 3
fi
HAVE_FF=0; need_ffmpeg && HAVE_FF=1
[ "$HAVE_FF" = 1 ] || log "ffmpeg/ffprobe missing: post-processing limited to markers + raw in-process frame timing"

# Exit codes: 0 = driver ran (frames may still be UNVERIFIED if this host can't record; see summary.md),
# 3 = driver wiring broken (no app, missing markers or transitions), anything else = post-processing crashed.
HAVE_FF=$HAVE_FF python3 - "$OUT" <<'PY'
import glob, hashlib, json, math, os, shutil, statistics, subprocess, sys
out = sys.argv[1]
CLIPS = ["open", "close", "page", "tick", "timer"]
PRE, POST = 0.3, 1.25             # clip window around each marker, seconds
GRID_FPS = 60                     # fixed output timeline per clip (deterministic frame count)
GRID_N = round((PRE + POST) * GRID_FPS)  # 93 frames per clip
GW, GH = 256, 144                 # analysis raster (grey) for frame differences
CHANGED = 0.25                    # mean |delta| on 0-255 grey above which a frame counts as changed
HAVE_FF = os.environ.get("HAVE_FF") == "1"
WIRING = ["ready", "open", "close", "reopen", "page", "page-back", "tick", "timer", "end"]
log = open(os.path.join(out, "capture.log"), "a")
def sh(cmd, **kw):
    log.write("$ " + " ".join(cmd) + "\n"); log.flush()
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=log, **kw)
ver = sh(["ffmpeg", "-hide_banner", "-version"]).stdout.decode() if HAVE_FF else ""
PASS = (["-fps_mode", "passthrough"] if "-fps_mode" in sh(["ffmpeg", "-hide_banner", "-h", "long"]).stdout.decode() else ["-vsync", "0"]) if HAVE_FF else []

def probe_pts(path):
    r = sh(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=pts_time,best_effort_timestamp_time:stream=width,height,avg_frame_rate,r_frame_rate", "-of", "json", path])
    j = json.loads(r.stdout or b"{}")
    pts = []
    for f in j.get("frames", []):
        v = f.get("pts_time", f.get("best_effort_timestamp_time"))
        if v not in (None, "N/A"): pts.append(float(v))
    return pts, (j.get("streams") or [{}])[0]

def grey_frames(inputs, crop=None):
    vf = ([f"crop={crop}"] if crop else []) + [f"scale={GW}:{GH}:flags=area", "format=gray"]
    r = sh(["ffmpeg", "-v", "error"] + inputs + PASS + ["-vf", ",".join(vf), "-f", "rawvideo", "-"])
    n = GW * GH
    return [r.stdout[i:i + n] for i in range(0, len(r.stdout) - n + 1, n)]

def diff(a, b):
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a) if a and b else 0.0

def motion_stats(times, diffs, grey):
    ch = [i for i, d in enumerate(diffs) if i > 0 and d > CHANGED]
    if not ch: return dict(changed_frames=0, distinct_intermediate_frames=0, motion_span_s=0, median_interval_ms=None, fps_in_motion=None)
    first, last = ch[0], ch[-1]
    before, after = grey[first - 1], grey[last]
    # Distinct intermediate: differs from its predecessor, from the before state and from the settled end state.
    inter = [i for i in ch if i != last and diff(grey[i], before) > CHANGED and diff(grey[i], after) > CHANGED]
    span = times[last] - times[first - 1] if first > 0 else times[last] - times[first]
    iv = [times[i] - times[i - 1] for i in range(first, last + 1)]
    med = statistics.median(iv) if iv else None
    return dict(changed_frames=len(ch), distinct_intermediate_frames=len(inter), intermediate_frame_indices=inter, motion_span_s=round(span, 4),
                motion_start_s=round(times[first - 1] if first > 0 else times[first], 4), motion_end_s=round(times[last], 4),
                median_interval_ms=round(med * 1000, 2) if med else None, fps_in_motion=round(1 / med, 1) if med else None)

def sheet(pattern, dest, count):
    if count == 0 or not HAVE_FF: return
    cols = 6; rows = max(1, math.ceil(min(count, 48) / cols))
    sh(["ffmpeg", "-v", "error", "-y", "-framerate", "60", "-i", pattern, "-frames:v", "1",
        "-vf", f"select=lt(n\\,48),scale=300:-1,tile={cols}x{rows}:padding=4:margin=4:color=0x303030", dest])

summary = {"ffmpeg": ver.splitlines()[0] if ver else None, "threshold_mean_abs_delta": CHANGED, "analysis_raster": f"{GW}x{GH} grey",
           "screen_recording": None, "in_process": None}

# ---------- 0. Driver wiring (needs no ffmpeg): every scripted transition fired, and how ----------
def wiring(path):
    if not os.path.exists(path): return {"ok": False, "error": f"missing {os.path.relpath(path, out)}"}
    mk = json.load(open(path))["markers"]; seen = {m["name"]: m.get("via") for m in mk}
    miss = [n for n in WIRING if n not in seen]
    fallbacks = [n for n, v in seen.items() if str(v).startswith("direct") or v == "none"]
    # AX diagnostics from the driver: notch-panel AX node count before each step, and the wake report.
    ax = {m["name"]: m.get("ax_nodes") for m in mk if "ax_nodes" in m}
    reo = next((m for m in mk if m["name"] == "reopen"), {})
    wake = {k: reo.get(k) for k in ("ax_wake_mode", "ax_trusted", "ax_wake_inproc") if k in reo}
    return {"ok": not miss, "missing": miss, "via": seen, "direct_fallbacks": fallbacks, "ax_nodes": ax, "ax_wake": wake}
summary["wiring"] = {"screen_pass": wiring(os.path.join(out, "markers.json")),
                     "in_process_pass": wiring(os.path.join(out, "in-process", "markers.json"))}
axw = os.path.join(out, "ax-wake.txt")
if os.path.exists(axw): summary["wiring"]["screen_pass"]["ax_wake_external"] = open(axw).read().strip()

# ---------- 1. Screen recording ----------
mov = os.path.join(out, "screen.mov")
markers_path = os.path.join(out, "markers.json")
if not HAVE_FF:
    summary["screen_recording"] = {"error": "ffmpeg/ffprobe not installed on this host; screen.mov (if any) left unanalysed"}
elif os.path.exists(mov) and os.path.getsize(mov) > 0 and os.path.exists(markers_path):
    pts, st = probe_pts(mov)
    W, H = int(st.get("width", 0)), int(st.get("height", 0))
    mk = json.load(open(markers_path))
    scr = (mk.get("screens") or [{}])[0]
    # Analyse the top 2/3 of the screen (where the notch and its workspace live).
    crop = f"{W}:{int(H * 0.66) // 2 * 2}:0:0"
    g = grey_frames(["-i", mov], crop)
    n = min(len(g), len(pts)); g, pts = g[:n], pts[:n]
    d = [0.0] + [diff(g[i - 1], g[i]) for i in range(1, n)]
    start = float(open(os.path.join(out, "record_start_epoch.txt")).read())
    M = {m["name"]: m for m in mk["markers"]}
    # Align wall-clock markers to video time on the first visible change after "open" (recorder start latency).
    est = M["open"]["t"] - start
    # The recorder starts L >= 0 s after record_start_epoch, so the open shows up at video time est - L.
    # The app idles 4 s before opening; require ~0.3 s of stillness so the launch can't match.
    cand = [i for i in range(20, n) if est - 2.5 <= pts[i] <= est + 0.5 and d[i] > CHANGED and max(d[i - 18:i]) <= CHANGED]
    offset = (pts[cand[0] - 1] - est) if cand else 0.0
    rec = {"source": "screencapture -V (real compositor output)", "file": "screen.mov", "width": W, "height": H,
           "screen_points": scr, "frames": n, "duration_s": round(pts[-1] - pts[0], 3) if n else 0,
           "stream_avg_frame_rate": st.get("avg_frame_rate"), "stream_r_frame_rate": st.get("r_frame_rate"),
           "alignment_offset_s": round(offset, 4), "aligned_on": "first changed frame after the open marker" if cand else "none (raw clock)",
           "clips": {}}
    # Re-anchor every marker in timeline order: the recorder clock drifts from the app clock (~0.3 s over
    # 10 s on a hosted VM), so one offset from "open" mis-windows later clips. Each marker snaps to the first
    # visible change in [pred-0.25, pred+0.8] after the previous anchor and carries its offset forward.
    anchor_off, last_i, cur = {}, 0, offset
    for m in sorted(mk["markers"], key=lambda m: m["t"]):
        pred = m["t"] - start + cur
        hit = next((i for i in range(max(last_i + 1, 1), n) if pred - 0.25 <= pts[i] <= pred + 0.8 and d[i] > CHANGED), None)
        if hit is not None:
            cur = pts[hit - 1] - (m["t"] - start); last_i = hit
        anchor_off[m["name"]] = (cur, hit is not None)
    rec["per_marker_offset_s"] = {k: [round(v[0], 4), v[1]] for k, v in anchor_off.items()}
    for name in CLIPS:
        if name not in M: continue
        off_n = anchor_off.get(name, (offset, False))[0]
        vt = M[name]["t"] - start + off_n
        idx = [i for i in range(n) if vt - PRE <= pts[i] <= vt + POST]
        cdir = os.path.join(out, name); shutil.rmtree(cdir, ignore_errors=True); os.makedirs(os.path.join(cdir, "frames"))
        if not idx:
            rec["clips"][name] = {"error": "no frames in window"}; continue
        a, b = pts[idx[0]], pts[idx[-1]]
        # Raw recorder frames in the window (screencapture is variable-rate: it skips static frames).
        rdir = os.path.join(cdir, ".raw"); os.makedirs(rdir)
        sel = f"select=between(n\\,{idx[0]}\\,{idx[-1]}),setpts=PTS-STARTPTS"
        sh(["ffmpeg", "-v", "error", "-y", "-i", mov, *PASS, "-vf", f"{sel},crop={crop}", "-start_number", "0", os.path.join(rdir, "r%04d.png")])
        raw = sorted(glob.glob(os.path.join(rdir, "r*.png")))
        # Deterministic output: exactly GRID_N frames per clip on a fixed 60 fps grid from marker-PRE, each the
        # latest recorder frame at or before that instant (sample-and-hold). Same count and timestamps every run.
        grid, j = [], 0
        for k in range(GRID_N):
            t = vt - PRE + k / GRID_FPS
            while j + 1 < len(idx) and pts[idx[j + 1]] <= t + 1e-6: j += 1
            grid.append((k, t, j))
        for k, t, jj in grid:
            if jj < len(raw): shutil.copyfile(raw[jj], os.path.join(cdir, "frames", f"f{k:04d}.png"))
        shutil.rmtree(rdir)
        sh(["ffmpeg", "-v", "error", "-y", "-framerate", str(GRID_FPS), "-start_number", "0", "-i", os.path.join(cdir, "frames", "f%04d.png"),
            "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-c:v", "libx264", "-crf", "16", "-pix_fmt", "yuv420p", "-an", os.path.join(cdir, "clip.mp4")])
        files = sorted(glob.glob(os.path.join(cdir, "frames", "f*.png")))
        # Motion stats use the raw recorder frames (true intermediates), not the held grid.
        times = [pts[i] for i in idx]; dd = [0.0] + [d[i] for i in idx[1:]]
        stats = motion_stats(times, dd, [g[i] for i in idx])
        frames = []
        for k, t, jj in grid:
            src = idx[jj]; prev = idx[grid[k - 1][2]] if k else None
            dk = diff(g[prev], g[src]) if prev is not None and prev != src else 0.0
            frames.append({"i": k, "file": f"frames/f{k:04d}.png", "t_from_marker_ms": round((t - vt) * 1000, 2),
                           "source_video_pts_s": round(pts[src], 5), "held": prev == src, "mean_abs_delta": round(dk, 4), "changed": dk > CHANGED})
        meta = {"clip": name, "kind": "screen-recording", "marker": M[name], "alignment_offset_s": round(off_n, 4), "window_s": [round(a, 4), round(b, 4)],
                "grid": {"fps": GRID_FPS, "frames": GRID_N, "from_marker_s": -PRE}, "raw_frames_in_window": len(idx), **stats, "frames": frames}
        json.dump(meta, open(os.path.join(cdir, "frames.json"), "w"), indent=1)
        # Contact sheet starts one frame before the motion so the before state is visible.
        first_ch = next((k for k, f in enumerate(frames) if f["changed"]), 0)
        sdir = os.path.join(cdir, ".sheet"); os.makedirs(sdir, exist_ok=True)
        for k, f in enumerate(files[max(0, first_ch - 1):]):
            os.symlink(f, os.path.join(sdir, f"f{k:04d}.png"))
        sheet(os.path.join(sdir, "f%04d.png"), os.path.join(cdir, "sheet.png"), len(files)); shutil.rmtree(sdir)
        rec["clips"][name] = {k: v for k, v in meta.items() if k != "frames"} | {"frames_in_window": GRID_N, "via": M[name].get("via")}
    summary["screen_recording"] = rec
else:
    what = "screen.mov missing or empty (recorder refused or no Screen Recording grant)" if os.path.exists(markers_path) else "markers.json missing"
    summary["screen_recording"] = {"error": what + "; see capture.log for the recorder's exact output"}

# ---------- 2. In-process 16 ms snapshots (labelled fallback) ----------
ip = os.path.join(out, "in-process")
if os.path.isdir(ip):
    res = {"source": "in-process own-window render (NSView.cacheDisplay every 16 ms), NOT compositor output", "clips": {}}
    ipmk = os.path.join(ip, "markers.json")
    ipvia = {m["name"]: m.get("via") for m in json.load(open(ipmk))["markers"]} if os.path.exists(ipmk) else {}
    for name in CLIPS:
        fj = os.path.join(ip, name, "frames.json")
        if not os.path.exists(fj): continue
        meta = json.load(open(fj)); fr = meta["frames"]
        if not fr: continue
        times = [f["t"] for f in fr]
        if HAVE_FF:
            pngs = [os.path.join(ip, name, f["file"]) for f in fr]
            lst = os.path.join(ip, name, "list.txt")
            open(lst, "w").write("".join(f"file '{p}'\n" for p in pngs))
            g = grey_frames(["-f", "concat", "-safe", "0", "-i", lst]); os.remove(lst)
            times = times[:len(g)]
            dd = [0.0] + [diff(g[i - 1], g[i]) for i in range(1, len(g))]
            for k, f in enumerate(fr[:len(g)]): f["mean_abs_delta"] = round(dd[k], 4); f["changed"] = dd[k] > CHANGED
            meta.update(motion_stats(times, dd, g))
        else:
            # Byte-identical PNGs are the only "no change" signal available without a decoder.
            dig = [hashlib.sha1(open(os.path.join(ip, name, f["file"]), "rb").read()).hexdigest() for f in fr]
            meta.update(changed_frames=None, distinct_intermediate_frames=None, byte_distinct_frames=len(set(dig)))
        iv = [times[i] - times[i - 1] for i in range(1, len(times))]
        meta.update(median_spacing_ms=round(statistics.median(iv) * 1000, 2) if iv else None,
                    max_spacing_ms=round(max(iv) * 1000, 2) if iv else None)
        json.dump(meta, open(fj, "w"), indent=1)
        sheet(os.path.join(ip, name, "f%03d.png"), os.path.join(ip, name, "sheet.png"), len(fr))
        # mp4 at the requested 16 ms cadence (62.5 fps); frames.json has the real timestamps.
        if HAVE_FF: sh(["ffmpeg", "-v", "error", "-y", "-framerate", "62.5", "-i", os.path.join(ip, name, "f%03d.png"),
            "-c:v", "libx264", "-crf", "16", "-pix_fmt", "yuv420p", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", os.path.join(ip, name, "clip.mp4")])
        res["clips"][name] = {k: v for k, v in meta.items() if k != "frames"} | {"frames_total": len(fr), "via": ipvia.get(name)}
    if os.path.exists(ipmk): res["markers"] = json.load(open(ipmk))["markers"]
    summary["in_process"] = res

sr = summary["screen_recording"] or {}
recorded = "error" not in sr and any("error" not in c for c in sr.get("clips", {}).values())
wired = summary["wiring"]["screen_pass"]["ok"] or summary["wiring"]["in_process_pass"]["ok"]
summary["status"] = ("RECORDED" if recorded else "UNVERIFIED") if wired else "WIRING-BROKEN"
summary["status_reason"] = ("compositor frames recorded" if recorded else
                            "no compositor recording on this host: " + sr.get("error", "no usable clips")) if wired else "driver markers missing"
json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=1)
L = ["# Perch motion capture summary", "", f"**Motion frames: {summary['status']}** ({summary['status_reason']})", "", "## Driver wiring"]
for k, w in summary["wiring"].items():
    if "error" in w: L.append(f"- {k}: ERROR {w['error']}"); continue
    L.append(f"- {k}: {'ok' if w['ok'] else 'MISSING ' + ', '.join(w['missing'])}; via " +
             ", ".join(f"{n}={v}" for n, v in w["via"].items()) + (f"; direct fallbacks: {', '.join(w['direct_fallbacks'])}" if w["direct_fallbacks"] else ""))
    if w.get("ax_nodes"): L.append(f"  - AX nodes before each step: " + ", ".join(f"{n}={v}" for n, v in w["ax_nodes"].items()))
    if w.get("ax_wake"): L.append(f"  - AX wake: " + ", ".join(f"{k}={v}" for k, v in w["ax_wake"].items()))
    if w.get("ax_wake_external"): L.append("  - external AX query (System Events): " + w["ax_wake_external"].replace("\n", " | "))
L.append("")
for key, title in (("screen_recording", "Screen recording"), ("in_process", "In-process 16 ms snapshots (fallback, not compositor)")):
    r = summary.get(key)
    L.append(f"## {title}")
    if not r: L.append("not run"); L.append(""); continue
    if "error" in r: L.append(f"ERROR: {r['error']}"); L.append(""); continue
    L.append(f"source: {r['source']}")
    if key == "screen_recording":
        L.append(f"{r['width']}x{r['height']}, {r['frames']} frames over {r['duration_s']} s, avg_frame_rate {r['stream_avg_frame_rate']}, alignment offset {r['alignment_offset_s']} s")
    L.append("")
    L.append("| clip | via | changed frames | distinct intermediate | motion span s | median interval ms | fps in motion |")
    L.append("|---|---|---|---|---|---|---|")
    for name, c in r["clips"].items():
        via = c.get("via") or (c.get("marker") or {}).get("via", "")
        changed = c.get("changed_frames") if c.get("changed_frames") is not None else f"n/a ({c.get('byte_distinct_frames')} byte-distinct of {c.get('frames_total')})"
        L.append(f"| {name} | {via} | {changed} | {c.get('distinct_intermediate_frames', 'n/a')} | {c.get('motion_span_s', 'n/a')} | {c.get('median_interval_ms', c.get('median_spacing_ms'))} | {c.get('fps_in_motion', 'n/a')} |")
    L.append("")
open(os.path.join(out, "summary.md"), "w").write("\n".join(L))
print("\n".join(L))
sys.exit(3 if summary["status"] == "WIRING-BROKEN" else 0)
PY
RC=$?
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$OUT/summary.md" ] && cat "$OUT/summary.md" >>"$GITHUB_STEP_SUMMARY"
if [ -f "$OUT/summary.json" ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
  ST=$(python3 -c 'import json,sys;j=json.load(open(sys.argv[1]));print(j["status"]+": "+j["status_reason"])' "$OUT/summary.json")
  case "$ST" in RECORDED*) ;; *) echo "::warning title=Perch motion frames::$ST" ;; esac
fi
exit $RC
