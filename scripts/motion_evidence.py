import glob, hashlib, json, math, os, shutil, statistics, subprocess, sys
from motion_evidence_rules import qualify, window_bounds, candidate_stats
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
    stats = candidate_stats(times, grey, CHANGED)
    stats["target_intermediates"] = None
    stats["classification"] = "UNREVIEWED: whole-window changes may be focus ring, countdown, or unrelated feedback; not animation quality"
    stats["settle_time_s"] = None
    return stats

def sheet(pattern, dest, count):
    if count == 0 or not HAVE_FF: return
    cols = 6; rows = max(1, math.ceil(min(count, 48) / cols))
    sh(["ffmpeg", "-v", "error", "-y", "-framerate", "60", "-i", pattern, "-frames:v", "1",
        "-vf", f"select=lt(n\\,48),scale=300:-1,tile={cols}x{rows}:padding=4:margin=4:color=0x303030", dest])

summary = {"ffmpeg": ver.splitlines()[0] if ver else None, "threshold_mean_abs_delta": CHANGED, "analysis_raster": f"{GW}x{GH} grey",
           "schema": 2, "screen_recording": None, "in_process": None}

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
    failed = [m["name"] for m in mk if str(m.get("via", "")).startswith("FAILED:") or (m["name"] in ("page", "tick", "timer") and not str(m.get("via", "")).startswith("ax-press:"))]
    return {"ok": not miss and not failed, "failed_interactions": failed, "missing": miss, "via": seen, "direct_fallbacks": fallbacks, "ax_nodes": ax, "ax_wake": wake}
summary["wiring"] = {"screen_pass": wiring(os.path.join(out, "markers.json")),
                     "in_process_pass": wiring(os.path.join(out, "in-process", "markers.json"))}

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
    # Keep a fixed logical-width region around the centered workspace. Scaling an entire 1920px
    # desktop down to GW diluted a real task removal below CHANGED (0.12 versus the 0.25 threshold).
    # Respect backing scale and keep the full workspace height; the original 1024x768 crop is unchanged.
    scale = float(scr.get("scale", 1))
    cw = min(W, int(1024 * scale) // 2 * 2)
    ch = min(int(H * 0.66) // 2 * 2, int(600 * scale) // 2 * 2)
    cx = (W - cw) // 4 * 2
    crop = f"{cw}:{ch}:{cx}:0"
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
    rec = {"source": open(os.path.join(out, "source.txt")).read().strip() if os.path.exists(os.path.join(out, "source.txt")) else "historical recorder (source not explicitly logged)", "file": "screen.mov", "width": W, "height": H,
           "screen_points": scr, "analysis_crop": crop, "frames": n, "duration_s": round(pts[-1] - pts[0], 3) if n else 0,
           "stream_avg_frame_rate": st.get("avg_frame_rate"), "stream_r_frame_rate": st.get("r_frame_rate"),
           "alignment_offset_s": round(offset, 4), "aligned_on": "first changed frame after the open marker" if cand else "none (raw clock)",
           "clips": {}}
    # Re-anchor every marker in timeline order: the recorder clock drifts from the app clock (~0.3 s over
    # 10 s on a hosted VM), so one offset from "open" mis-windows later clips. Each marker snaps to the first
    # visible change in [pred-0.4, pred+0.8] after the previous anchor. Its offset is carried forward only if it
    # moved by <= 0.4 s: clock drift is slow, while a larger jump is a late render (the AX wake can hold the main
    # thread at "reopen" for ~0.7 s) and carrying it would push the next window past the next marker's change.
    anchor_off, last_i, cur = {}, 0, offset
    for m in sorted(mk["markers"], key=lambda m: m["t"]):
        pred = m["t"] - start + cur
        hit = next((i for i in range(max(last_i + 1, 1), n) if pred - 0.4 <= pts[i] <= pred + 0.8 and d[i] > CHANGED), None)
        own = cur
        if hit is not None:
            own = pts[hit - 1] - (m["t"] - start); last_i = hit
            if abs(own - cur) <= 0.4: cur = own
        anchor_off[m["name"]] = (own, hit is not None)
    rec["per_marker_offset_s"] = {k: [round(v[0], 4), v[1]] for k, v in anchor_off.items()}
    ordered = sorted(mk["markers"], key=lambda m: m["t"])
    rec["candidate_sha"] = mk.get("candidate_sha")
    rec["source_sha256"] = hashlib.sha256(open(mov, "rb").read()).hexdigest()
    for name in CLIPS:
        if name not in M: continue
        off_n = anchor_off.get(name, (offset, False))[0]
        vt = M[name]["t"] - start + off_n
        following = next((m for m in ordered if m["t"] > M[name]["t"]), None)
        next_time = None
        if following:
            next_offset = anchor_off.get(following["name"], (off_n, False))[0]
            next_time = min(following["t"] - start + off_n, following["t"] - start + next_offset)
        low, high = window_bounds(vt, next_time, PRE, POST)
        grid_n = max(1, math.floor((high-low)*GRID_FPS))
        idx = [i for i in range(n) if low <= pts[i] < high]
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
        for k in range(grid_n):
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
                           "source_frame_index": src, "source_video_pts_s": round(pts[src], 5), "held": prev == src, "mean_abs_delta": round(dk, 4), "changed": dk > CHANGED})
        meta = {"clip": name, "kind": "screen-recording", "marker": M[name], "alignment_offset_s": round(off_n, 4), "window_s": [round(a, 4), round(b, 4)],
                "qualification": qualify(M[name], mk.get("candidate_sha")),
                "bounded_end_pts_s": high, "next_action": following["name"] if following else None,
                "grid": {"fps": GRID_FPS, "frames": grid_n, "from_marker_s": -PRE}, "raw_frames_in_window": len(idx), **stats, "frames": frames}
        json.dump(meta, open(os.path.join(cdir, "frames.json"), "w"), indent=1)
        # Contact sheet starts one frame before the motion so the before state is visible.
        first_ch = next((k for k, f in enumerate(frames) if f["changed"]), 0)
        sdir = os.path.join(cdir, ".sheet"); os.makedirs(sdir, exist_ok=True)
        for k, f in enumerate(files[max(0, first_ch - 1):]):
            os.symlink(f, os.path.join(sdir, f"f{k:04d}.png"))
        sheet(os.path.join(sdir, "f%04d.png"), os.path.join(cdir, "sheet.png"), len(files)); shutil.rmtree(sdir)
        rec["clips"][name] = {k: v for k, v in meta.items() if k != "frames"} | {"frames_in_window": grid_n, "via": M[name].get("via")}
    summary["screen_recording"] = rec
    summary["policy_qualified"] = all(c.get("qualification", {}).get("qualified", False) for c in rec["clips"].values())
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
wired = summary["wiring"]["screen_pass"]["ok"]
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
    L.append("| clip | via | whole-window changes | unique unclassified candidates | whole-window span (NOT settle time) | policy qualified | target intermediates |")
    L.append("|---|---|---|---|---|---|---|")
    for name, c in r["clips"].items():
        via = c.get("via") or (c.get("marker") or {}).get("via", "")
        changed = len(c["changed_source_indices"]) if "changed_source_indices" in c else f"n/a ({c.get('byte_distinct_frames')} byte-distinct of {c.get('frames_total')})"
        L.append(f"| {name} | {via} | {changed} | {c.get('unique_unclassified_intermediates', 'n/a')} | {c.get('whole_window_change_span_s', 'n/a')} | {c.get('qualification', {}).get('qualified', False)} | UNREVIEWED |")
    L.append("")
open(os.path.join(out, "summary.md"), "w").write("\n".join(L))
print("\n".join(L))
sys.exit(3 if summary["status"] == "WIRING-BROKEN" else 0)
