#!/usr/bin/env bash
# remote_test.sh [swift test args...]
# Runs `swift test` for the current worktree on a remote Linux build host, so local RAM
# stays free for agents. Falls back to a local run if the host is unset or unreachable.
#
# The host comes from PERCH_BUILD_HOST (for example user@host). There is no default.
# Keep the real value out of git: put `export PERCH_BUILD_HOST=...` in .envrc.local
# (gitignored) at the repo root. This script sources that file if it exists.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
[ -f "$ROOT/.envrc.local" ] && . "$ROOT/.envrc.local"
HOST="${PERCH_BUILD_HOST:-}"
NAME="$(basename "$ROOT")-$(git rev-parse --abbrev-ref HEAD | tr / -)"
SWIFT='$HOME/swift/swift-6.4.2-RELEASE-ubuntu22.04/usr/bin'
if [ -n "$HOST" ] && timeout 8 ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" true 2>/dev/null; then
  ssh -o BatchMode=yes "$HOST" "mkdir -p ~/perch-builds/$NAME"
  rsync -az --delete --exclude .build --exclude .git --exclude dist --exclude .worktrees --exclude .envrc.local "$ROOT/" "$HOST:~/perch-builds/$NAME/"
  ssh -o BatchMode=yes "$HOST" "cd ~/perch-builds/$NAME && export PATH=$SWIFT:\$PATH && swift test $*"
else
  [ -z "$HOST" ] && echo "PERCH_BUILD_HOST not set, running locally" >&2 || echo "build host unreachable, running locally" >&2
  export PATH="${PERCH_LOCAL_SWIFT:-/ephemeral/swift/swift-6.4.2-RELEASE-ubuntu22.04/usr/bin}:$PATH"; cd "$ROOT" && swift test "$@"
fi
