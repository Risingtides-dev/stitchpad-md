#!/usr/bin/env bash
# stitchpad watcher adapter: codex.
# Fired by watch.sh THE INSTANT a new @name lands in stitchpad.md:
#   claude.sh mention <name> <stitchpad.md> <taskfile>
#
# Codex `pull` members are owned by the real Stop hook. The watcher must never
# hide a second headless `codex exec` lane behind that identity; doing so makes
# work happen outside the interactive terminal the operator is watching.
set -uo pipefail
name="${2:-}"; pad="${3:-}"; taskfile="${4:-}"
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$src/bin/lib.sh" 2>/dev/null || true
msg="$(head -c 240 "$taskfile" 2>/dev/null)"
sp_notify "stitchpad → @$name" "${msg:-new mention}" 2>/dev/null || true
# The Stop hook will deliver the pending markdown on the visible session's next
# turn boundary. Exit deferred so no watcher cursor is consumed.
exit 3
