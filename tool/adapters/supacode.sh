#!/usr/bin/env bash
# stitchpad adapter: supacode (Ghostty-based agent terminal).
#
# Same contract as kitty.sh — called by the watcher as:
#   supacode.sh mention <name> <stitchpad.md> <taskfile>
# Env: SP_TARGET = the agent's supacode address "<tab_uuid>@@<surface_uuid>"
#      (mirrors kitty's socket@@window; @@ because the roster is pipe-delimited).
#      A new tab's first surface UUID == the tab UUID.
#
# WHY supacode is a clean fit (verified against source github.com/supabitapp/supacode):
#   - wake = `supacode surface focus -t <tab> -s <surface> -i "<nudge>"` — ONE call
#     that injects AND runs the command (no send-text+enter two-step; ~0.024s).
#   - identity is the UUID we self-assign at spawn (-n <uuid>), so there's no
#     title-drift class of bug — we target a handle we chose, not a mutable title.
#   - colors/title are OSC escapes (Ghostty: truecolor + OSC 2/11/4), painted by
#     the launcher at spawn, not by this adapter.
#   - the CLI "Timed out waiting for response" on create/focus is COSMETIC: the
#     action is a fire-and-forget deeplink that still lands; we ignore nonzero rc.
set -uo pipefail
event="$1"; to="$2"; pad_md="$3"; taskfile="$4"
# SP_PAD_DIR may be the project root (contains .stitchpad/) or the pad dir itself.
pad_root="${SP_PAD_DIR:-.}"
if [ -f "$pad_root/stitchpad.md" ]; then
  pad_dir="$pad_root"
elif [ -d "$pad_root/.stitchpad" ]; then
  pad_dir="$pad_root/.stitchpad"
else
  pad_dir=".stitchpad"
fi
mkdir -p "$pad_dir/.state" 2>/dev/null || true
log="$pad_dir/.state/adapter.supacode.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
[ "$event" = "mention" ] || exit 0

sc_bin="$(command -v supacode 2>/dev/null || echo /Applications/Supacode.app/Contents/Resources/bin/supacode)"
[ -x "$sc_bin" ] || { echo "[$(ts)] supacode not found" >>"$log"; exit 1; }
# zmx is the session multiplexer Supacode wraps every surface's shell in. We wake
# THROUGH it, not through `supacode surface focus -i` — the supacode CLI inserts
# text but its focusAndInsertText path does NOT submit for TUI agents (verified
# bug). `zmx send <session> <text\n>` is a RAW PTY write that DOES submit, and the
# session name is deterministic: `supa-<surface_uuid>` — the UUID we self-assign at
# spawn, so no discovery. `zmx history` also reads the buffer back (delivery proof).
zmx_bin="/Applications/Supacode.app/Contents/Resources/zmx/zmx"
[ -x "$zmx_bin" ] || { echo "[$(ts)] zmx not found at $zmx_bin" >>"$log"; exit 1; }

# Target: "<tab>@@<surface>". A bare value (no @@) is treated as both (new-tab case
# where surface==tab). Empty/'-' → resolve below.
target="${SP_TARGET:-}"
case "$target" in
  *"@@"*) tab="${target%%@@*}"; surface="${target##*@@}" ;;
  "-"|"") tab=""; surface="" ;;
  *)      tab="$target"; surface="$target" ;;     # bare uuid → tab==surface
esac

# VALIDATE the stored UUID against live zmx sessions (a restart/outage invalidates
# old surfaces). Do NOT use `supacode tab list` here: the watcher runs outside a
# Supacode surface and the CLI requires SUPACODE_WORKTREE_ID/-w, so it falsely
# reports missing worktree. zmx is the actual wake substrate and has global list.
if [ -n "$surface" ]; then
  _sess_check="supa-$(printf '%s' "$surface" | tr 'A-Z' 'a-z')"
  if ! "$zmx_bin" list --short 2>/dev/null | grep -Fxq "$_sess_check"; then
    echo "[$(ts)] stored zmx session $_sess_check not live — clearing for self-heal" >>"$log"
    tab=""; surface=""
  fi
fi

# SELF-HEAL: supacode surfaces have no title to match on, so unlike kitty there's no
# name-based recovery. The authoritative handle is the UUID assigned at spawn (stored
# in SP_TARGET / the roster). If it's gone, we can't guess which anonymous surface is
# this agent — surface the failure rather than wake a random one. The launcher
# (stitchpad-team) re-assigns a known UUID on respawn, which is the real recovery path.
if [ -z "$tab" ] || [ -z "$surface" ]; then
  echo "[$(ts)] no live supacode target for @$to (stored UUID gone; respawn via launcher to re-bind)" >>"$log"
  exit 1
fi

# Canonical wake message from the CLI — same text the stop-hook delivers.
nudge="$(STITCHPAD_NAME="$to" stitchpad wake "$to" --peek 2>/dev/null)"
[ -z "$nudge" ] && nudge="stitchpad: @$to you were pinged — read .stitchpad/stitchpad.md and reply"
# SANITIZE — critical because `zmx send` is a RAW PTY write that submits immediately
# (no visible paste, higher blast radius than kitty's send-text). The nudge is built
# from `wake --peek`, whose snippet carries pad-BODY text (untrusted). Strip ALL
# control bytes (incl. ESC \033 for escape-sequence injection AND \r for embedded
# second-command injection), then collapse whitespace. Defense-in-depth at the pty
# boundary: even if a crafted pad message reaches the snippet, only printable text
# lands in the session. (mark's zmx trust-boundary review.)
nudge="$(printf '%s' "$nudge" | LC_ALL=C tr -d '\000-\037\177' | tr -s ' ')"

# Ensure the woken agent's heartbeat ticker is running (cold-wake gap — same fix as
# kitty.sh: a session that hasn't run a CLI yet has no alive.<name> and decays in 90s).
# The -f "$pad_dir/stitchpad.md" guard below also covers mark's pad_dir-default note:
# if resolution fell through to the bare ".stitchpad" default and no real pad is there,
# the file check fails and we skip the spawn rather than logging to the wrong place.
if [ -n "$pad_dir" ] && [ -f "$pad_dir/stitchpad.md" ]; then
  ( cd "$(dirname "$pad_dir")" && STITCHPAD_NAME="$to" stitchpad heartbeat start "$to" >/dev/null 2>&1 ) &
  echo "[$(ts)] ensured heartbeat for @$to" >>"$log"
fi

# WAKE via zmx raw-pty write — the session name is `supa-<surface_uuid>` (lowercased).
# The trailing carriage return is the submit (a real Enter to the pty), which is the
# part the supacode CLI's insert path drops. zmx docs are explicit: send is raw and
# caller appends \r to execute. One call, submits across plain shells AND TUI agents.
# We focus the surface first (cosmetic — brings it visible) then send.
sess="supa-$(printf '%s' "$surface" | tr 'A-Z' 'a-z')"
"$sc_bin" surface focus -t "$tab" -s "$surface" >/dev/null 2>&1   # bring visible (rc ignored)
if printf '%s\r' "$nudge" | "$zmx_bin" send "$sess" >>"$log" 2>&1; then
  echo "[$(ts)] woke @$to via zmx send ($sess)" >>"$log"
  exit 0
else
  echo "[$(ts)] zmx send failed for @$to ($sess) — session may be dead; respawn via launcher" >>"$log"
  exit 1
fi
