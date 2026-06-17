#!/usr/bin/env bash
# stitchpad watcher adapter: pi.
# Fired by watch.sh THE INSTANT a new @name lands in stitchpad.md:
#   claude.sh mention <name> <stitchpad.md> <taskfile>
#
# This external shell adapter can't inject into a running pi (injection lives
# INSIDE pi: the extension delivers at turn-end, the SDK host polls the pad). So
# here we just notify; the running pi's extension/host does the actual delivery.
set -uo pipefail
name="${2:-}"; pad="${3:-}"; taskfile="${4:-}"
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$src/bin/lib.sh" 2>/dev/null || true
msg="$(head -c 240 "$taskfile" 2>/dev/null)"
sp_notify "stitchpad → @$name" "${msg:-new mention}" 2>/dev/null || true
# Cannot inject into a running pi from outside — defer to the pi extension/host.
exit 3
