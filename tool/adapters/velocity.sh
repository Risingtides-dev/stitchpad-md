#!/usr/bin/env bash
# stitchpad wake adapter for Velocity (Ghostty/zmx terminal surfaces).
#
# Velocity owns the full surface stack: the CLI (surface focus/send-key/list),
# zmx as the session multiplexer, and the surface env it injects into each shell.
#
# Called by the watcher as:  velocity.sh mention <name> <stitchpad.md> <taskfile>
# Env: SP_TARGET = "<worktree>@@<tab_uuid>@@<surface_uuid>" (roster is pipe-delimited).
#
# Wake = `velocity surface focus ... -i "<nudge>"` to insert the prompt, then
# `velocity surface send-key ... --key Enter` to submit. The CLI "Timed out
# waiting for response" on focus is COSMETIC (fire-and-forget deeplink) — we
# ignore nonzero rc.
set -uo pipefail

export STITCHPAD_SURFACE_APP="${STITCHPAD_SURFACE_APP:-velocity}"
export STITCHPAD_SURFACE_CLI="${STITCHPAD_SURFACE_CLI:-/Applications/Velocity.app/Contents/Resources/bin/velocity}"
export STITCHPAD_SURFACE_ZMX="${STITCHPAD_SURFACE_ZMX:-/Applications/Velocity.app/Contents/Resources/zmx/zmx}"

event="$1"; to="$2"; pad_md="$3"; taskfile="$4"
surface_app="${STITCHPAD_SURFACE_APP:-velocity}"
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
log="$pad_dir/.state/adapter.$surface_app.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
[ "$event" = "mention" ] || exit 0

if [ -n "${STITCHPAD_SURFACE_CLI:-}" ]; then
  sc_bin="$STITCHPAD_SURFACE_CLI"
else
  sc_bin="$(command -v velocity 2>/dev/null || echo /Applications/Velocity.app/Contents/Resources/bin/velocity)"
fi
[ -x "$sc_bin" ] || { echo "[$(ts)] $surface_app CLI not found at $sc_bin" >>"$log"; exit 1; }
# zmx is the session multiplexer the host app wraps every surface's shell in. We use
# it only to validate that a stored target still exists; prompt delivery goes
# through the configured surface CLI commands.
zmx_bin="${STITCHPAD_SURFACE_ZMX:-/Applications/Velocity.app/Contents/Resources/zmx/zmx}"
[ -x "$zmx_bin" ] || { echo "[$(ts)] zmx not found at $zmx_bin" >>"$log"; exit 1; }

# Target now supports 3-part format: "<worktree>@@<tab>@@<surface>" (new)
# or 2-part: "<tab>@@<surface>" (legacy, worktree from SP_WORKTREE env).
target="${SP_TARGET:-}"
# Resolve worktree from $SP_WORKTREE env, or sidecar .state/worktree.<name>.
_worktree="${SP_WORKTREE:-}"
[ -z "$_worktree" ] && [ -f "$pad_dir/.state/worktree.$to" ] && _worktree="$(cat "$pad_dir/.state/worktree.$to" 2>/dev/null || true)"
case "$target" in
  *"@@"*"@@"*)
    # 3-part: worktree@@tab@@surface
    _worktree="${target%%@@*}"
    _rest="${target#*@@}"
    tab="${_rest%%@@*}"
    surface="${_rest##*@@}"
    ;;
  *"@@"*)
    # 2-part: tab@@surface (worktree from SP_WORKTREE)
    tab="${target%%@@*}"
    surface="${target##*@@}"
    ;;
  "-"|"")
    tab=""; surface=""
    ;;
  *)
    tab="$target"; surface="$target"  # bare uuid → tab==surface
    ;;
esac
case "$_worktree" in
  folder:*) _worktree="${_worktree#folder:}" ;;
esac

normalize_uuid() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

strip_ansi() {
  LC_ALL=C tr -d '\033' | sed -E 's/\[[0-9;]*[A-Za-z]//g'
}

encode_worktree_path() {
  python3 - "$1" <<'PY'
import os
import sys
import urllib.parse

path = os.path.realpath(sys.argv[1])
if not path.endswith("/"):
    path += "/"
print(urllib.parse.quote(path, safe=""))
PY
}

infer_worktree() {
  local root encoded
  root="$(cd "$(dirname "$pad_dir")" 2>/dev/null && pwd -P)" || return 1
  encoded="$(encode_worktree_path "$root" 2>/dev/null || true)"
  [ -n "$encoded" ] || return 1
  if "$sc_bin" worktree list 2>/dev/null | strip_ansi | grep -Fxq "$encoded"; then
    printf '%s\n' "$encoded"
    return 0
  fi
  if "$sc_bin" worktree list 2>/dev/null | strip_ansi | grep -Fxq "folder:$encoded"; then
    printf 'folder:%s\n' "$encoded"
    return 0
  fi
  return 1
}

worktree_tabs() {
  "$sc_bin" tab list -w "$1" 2>/dev/null | strip_ansi
}

worktree_surfaces() {
  "$sc_bin" surface list -w "$1" -t "$2" 2>/dev/null | strip_ansi
}

resolve_worktree() {
  local wt="$1" inferred
  if [ -n "$wt" ] && worktree_tabs "$wt" | grep -q .; then
    printf '%s\n' "$wt"
    return 0
  fi
  inferred="$(infer_worktree 2>/dev/null || true)"
  if [ -n "$inferred" ] && worktree_tabs "$inferred" | grep -q .; then
    printf '%s\n' "$inferred"
    return 0
  fi
  return 1
}

resolve_tab_for_surface() {
  local wt="$1" current_tab="$2" target_surface="$3" target_uc tab_candidate surf_candidate
  target_uc="$(normalize_uuid "$target_surface")"
  if [ -n "$current_tab" ]; then
    while IFS= read -r surf_candidate; do
      [ -n "$surf_candidate" ] || continue
      if [ "$(normalize_uuid "$surf_candidate")" = "$target_uc" ]; then
        printf '%s\n' "$current_tab"
        return 0
      fi
    done < <(worktree_surfaces "$wt" "$current_tab")
  fi
  while IFS= read -r tab_candidate; do
    [ -n "$tab_candidate" ] || continue
    while IFS= read -r surf_candidate; do
      [ -n "$surf_candidate" ] || continue
      if [ "$(normalize_uuid "$surf_candidate")" = "$target_uc" ]; then
        printf '%s\n' "$tab_candidate"
        return 0
      fi
    done < <(worktree_surfaces "$wt" "$tab_candidate")
  done < <(worktree_tabs "$wt")
  return 1
}

# Validate the stored UUID against live zmx sessions (a restart/outage invalidates
# old surfaces). zmx is a quick liveness guard; below we also resolve the owning
# tab because a surface can live under a different tab than the roster recorded.
# zmx names each surface's session "velocity-<surface-uuid>".
if [ -n "$surface" ]; then
  _sess_check="velocity-$(printf '%s' "$surface" | tr 'A-Z' 'a-z')"
  if ! "$zmx_bin" list --short 2>/dev/null | grep -Fxq "$_sess_check"; then
    echo "[$(ts)] stored zmx session $_sess_check not live — clearing for self-heal" >>"$log"
    tab=""; surface=""
  fi
fi

# SELF-HEAL: the authoritative handle is the surface UUID captured at join (stored in
# SP_TARGET / the roster). If it's gone, we can't guess which anonymous surface is this
# agent — surface the failure rather than wake a random one. Rejoining from the live
# surface re-binds the UUID, which is the real recovery path.
if [ -z "$tab" ] || [ -z "$surface" ]; then
  echo "[$(ts)] no live $surface_app target for @$to (stored UUID gone; respawn via launcher to re-bind)" >>"$log"
  exit 1
fi

if ! _worktree="$(resolve_worktree "$_worktree")"; then
  echo "[$(ts)] no $surface_app worktree for @$to (raw_worktree='${SP_WORKTREE:-}', sidecar='$(cat "$pad_dir/.state/worktree.$to" 2>/dev/null || true)')" >>"$log"
  exit 1
fi

if ! tab="$(resolve_tab_for_surface "$_worktree" "$tab" "$surface")"; then
  echo "[$(ts)] surface $surface is live in zmx but not registered in $surface_app worktree $_worktree" >>"$log"
  exit 1
fi

printf '%s' "$_worktree" > "$pad_dir/.state/worktree.$to" 2>/dev/null || true

# Canonical wake message from the CLI — same text the stop-hook delivers.
nudge="$(STITCHPAD_PAD_DIR="$pad_dir" STITCHPAD_NAME="$to" stitchpad wake "$to" --peek 2>/dev/null)"
[ -z "$nudge" ] && nudge="stitchpad: @$to you were pinged — read .stitchpad/stitchpad.md and reply"
# SANITIZE — critical because `zmx send` is a RAW PTY write and the delivery below
# sends a discrete CR to submit. The nudge is built
# from `wake --peek`, whose snippet carries pad-BODY text (untrusted). Strip ALL
# control bytes (incl. ESC \033 for escape-sequence injection AND \r for embedded
# second-command injection), then collapse whitespace. Defense-in-depth at the pty
# boundary: even if a crafted pad message reaches the snippet, only printable text
# lands in the session. (mark's zmx trust-boundary review.)
nudge="$(printf '%s' "$nudge" | LC_ALL=C tr -d '\000-\037\177' | tr -s ' ')"

# Ensure the woken agent's heartbeat ticker is running (cold-wake gap: a session that
# hasn't run a CLI yet has no alive.<name> and decays in 90s).
# The -f "$pad_dir/stitchpad.md" guard below also covers mark's pad_dir-default note:
# if resolution fell through to the bare ".stitchpad" default and no real pad is there,
# the file check fails and we skip the spawn rather than logging to the wrong place.
# NOT backgrounded (`( … ) &`): heartbeat start forks+disowns its own ticker and
# returns immediately. Backgrounding it puts the ticker in this adapter's process
# group, reaped the instant the adapter exits (<1s) → agent decays anyway. Foreground
# spawn lets the internal disown outlive the short-lived adapter.
if [ -n "$pad_dir" ] && [ -f "$pad_dir/stitchpad.md" ]; then
  ( cd "$(dirname "$pad_dir")" && STITCHPAD_NAME="$to" stitchpad heartbeat start "$to" >/dev/null 2>&1 )
  echo "[$(ts)] ensured heartbeat for @$to" >>"$log"
fi

# FOCUS-GUARD: do not clobber the prompt box while the human is actively typing in
# the target surface. If this surface is the FOCUSED one, a `focus -i` would overwrite
# whatever's parked in the composer mid-keystroke. Defer instead (exit 3 = "not
# delivered, re-fire later" — the watcher does NOT consume the mention, so the wake
# lands once the surface is no longer focused). STITCHPAD_FORCE_WAKE=1 bypasses this
# (used for agents whose surface is legitimately the focused one, e.g. an orchestrator).
if [ "${STITCHPAD_FORCE_WAKE:-0}" != "1" ]; then
  _focused="$("$sc_bin" surface list -w "$_worktree" -t "$tab" -f 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
  _this="$(printf '%s' "$surface" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
  if [ -n "$_focused" ] && [ "$_focused" = "$_this" ]; then
    echo "[$(ts)] deferred @$to — surface $surface is focused (user typing); will re-fire when unfocused" >>"$log"
    exit 3
  fi
fi

# Write the nudge to file as a breadcrumb, but do not treat file-only delivery as
# success. Success means the prompt is submitted into the live Velocity surface.
_nudge_file="$pad_dir/.state/nudge.$to"
mkdir -p "$(dirname "$_nudge_file")" 2>/dev/null || true
printf '%s' "$nudge" > "$_nudge_file"

_session="velocity-$(printf '%s' "$surface" | tr 'A-Z' 'a-z')"

# PRIMARY — silent PTY write via zmx. This writes raw input straight into the
# target session's pty WITHOUT focusing the surface, so a wake to a background
# agent never steals smaths's keyboard or moves his focus. This is the whole point:
# agent wakes run independently of the human's keyboard.
#
# CRITICAL: the text and the Enter MUST be SEPARATE zmx sends with a beat between.
# A single `\025<text>\r` burst is delivered as one PTY chunk and the coding TUIs
# (Claude/codex) treat a fast burst ending in CR as a *paste* — the line parks in
# the composer unsubmitted (smaths's "it was sitting in the input"). Three discrete
# writes — clear, text, then a standalone CR — make the final \r register as a real
# Enter keypress, which submits and triggers the agent's turn. Verified live.
_zmx_ok=1
printf '\025' | "$zmx_bin" send "$_session" >/dev/null 2>>"$log" || _zmx_ok=0
sleep 0.3
printf '%s' "$nudge" | "$zmx_bin" send "$_session" >/dev/null 2>>"$log" || _zmx_ok=0
sleep 0.5
printf '\r' | "$zmx_bin" send "$_session" >/dev/null 2>>"$log" || _zmx_ok=0
if [ "$_zmx_ok" = 1 ]; then
  echo "[$(ts)] woke @$to via zmx PTY write (silent, no focus steal) (w=$_worktree tab=$tab surface=$surface)" >>"$log"
  exit 0
fi
zmx_rc=1

# FALLBACK — only if the silent PTY write failed. This path DOES focus the surface
# (steals keyboard briefly), so it's last-resort. The focus-guard above already
# bailed if the human is actively in this surface, so this won't fire mid-typing.
echo "[$(ts)] zmx PTY write failed (rc=$zmx_rc) for @$to — escalating to focus path" >>"$log"
printf '\025' | "$zmx_bin" send "$_session" >/dev/null 2>>"$log" || true
if "$sc_bin" surface focus -w "$_worktree" -t "$tab" -s "$surface" -i "$nudge" >>"$log" 2>&1; then
  focus_rc=0
else
  focus_rc=$?
fi
sleep 0.2
if "$sc_bin" surface send-key -w "$_worktree" -t "$tab" -s "$surface" --key Enter >>"$log" 2>&1; then
  echo "[$(ts)] woke @$to via focus+send-key fallback (w=$_worktree tab=$tab surface=$surface focus_rc=$focus_rc)" >>"$log"
  exit 0
fi
key2_rc=$?

echo "[$(ts)] $surface_app send-key failed for @$to (w=$_worktree tab=$tab surface=$surface focus_rc=$focus_rc key2_rc=$key2_rc); wrote file breadcrumb only ($_nudge_file)" >>"$log"
exit 1
