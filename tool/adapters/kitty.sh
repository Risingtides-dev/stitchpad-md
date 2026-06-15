#!/usr/bin/env bash
# stitchpad adapter: kitty (the universal wake).
#
# Every interactive agent — claude, codex, pi — runs in a kitty window. kitty's
# remote control writes text into a window it owns (it owns the pty, so the
# kernel permits it without root and without TIOCSTI, which macOS gates to root).
# This is the on-plan, no-API-bill external wake: the agent stays a normal
# interactive session (claude/codex draw from your subscription, not the metered
# Agent-SDK pool); we just nudge it to take a turn and read the pad.
#
# Called by the watcher as: kitty.sh mention <name> <stitchpad.md> <taskfile>
# Env: SP_TARGET = the agent's kitty address, captured at join as:
#        "<socket>@@<window_id>"  e.g. "unix:/tmp/kitty-thoth-675@@49"
#      (@@ not | — the roster is pipe-delimited, so | would be truncated.)
#      (kitty appends the instance PID to listen_on, and each window exposes its
#       own $KITTY_LISTEN_ON + $KITTY_WINDOW_ID — so the agent records its own.)
#      Back-compat: a bare number is treated as a window id on $KITTY_SOCKET.
#
# Requires (already in this kitty.conf): allow_remote_control socket-only (or yes).
set -uo pipefail
event="$1"; to="$2"; pad_md="$3"; taskfile="$4"
log="${SP_PAD_DIR:-.}/.state/adapter.kitty.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
[ "$event" = "mention" ] || exit 0

kitty_bin="$(command -v kitty 2>/dev/null || echo /Applications/kitty.app/Contents/MacOS/kitty)"
[ -x "$kitty_bin" ] || { echo "[$(ts)] kitty not found" >>"$log"; exit 1; }

target="${SP_TARGET:-}"
case "$target" in
  *"@@"*) sock="${target%%@@*}"; win="${target##*@@}" ;;          # socket|window_id (normal)
  ""|-)  echo "[$(ts)] no kitty target for @$to (agent must join from a kitty window)" >>"$log"; exit 1 ;;
  *)     sock="${KITTY_SOCKET:-${KITTY_LISTEN_ON:-}}"; win="$target" ;;  # bare id fallback
esac
[ -n "$sock" ] || { echo "[$(ts)] no kitty socket for @$to" >>"$log"; exit 1; }

# GUARD: never inject into a FOCUSED window — that's the one you're typing in, and
# send-text would interleave with your keystrokes. Skip; the mention stays
# unanswered (engagement gate), so the watcher retries on the next pad change once
# you've clicked away. Set STITCHPAD_FORCE_WAKE=1 to override.
if [ "${STITCHPAD_FORCE_WAKE:-0}" != "1" ]; then
  focused="$("$kitty_bin" @ --to "$sock" ls 2>/dev/null | python3 -c '
import sys,json
try:
  d=json.load(sys.stdin); w=sys.argv[1]
  print(any(str(win["id"])==w and win.get("is_focused") for o in d for t in o["tabs"] for win in t["windows"]))
except: print(False)' "$win" 2>/dev/null)"
  if [ "$focused" = "True" ]; then
    echo "[$(ts)] @$to window $win is focused (you're typing) — deferring wake" >>"$log"
    exit 0
  fi
fi

# Short, metacharacter-free nudge; the pad holds the detail, the agent reads it.
nudge="stitchpad: @$to you were pinged — read .stitchpad/stitchpad.md and reply with a line starting @whoever-pinged-you"

# Submit in two steps: send-text drops the line in the prompt, then a SEPARATE
# send-key enter actually submits it. A trailing \r in send-text does NOT submit
# in agent TUIs (claude/codex/pi use a custom keyboard mode) — it just pastes.
# send-key enter is a real keypress and submits across all three. (verified live)
if "$kitty_bin" @ --to "$sock" send-text --match "id:$win" -- "$nudge" 2>>"$log"; then
  sleep 0.3   # let the TUI register the pasted text before the Enter keypress
  "$kitty_bin" @ --to "$sock" send-key --match "id:$win" enter 2>>"$log"
  echo "[$(ts)] woke @$to via kitty (win $win @ $sock)" >>"$log"
else
  echo "[$(ts)] kitty send-text failed for @$to (win $win @ $sock)" >>"$log"; exit 1
fi
