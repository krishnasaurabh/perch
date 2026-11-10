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

# SwiftUI builds a macOS app's accessibility tree lazily, on the first request from an accessibility client.
# A CI VM has no VoiceOver, so without a wake the driver's in-process button presses find nothing and every
# button step takes `direct:`. PERCH_MOTION_AX_WAKE=inproc (default) has the driver read its own windows through
# the AX API before the button steps; =none reproduces the empty tree.
AXMODE="${PERCH_MOTION_AX_WAKE:-inproc}"
drive() {  # drive <mode> <markers.json> <timeout-ticks> [extra args]: one driver run, waits for it to quit
  local MODE="$1" MK="$2" TICKS="$3"; shift 3
  PERCH_MOTION_AX_WAKE="$MODE" PERCH_DATA="$DATA" PERCH_CANDIDATE_SHA="${GITHUB_SHA:-$(git rev-parse HEAD)}" "$BIN" --motion-script "$MK" --motion-policy "${PERCH_MOTION_POLICY:-production}" "$@" >>"$LOG" 2>&1 &
  local P=$!
  for _ in $(seq 1 "$TICKS"); do kill -0 $P 2>/dev/null || break; sleep 0.5; done
  kill $P 2>/dev/null
  rm -f "$DATA"
}

record() {
  local BIN="$APP/Contents/MacOS/Perch"
  [ -x "$BIN" ] || { log "no app binary at $BIN"; return 1; }
  local DATA="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/motion-planner.json"

  # Pass 1: real screen recording (compositor output, includes the menu bar and desktop).
  rm -f "$DATA" "$OUT/screen.mov"
  python3 -c 'import time;print(repr(time.time()))' >"$OUT/record_start_epoch.txt"
  printf '%s\n' 'screencapture -V (real compositor output)' >"$OUT/source.txt"
  screencapture -x -V 40 "$OUT/screen.mov" >>"$LOG" 2>&1 &
  local SC=$!
  sleep 2
  drive "$AXMODE" "$OUT/markers.json" 76
  wait $SC; local RC=$?
  log "screencapture exit=$RC size=$(stat -f%z "$OUT/screen.mov" 2>/dev/null || echo none)"
  if [ ! -s "$OUT/screen.mov" ] && command -v ffmpeg >/dev/null; then
    log "screencapture produced no video; trying ffmpeg avfoundation"
    ffmpeg -hide_banner -f avfoundation -list_devices true -i "" >>"$LOG" 2>&1
    rm -f "$DATA"
    python3 -c 'import time;print(repr(time.time()))' >"$OUT/record_start_epoch.txt"
    printf '%s\n' 'ffmpeg avfoundation (real compositor output)' >"$OUT/source.txt"
    ffmpeg -hide_banner -y -f avfoundation -framerate 60 -capture_cursor 0 -i "Capture screen 0:none" -t 40 \
      -c:v libx264 -preset ultrafast -crf 12 "$OUT/screen.mov" >>"$LOG" 2>&1 &
    local FF=$!; sleep 2
    drive "$AXMODE" "$OUT/markers.json" 76
    wait $FF; log "ffmpeg avfoundation exit=$? size=$(stat -f%z "$OUT/screen.mov" 2>/dev/null || echo none)"
  fi

  # Pass 2: in-process own-window renders every 16 ms. Separate run so the extra main-thread work can't
  # disturb the recording above. Labelled "in-process-snapshot" everywhere.
  rm -f "$DATA"; mkdir -p "$OUT/in-process"
  drive "$AXMODE" "$OUT/in-process/markers.json" 100 --motion-snapshots "$OUT/in-process"
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
HAVE_FF=$HAVE_FF python3 "$(dirname "$0")/motion_evidence.py" "$OUT"
RC=$?
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$OUT/summary.md" ] && cat "$OUT/summary.md" >>"$GITHUB_STEP_SUMMARY"
if [ -f "$OUT/summary.json" ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
  ST=$(python3 -c 'import json,sys;j=json.load(open(sys.argv[1]));print(j["status"]+": "+j["status_reason"])' "$OUT/summary.json")
  case "$ST" in RECORDED*) ;; *) echo "::warning title=Perch motion frames::$ST" ;; esac
fi
exit $RC
