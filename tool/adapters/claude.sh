#!/usr/bin/env bash
# stitchpad watcher adapter: claude.
# Fired by watch.sh THE INSTANT a new @name lands in stitchpad.md:
#   claude.sh mention <name> <stitchpad.md> <taskfile>
#
# A running claude TUI has no supported external-injection channel (no socket,
# no stdin into a live session — verified). So the instant-wake we CAN do for an
# interactive claude is: desktop notification now + the message is already on the
# pad, so claude's own Stop hook delivers it at its next turn-end. For an
# autonomous (non-TUI) claude, run it under a host that owns the loop instead.
set -uo pipefail
name="${2:-}"; pad="${3:-}"; taskfile="${4:-}"
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$src/bin/lib.sh" 2>/dev/null || true
msg="$(head -c 240 "$taskfile" 2>/dev/null)"
sp_notify "stitchpad → @$name" "${msg:-new mention}" 2>/dev/null || true
# Cannot inject into a live Claude TUI — defer to the Stop hook / host polling.
exit 3
