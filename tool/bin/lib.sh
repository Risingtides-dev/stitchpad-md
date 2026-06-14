#!/usr/bin/env bash
# stitchpad core library — sourced by every command/daemon/adapter.
# The whole system is: one markdown file (stitchpad.md) whose own header declares
# its roster, plus a generic watcher that fires each user's adapter on @mention.
#
# A pad is a directory with:
#   stitchpad.md   the markdown bus (roster block + messages)
#   stitchpad-git/ isolated git history (one commit per post)
#   .state/        runtime flags/counters/inboxes (gitignored)
#
# Roster lives INSIDE stitchpad.md as a fenced ```roster block:
#   name | adapter | wake | target
# wake = push (daemon spawns them) | pull (daemon flags+notifies; they read later)

set -uo pipefail

# STITCHPAD_HOME is the checkout's tool/ dir (holds bin/ + adapters/). If the
# caller already resolved BIN_DIR (via the symlink-safe header), derive HOME from
# it so install-by-symlink works without anyone exporting STITCHPAD_HOME.
if [ -z "${STITCHPAD_HOME:-}" ] && [ -n "${BIN_DIR:-}" ]; then
  STITCHPAD_HOME="$(cd -P "$BIN_DIR/.." && pwd)"
fi
STITCHPAD_HOME="${STITCHPAD_HOME:-$HOME/.stitchpad}"
ADAPTER_DIR="$STITCHPAD_HOME/adapters"

# ── Pad resolution ──────────────────────────────────────────────────
# Find the pad dir: explicit $PAD_DIR, else nearest .stitchpad up the tree.
sp_find_pad() {
  if [ -n "${PAD_DIR:-}" ]; then echo "$PAD_DIR"; return; fi
  local d="${1:-$PWD}"
  while [ "$d" != "/" ]; do
    [ -d "$d/.stitchpad" ] && { echo "$d/.stitchpad"; return; }
    d="$(dirname "$d")"
  done
  return 1
}

sp_init_paths() {
  PAD_DIR="$(sp_find_pad "${1:-$PWD}")" || { echo "no .stitchpad found (run: stitchpad init)" >&2; return 1; }
  PAD_MD="$PAD_DIR/stitchpad.md"
  PAD_GIT="$PAD_DIR/stitchpad-git"
  PAD_STATE="$PAD_DIR/.state"
  mkdir -p "$PAD_STATE"
}

# ── Atomic pad mutation lock ─────────────────────────────────────────
# Multiple agents may say/join the same pad concurrently. stitchpad.md is mutated
# by bare appends (say) and read-rewrite (join); without serialization those race
# (interleaved lines / lost updates). mkdir is atomic on every POSIX fs, so we use
# a lock DIR as the mutex — no flock dependency (macOS lacks it). Auto-breaks a
# stale lock so a crashed writer can't wedge the pad forever.
SP_LOCK_TIMEOUT="${SP_LOCK_TIMEOUT:-5}"   # seconds to wait for the lock
SP_LOCK_STALE="${SP_LOCK_STALE:-30}"      # seconds before a held lock is "stale"
_SP_LOCK_DIR=""

sp_lock() {
  local lock="$PAD_STATE/.lock" waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    # Break a stale lock (holder died without releasing).
    if [ -d "$lock" ]; then
      local age now mtime
      now=$(date +%s)
      mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now")
      age=$(( now - mtime ))
      if [ "$age" -ge "$SP_LOCK_STALE" ]; then rmdir "$lock" 2>/dev/null || true; continue; fi
    fi
    waited=$(( waited + 1 ))
    [ "$waited" -ge $(( SP_LOCK_TIMEOUT * 10 )) ] && { echo "stitchpad: pad busy (lock timeout)" >&2; return 1; }
    sleep 0.1
  done
  _SP_LOCK_DIR="$lock"
  # Release on any exit so a killed writer doesn't wedge the pad.
  trap 'sp_unlock' EXIT INT TERM
  return 0
}

sp_unlock() {
  [ -n "$_SP_LOCK_DIR" ] && rmdir "$_SP_LOCK_DIR" 2>/dev/null || true
  _SP_LOCK_DIR=""
}

# Isolated git wrapper: history of just stitchpad.md, separate from project repo.
sgit() { git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" "$@"; }

sp_commit() {
  local msg="$1"
  sgit rev-parse --git-dir >/dev/null 2>&1 || return 0
  sgit diff --quiet -- stitchpad.md 2>/dev/null && return 0
  sgit add stitchpad.md 2>/dev/null || true
  sgit commit -q -m "$msg" 2>/dev/null || true
}

# ── Roster parsing (the magic: roster is IN the markdown) ────────────
# Emits "name|adapter|wake|target" per participant from the ```roster fence.
sp_roster() {
  awk '
    /^```roster/ { inblk=1; next }
    /^```/       { inblk=0 }
    inblk {
      line=$0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "" || line ~ /^#/) next
      n=split(line, f, /[ \t]*\|[ \t]*/)
      if (n>=2) {
        name=f[1]; adapter=f[2];
        wake=(n>=3?f[3]:"pull"); target=(n>=4?f[4]:"-");
        gsub(/^[ \t]+|[ \t]+$/, "", name)
        print name "|" adapter "|" wake "|" target
      }
    }
  ' "$PAD_MD"
}

# Look up one field for a user. sp_user_field <name> <adapter|wake|target>
sp_user_field() {
  local who="$1" field="$2"
  sp_roster | awk -F'|' -v w="$who" -v f="$field" '
    tolower($1)==tolower(w) {
      if (f=="adapter") print $2;
      else if (f=="wake") print $3;
      else if (f=="target") print $4;
      exit
    }'
}

sp_user_exists() { [ -n "$(sp_user_field "$1" adapter)" ]; }

# ── @mention detection (a TASK line STARTS with @name) ───────────────
# Count lines addressed TO <name> — line begins with @name (allow md punctuation).
sp_count_to() {
  local who="$1"
  local n
  n=$(grep -icE "^[ >*_-]*@${who}([^a-z0-9_-]|$)" "$PAD_MD" 2>/dev/null) || true
  echo "${n:-0}"
}

# Extract the latest message block addressed to <name>: from the last "## " header
# owning an @name line, through EOF.
sp_latest_to() {
  local who="$1"
  awk -v who="$who" '
    /^##/ { sub_start=NR }
    { lines[NR]=$0 }
    tolower($0) ~ ("^[ >*_-]*@" tolower(who)) { last=sub_start }
    END { if (last) for (i=last;i<=NR;i++) print lines[i] }
  ' "$PAD_MD"
}

# ── Notifications ────────────────────────────────────────────────────
sp_notify() {
  local title="$1" msg="$2" sound="${3:-Glass}"
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "$title" -message "$msg" -sound "$sound" 2>/dev/null || true
  else
    osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\" sound name \"$sound\"" 2>/dev/null || true
  fi
}
