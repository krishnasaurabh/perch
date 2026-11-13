#!/usr/bin/env bash
# macOS CI only: renders the real Settings, Dashboard, Welcome, Week, Clips and Details
# surfaces and drives them with real key events. Never writes the user's planner, clipboard or
# permission state: PERCH_DATA is synthetic, the probe stays unbundled, and nothing ever asks
# for access. The runner switches the system increase-contrast state and full keyboard access
# on for the contrast and Tab measurements and restores whatever the runner had afterwards.
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
out = pathlib.Path(out)
data = out / 'planner.json'
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


def read_keyboard_mode():
    result = subprocess.run(
        ['defaults', 'read', '-g', 'AppleKeyboardUIMode'], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ''


def write_keyboard_mode(value):
    subprocess.run(
        ['defaults', 'write', '-g', 'AppleKeyboardUIMode', '-int', value],
        check=False, capture_output=True, text=True)


def run(label, extra):
    """Child output goes to a file so a trap or a timeout still shows what happened."""
    log_path = out / ('%s.log' % label)
    env = dict(os.environ, PERCH_DATA=str(data), MATRIX_OUTPUT=str(out),
               SWIFT_BACKTRACE='enable=yes')
    command = [binary, '-AppleKeyboardUIMode', '3'] + extra
    # Opt in only on the diagnostic branch. Unset GITHUB_REF and all other refs
    # retain the normal child invocation, including after a cherry-pick.
    if os.environ.get('GITHUB_REF') in (
            'refs/heads/t_7ef2077d-clickfix', 'refs/heads/t_7ef2077d-clickfix3',
            'refs/heads/t_95290d75-matrixreds') and label == 'matrix':
        command = [
            'lldb', '--batch', '-o', 'settings set target.disable-aslr false',
            '-o', 'run',
            '-o', 'script p = lldb.debugger.GetSelectedTarget().GetProcess(); '
                  'lldb.debugger.HandleCommand("quit %d" % '
                  '(p.GetExitStatus() if p.GetState() == lldb.eStateExited else 1))',
            '-k', 'thread backtrace all', '-k', 'quit 1', '--'] + command
        print('all-page matrix: out-of-process LLDB diagnostics enabled')
    print('running all-page matrix probe: %s' % label)
    with open(log_path, 'w') as handle:
        result = subprocess.run(
            command, env=env, stdout=handle, stderr=subprocess.STDOUT, timeout=300, check=False)
    lines = log_path.read_text(errors='replace').splitlines()
    print('--- %s exit=%s lines=%d ---' % (label, result.returncode, len(lines)))
    for line in lines[-120:]:
        print('%s: %s' % (label, line))
    print('--- end %s ---' % label)
    return result.returncode


prior = read_contrast()
write_contrast('true')
print('increase-contrast prior=%r now=%r' % (prior, read_contrast()))
# NSApp.isFullKeyboardAccessEnabled reads the global domain only; the argument-domain
# override below does not reach AppKit, so native controls (segmented pickers, plain
# buttons) would never join the Tab loop. Set the runner's global state for the child
# and restore whatever the runner had afterwards, exactly like increase-contrast.
prior_keyboard = read_keyboard_mode()
write_keyboard_mode('3')
print('full-keyboard-access prior=%r now=%r' % (prior_keyboard, read_keyboard_mode()))
failed = 0
try:
    # A single accessibility read per API, so a trap is attributable to one call.
    if run('ax-smoke', ['--ax-smoke']) != 0:
        failed = 1
    if run('matrix', []) != 0:
        failed = 1
finally:
    if prior in ('0', '1'):
        write_contrast('true' if prior == '1' else 'false')
    else:
        subprocess.run(
            ['defaults', 'delete', 'com.apple.universalaccess', 'increaseContrast'],
            check=False, capture_output=True, text=True)
    print('increase-contrast restored=%r' % read_contrast())
    if prior_keyboard:
        write_keyboard_mode(prior_keyboard)
    else:
        subprocess.run(
            ['defaults', 'delete', '-g', 'AppleKeyboardUIMode'],
            check=False, capture_output=True, text=True)
    print('full-keyboard-access restored=%r' % read_keyboard_mode())
sys.exit(1 if failed else 0)
PY
