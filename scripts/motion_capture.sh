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
  PERCH_DATA="$DATA" "$BIN" --motion-script "$OUT/markers.json" >>"$LOG" 2>&1 &
  local P=$!
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
  PERCH_DATA="$DATA" "$BIN" --motion-script "$OUT/in-process/markers.json" --motion-snapshots "$OUT/in-process" >>"$LOG" 2>&1 &
  P=$!
  for _ in $(seq 1 60); do kill -0 $P 2>/dev/null || break; sleep 0.5; done
  kill $P 2>/dev/null
  rm -f "$DATA"
  return 0
}

if [ "${POSTPROCESS_ONLY:-0}" != 1 ]; then
  [ "$(uname)" = Darwin ] || { log "recording needs macOS; use POSTPROCESS_ONLY=1 elsewhere"; exit 2; }
  need_ffmpeg || log "ffmpeg unavailable: no clips or sheets can be made"
  record
fi
need_ffmpeg || { log "ffmpeg/ffprobe required for post-processing"; exit 1; }

python3 - "$OUT" <<'PY'
import glob, hashlib, json, math, os, shutil, statistics, subprocess, sys
out = sys.argv[1]
CLIPS = ["open", "close", "page", "tick", "timer"]
PRE, POST = 0.15, 1.25            # clip window around each marker, seconds
GW, GH = 256, 144                 # analysis raster (grey) for frame differences
CHANGED = 0.25                    # mean |delta| on 0-255 grey above which a frame counts as changed
log = open(os.path.join(out, "capture.log"), "a")
def sh(cmd, **kw):
    log.write("$ " + " ".join(cmd) + "\n"); log.flush()
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=log, **kw)
ver = sh(["ffmpeg", "-hide_banner", "-version"]).stdout.decode()
PASS = ["-fps_mode", "passthrough"] if "-fps_mode" in sh(["ffmpeg", "-hide_banner", "-h", "long"]).stdout.decode() else ["-vsync", "0"]

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
    if count == 0: return
    cols = 6; rows = max(1, math.ceil(min(count, 48) / cols))
    sh(["ffmpeg", "-v", "error", "-y", "-framerate", "60", "-i", pattern, "-frames:v", "1",
        "-vf", f"select=lt(n\\,48),scale=300:-1,tile={cols}x{rows}:padding=4:margin=4:color=0x303030", dest])

summary = {"ffmpeg": ver.splitlines()[0] if ver else "", "threshold_mean_abs_delta": CHANGED, "analysis_raster": f"{GW}x{GH} grey",
           "screen_recording": None, "in_process": None}

# ---------- 1. Screen recording ----------
mov = os.path.join(out, "screen.mov")
markers_path = os.path.join(out, "markers.json")
if os.path.exists(mov) and os.path.getsize(mov) > 0 and os.path.exists(markers_path):
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
    for name in CLIPS:
        if name not in M: continue
        vt = M[name]["t"] - start + offset
        idx = [i for i in range(n) if vt - PRE <= pts[i] <= vt + POST]
        cdir = os.path.join(out, name); shutil.rmtree(cdir, ignore_errors=True); os.makedirs(os.path.join(cdir, "frames"))
        if not idx:
            rec["clips"][name] = {"error": "no frames in window"}; continue
        a, b = pts[idx[0]], pts[idx[-1]]
        sel = f"select=between(n\\,{idx[0]}\\,{idx[-1]}),setpts=PTS-STARTPTS"
        sh(["ffmpeg", "-v", "error", "-y", "-i", mov, *PASS, "-vf", sel + ",pad=ceil(iw/2)*2:ceil(ih/2)*2",
            "-c:v", "libx264", "-crf", "16", "-pix_fmt", "yuv420p", "-an", os.path.join(cdir, "clip.mp4")])
        sh(["ffmpeg", "-v", "error", "-y", "-i", mov, *PASS, "-vf", f"{sel},crop={crop}",
            "-start_number", "0", os.path.join(cdir, "frames", "f%04d.png")])
        files = sorted(glob.glob(os.path.join(cdir, "frames", "f*.png")))
        times = [pts[i] for i in idx]; dd = [0.0] + [d[i] for i in idx[1:]]
        stats = motion_stats(times, dd, [g[i] for i in idx])
        frames = [{"i": k, "file": f"frames/f{k:04d}.png" if k < len(files) else None, "video_pts_s": round(pts[i], 5),
                   "t_from_marker_ms": round((pts[i] - vt) * 1000, 2), "mean_abs_delta": round(dd[k], 4), "changed": dd[k] > CHANGED}
                  for k, i in enumerate(idx)]
        meta = {"clip": name, "kind": "screen-recording", "marker": M[name], "window_s": [round(a, 4), round(b, 4)], **stats, "frames": frames}
        json.dump(meta, open(os.path.join(cdir, "frames.json"), "w"), indent=1)
        # Contact sheet starts one frame before the motion so the before state is visible.
        first_ch = next((k for k, f in enumerate(frames) if f["changed"]), 0)
        sdir = os.path.join(cdir, ".sheet"); os.makedirs(sdir, exist_ok=True)
        for k, f in enumerate(files[max(0, first_ch - 1):]):
            os.symlink(f, os.path.join(sdir, f"f{k:04d}.png"))
        sheet(os.path.join(sdir, "f%04d.png"), os.path.join(cdir, "sheet.png"), len(files)); shutil.rmtree(sdir)
        rec["clips"][name] = {k: v for k, v in meta.items() if k != "frames"} | {"frames_in_window": len(idx), "via": M[name].get("via")}
    summary["screen_recording"] = rec
else:
    summary["screen_recording"] = {"error": "no screen.mov or markers.json; see capture.log for the recorder's exact output"}

# ---------- 2. In-process 16 ms snapshots (labelled fallback) ----------
ip = os.path.join(out, "in-process")
if os.path.isdir(ip):
    res = {"source": "in-process own-window render (NSView.cacheDisplay every 16 ms), NOT compositor output", "clips": {}}
    for name in CLIPS:
        fj = os.path.join(ip, name, "frames.json")
        if not os.path.exists(fj): continue
        meta = json.load(open(fj)); fr = meta["frames"]
        if not fr: continue
        pngs = [os.path.join(ip, name, f["file"]) for f in fr]
        lst = os.path.join(ip, name, "list.txt")
        open(lst, "w").write("".join(f"file '{p}'\n" for p in pngs))
        g = grey_frames(["-f", "concat", "-safe", "0", "-i", lst]); os.remove(lst)
        times = [f["t"] for f in fr][:len(g)]
        dd = [0.0] + [diff(g[i - 1], g[i]) for i in range(1, len(g))]
        for k, f in enumerate(fr[:len(g)]): f["mean_abs_delta"] = round(dd[k], 4); f["changed"] = dd[k] > CHANGED
        iv = [times[i] - times[i - 1] for i in range(1, len(times))]
        meta.update(motion_stats(times, dd, g), median_spacing_ms=round(statistics.median(iv) * 1000, 2) if iv else None,
                    max_spacing_ms=round(max(iv) * 1000, 2) if iv else None)
        json.dump(meta, open(fj, "w"), indent=1)
        sheet(os.path.join(ip, name, "f%03d.png"), os.path.join(ip, name, "sheet.png"), len(fr))
        # mp4 at the requested 16 ms cadence (62.5 fps); frames.json has the real timestamps.
        sh(["ffmpeg", "-v", "error", "-y", "-framerate", "62.5", "-i", os.path.join(ip, name, "f%03d.png"),
            "-c:v", "libx264", "-crf", "16", "-pix_fmt", "yuv420p", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", os.path.join(ip, name, "clip.mp4")])
        res["clips"][name] = {k: v for k, v in meta.items() if k != "frames"} | {"frames_total": len(fr)}
    mk = os.path.join(ip, "markers.json")
    if os.path.exists(mk): res["markers"] = json.load(open(mk))["markers"]
    summary["in_process"] = res

json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=1)
L = ["# Perch motion capture summary", ""]
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
        L.append(f"| {name} | {via} | {c.get('changed_frames')} | {c.get('distinct_intermediate_frames')} | {c.get('motion_span_s')} | {c.get('median_interval_ms', c.get('median_spacing_ms'))} | {c.get('fps_in_motion')} |")
    L.append("")
open(os.path.join(out, "summary.md"), "w").write("\n".join(L))
print("\n".join(L))
PY
RC=$?
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$OUT/summary.md" ] && cat "$OUT/summary.md" >>"$GITHUB_STEP_SUMMARY"
exit $RC
