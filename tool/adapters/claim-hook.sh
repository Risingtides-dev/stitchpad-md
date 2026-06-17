#!/usr/bin/env bash
# stitchpad ← PreToolUse-hook shim for Claude Code. STABLE: all logic lives in
# `stitchpad claim-hook`, so this file's hash never changes (trust once via /hooks,
# edit the CLI freely forever) — same design as stop-hook.sh.
#
# Wire it in ~/.claude/settings.json with a Write|Edit matcher:
#   { "hooks": { "PreToolUse": [ { "matcher": "Write|Edit|MultiEdit",
#       "hooks": [ { "type": "command",
#         "command": "/Users/you/.stitchpad/adapters/claim-hook.sh" } ] } ] } }
# The runtime pipes its PreToolUse JSON {tool_name, tool_input:{file_path}, cwd}
# to our stdin; we forward it to the CLI, which leases the file via `stitchpad
# claim` and emits a PreToolUse deny if someone else holds a fresh lease.
sp="$(command -v stitchpad 2>/dev/null || true)"
[ -z "$sp" ] && sp="$HOME/.stitchpad/bin/stitchpad"
[ -x "$sp" ] || exit 0   # no CLI → don't block writes (fail-open, ponytail: availability > enforcement if uninstalled)
exec "$sp" claim-hook
