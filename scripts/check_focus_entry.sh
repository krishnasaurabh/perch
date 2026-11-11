#!/usr/bin/env bash
# Own-process macOS UI test. Isolated planner; never drives an installed app.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'This UI probe requires macOS.' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: check_focus_entry.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$PROBE/"
cp -R "$ROOT/Tests" "$PROBE/"
cp "$ROOT/scripts/focus_entry_probe.swift" "$PROBE/Sources/Perch/main.swift"
git -C "$ROOT" rev-parse HEAD > "$OUT/source-sha.txt"
swift build -Xswiftc -DPERCH_TESTING -Xswiftc -enable-testing --package-path "$PROBE" -c release --product Perch
python3 - "$PROBE/.build/release/Perch" "$OUT" <<'PY'
import json, os, pathlib, subprocess, sys
binary, output = sys.argv[1:]
data = pathlib.Path(output) / 'planner.json'
data.write_text(json.dumps({'preferences': {'welcomeCompleted': True,
    'catchCopies': False, 'catchScreenshots': False, 'defaultFocusMinutes': 25}}))
env = dict(os.environ, PERCH_DATA=str(data), FOCUS_ENTRY_OUTPUT=output)
# Argument-domain override affects this probe only, never the user's system preferences.
subprocess.run([binary, '-AppleKeyboardUIMode', '3'], env=env, check=True, timeout=150)
root = pathlib.Path(output)
result = json.loads((root / 'results.json').read_text())
assert result['activation'] == 'real-own-process-AX-press-no-model-fallback'
assert result['lastRowKeyboardUndo'] == 'verified-own-process-NotchPanel'
assert result['captureTextUndo'] == 'native-keyboard-undo-redo-and-submit'
assert result['rowCustomActions'] == 'verified-native-handlers-exact-task'
assert result['taskActivation'] == 'window-right-click-tracked-NSMenu-item-action'
menu = json.loads((root / 'context-menu-trace.json').read_text())
assert menu['mechanism'] == result['taskActivation'] and not menu['timedOut']
assert any('Start focusing' in titles for titles in menu['menus'])
assert {row['defaultMinutes'] for row in result['metrics']} == {25, 40}
# Read the real persisted snapshot before deletion, not a reconstruction from view state.
saved = json.loads((root / 'linked-focus.json').read_text())
assert saved['focus']['state'] == 'running' and saved['focus']['limit'] == 720
assert saved['focus']['taskID'] == saved['tasks'][0]['id'] and saved['tasks'][0]['minutes'] == 12
# Deletion followed by Undo restores the task, but must not resurrect its running timer.
final = json.loads(data.read_text())
assert len(saved['tasks']) == len(final['tasks']) == 1
assert final['tasks'][0]['id'] == saved['tasks'][0]['id'] and final['tasks'][0]['minutes'] == 12
assert final.get('focus') is None or final['focus']['state'] != 'running'
print(json.dumps(result, indent=2))
print('PASS: persisted UI-started session, deletion, and Undo agree')
PY
