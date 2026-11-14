#!/usr/bin/env bash
# Run production WorkspaceView outside the bundled XCTest command-line tool.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { printf '%s\n' 'This UI probe requires macOS.' >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: check_workspace_navigation.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
PROBE=$(mktemp -d "$OUT/build.XXXXXX")
trap 'rm -rf "$PROBE"' EXIT
cp "$ROOT/Package.swift" "$PROBE/"
cp -R "$ROOT/Sources" "$ROOT/Tests" "$PROBE/"
cp "$ROOT/Tests/PerchAppTests/WorkspaceBandProbe.swift" "$PROBE/Sources/Perch/main.swift"
printf '\nawait runWorkspaceBandProbe()\n' >> "$PROBE/Sources/Perch/main.swift"
python3 - "$PROBE" "$OUT" <<'PY'
import os
import pathlib
import subprocess
import sys

package, output = sys.argv[1:]
subprocess.run([
    'swift', 'build', '--jobs', '2', '-Xswiftc', '-DPERCH_TESTING',
    '-Xswiftc', '-enable-testing', '--package-path', package,
    '-c', 'debug', '--product', 'Perch',
], check=True, timeout=300)
bin_path = subprocess.check_output([
    'swift', 'build', '--show-bin-path', '--package-path', package, '-c', 'debug',
], text=True, timeout=30).strip()
# Each Swift fixture creates and verifies a fresh synthetic planner, then removes it.
# No LaunchServices registration, application install or global defaults change.
subprocess.run([
    str(pathlib.Path(bin_path) / 'Perch'), '-AppleKeyboardUIMode', '3',
], env=dict(os.environ, RUNNER_TEMP=output), check=True, timeout=120)
PY
