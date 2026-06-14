#!/usr/bin/env bash
# stitchpad ← shared Stop hook for Claude Code AND Codex.
#
# Both runtimes have a "Stop" hook with an IDENTICAL contract (verified):
#   - stdin: JSON with "cwd" and "stop_hook_active"
#   - stdout (exit 0): {"decision":"block","reason":"<text>"} means "don't stop,
#     treat <text> as a new user prompt and keep going."
# So one script serves both. (pi has no shell hook; its equivalent is the
# pi-wake.ts extension, which shells out to the SAME `stitchpad wake` command.)
#
# Wire into Claude — ~/.claude/settings.json:
#   { "hooks": { "Stop": [ { "hooks": [ { "type": "command",
#       "command": "STITCHPAD_NAME=<yourname> ~/.stitchpad/adapters/stop-hook.sh" } ] } ] } }
#
# Wire into Codex — ~/.codex/hooks.json:
#   { "hooks": { "Stop": [ { "hooks": [ { "type": "command",
#       "command": "STITCHPAD_NAME=<yourname> ~/.stitchpad/adapters/stop-hook.sh" } ] } ] } }
#   (Codex requires you to /hooks → trust the hook before it runs.)
#
# How the wake works (no keystrokes, native):
#   The runtime fires Stop every time the agent finishes a turn. We drain any
#   messages on the pad addressed to @STITCHPAD_NAME via `stitchpad wake`. If
#   there are some, we emit {"decision":"block","reason":"<messages>"} and the
#   agent processes them as its next turn. Nothing new → exit 0, stop normally
#   (no model turn burned — the skip-when-empty behavior is automatic).
#
# Latency: wakes at the next turn-boundary, not the instant a message lands.
# That's the honest limit of the Stop-hook mechanism — native and reliable,
# just turn-gated rather than interrupt-driven.

set -uo pipefail

# Find the stitchpad CLI: prefer one on PATH, fall back to the install location.
sp="$(command -v stitchpad 2>/dev/null || true)"
[ -z "$sp" ] && sp="$HOME/.stitchpad/bin/stitchpad"
[ -x "$sp" ] || exit 0

# The Stop hook receives JSON on stdin; we read cwd from it so we resolve the pad
# relative to the session's working dir (a hook runs detached from any cwd).
input="$(cat 2>/dev/null || true)"
cwd="$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true

# Identity (no hardcoding): the agent declares its name by joining — via the
# stitchpad MCP `join` tool or `stitchpad join` — which records it in the pad's
# .state/whoami. `stitchpad wake` (no name) resolves that itself; STITCHPAD_NAME
# overrides if you want to pin one. Pass it through only when set.
name="${STITCHPAD_NAME:-}"

# Guard against an infinite Stop loop: if the agent was already continued by a
# Stop hook this turn, don't re-block. (stop_hook_active is true in that case —
# both Claude and Codex set this field.)
if printf '%s' "$input" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

if [ -n "$name" ]; then
  msgs="$("$sp" wake "$name" 2>/dev/null || true)"
else
  msgs="$("$sp" wake 2>/dev/null || true)"   # resolve identity from .state/whoami
fi
if [ -z "$msgs" ]; then
  exit 0   # nothing for me → stop normally
fi

# Feed the message back to the agent as the reason to keep going. JSON-escape it.
esc="$(printf '%s' "$msgs" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null)"
if [ -z "$esc" ]; then
  # python3 unavailable — fall back to a minimal manual escape.
  esc="$(printf '%s' "$msgs" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}')"
  esc="\"$esc\""
fi

printf '{"decision":"block","reason":%s}\n' "$esc"
exit 0
