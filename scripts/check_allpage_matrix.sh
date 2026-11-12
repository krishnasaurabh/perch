#!/usr/bin/env bash
# macOS CI only: renders the real Settings, Dashboard, Welcome, Week, Clips and Details
# surfaces and drives them with real key events. Never writes the user's planner, clipboard or
# permission state: PERCH_DATA is synthetic, the probe stays unbundled, and nothing ever asks
# for access. The runner switches the system increase-contrast state on for the contrast
# measurements and restores whatever the runner had afterwards.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'This UI probe requires macOS.' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: check_allpage_matrix.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$ROOT/Tests" "$PROBE/"
cp "$ROOT/scripts/allpage_matrix_probe.swift" "$PROBE/Sources/Perch/main.swift"
swift build -Xswiftc -DPERCH_TESTING -Xswiftc -enable-testing --package-path "$PROBE" -c release --product Perch
python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import json, os, pathlib, subprocess, sys

binary, out = sys.argv[1:]
data = pathlib.Path(out) / 'planner.json'
data.write_text(json.dumps({'preferences': {
    'welcomeCompleted': True, 'catchCopies': False, 'catchScreenshots': False, 'remindersSync': False}}))


def read_contrast():
    result = subprocess.run(
        ['defaults', 'read', 'com.apple.universalaccess', 'increaseContrast'],
        capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ''


def write_contrast(value):
    subprocess.run(
        ['defaults', 'write', 'com.apple.universalaccess', 'increaseContrast', '-bool', value],
        check=False, capture_output=True, text=True)


prior = read_contrast()
write_contrast('true')
print('increase-contrast prior=%r now=%r' % (prior, read_contrast()))
try:
    # -AppleKeyboardUIMode 3 is an argument-domain override: real Tab traversal reaches buttons
    # and menus instead of text fields only, and nothing is written to the user's preferences.
    subprocess.run(
        [binary, '-AppleKeyboardUIMode', '3'],
        env=dict(os.environ, PERCH_DATA=str(data), MATRIX_OUTPUT=out),
        check=True, timeout=600)
finally:
    if prior in ('0', '1'):
        write_contrast('true' if prior == '1' else 'false')
    else:
        subprocess.run(
            ['defaults', 'delete', 'com.apple.universalaccess', 'increaseContrast'],
            check=False, capture_output=True, text=True)
    print('increase-contrast restored=%r' % read_contrast())
PY
