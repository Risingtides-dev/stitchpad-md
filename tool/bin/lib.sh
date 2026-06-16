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
  mkdir -p "$PAD_STATE/sessions"
}

# ── Identity ─────────────────────────────────────────────────────────
# Identity is bound to the agent's SESSION, declared once via the MCP `join` tool
# (which calls `stitchpad bind-session <id> <name>`, writing .state/sessions/<id>).
# Resolution order:
#   1. explicit STITCHPAD_NAME      (the hook may pin it; tests use it)
#   2. .state/sessions/$STITCHPAD_SESSION   (the MCP-written session record)
# The hook exports STITCHPAD_SESSION from its Stop-payload session_id, so it
# resolves the SAME name the MCP bound. No shared whoami → no impersonation: a
# session can only ever resolve to the name it joined with.
sp_me() {
  if [ -n "${STITCHPAD_NAME:-}" ]; then echo "$STITCHPAD_NAME"; return; fi
  local sid="${STITCHPAD_SESSION:-}"
  if [ -n "$sid" ] && [ -f "$PAD_STATE/sessions/$sid" ]; then
    cat "$PAD_STATE/sessions/$sid" 2>/dev/null; return
  fi
  # Window-id resolution: each kitty window is unique and stable, and the roster
  # records each agent's window as "...@@<window_id>". A process that knows its own
  # KITTY_WINDOW_ID can therefore find its name unambiguously — no shared state.
  # This is what keeps codex/pi agents (no session id) from colliding on whoami:
  # without it they all fell through to the single whoami file and posted as
  # whoever joined last (ernie's posts landing as @Jill/@larry).
  if [ -n "${KITTY_WINDOW_ID:-}" ]; then
    local _wname
    _wname="$(sp_roster | awk -F'|' -v w="$KITTY_WINDOW_ID" '
      { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $4)
        n=$4; sub(/.*@@/, "", n)
        if (n == w) { print $1; exit } }' 2>/dev/null)"
    if [ -n "$_wname" ]; then echo "$_wname"; return; fi
  fi
  # Pad default (pi: no session id, not in a kitty window). Last-resort fallback.
  cat "$PAD_STATE/whoami" 2>/dev/null || true
}

# ── Do Not Disturb ──────────────────────────────────────────────────
# DND is a local wake-suppression flag. It never mutates the pad or seen cursor:
# mentions accumulate behind .state/seen.<name> and can be drained on return.
sp_dnd_file() { printf '%s/dnd.%s\n' "$PAD_STATE" "$1"; }
sp_dnd_is_on() { [ -f "$(sp_dnd_file "$1")" ]; }

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

# Append a small italic system/presence line to the pad (join/leave, etc.).
# Not a message — no @sender — so it never trips mention detection or the gate.
sp_system() {
  local msg="$1" ts; ts="$(date '+%I:%M %p')"
  printf '\n*%s · %s*\n' "$msg" "$ts" >> "$PAD_MD"
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

# ── @mention detection ───────────────────────────────────────────────
# Count lines in the pad addressed TO <name> (a line starting with @name). Used
# by the watcher to detect when a NEW mention has landed (count went up).
sp_count_to() {
  local who="$1" file="${2:-$PAD_MD}" n
  n=$(grep -icE "(^|[^a-z0-9_-])@${who}([^a-z0-9_-]|$)" "$file" 2>/dev/null) || true
  echo "${n:-0}"
}

# Extract the latest message block addressed to <name>: from the last "## "
# header owning an @name mention, up to the next "## " header. Mentions can be
# inline ("dale @larry ..."), but must respect handle boundaries.
sp_latest_to() {
  local who="$1"
  awk -v who="$who" '
    BEGIN { mention = "(^|[^a-z0-9_-])@" tolower(who) "([^a-z0-9_-]|$)" }
    /^##/ { sub_start=NR; if (last && !end) end=NR-1 }
    { lines[NR]=$0 }
    tolower($0) ~ mention { last=sub_start; end=0 }
    END { if (!end) end=NR; if (last) for (i=last;i<=end;i++) print lines[i] }
  ' "$PAD_MD"
}

# Engagement gate derived from pad CONTENT, not git commit subjects. The watch.sh
# daemon auto-commits the pad as "update (HH:MM:SS)", which clobbers the authored
# "<name>: <text>" subject the old gate relied on — so git subjects are unreliable.
# The markdown is ground truth. Walks "## @author · time" blocks in order:
#   - a block authored by someone ELSE that @-mentions me  → a mention TO me
#   - a block authored by ME that @-mentions anyone else   → an addressed reply
# Prints "<last_mention_ordinal> <last_reply_ordinal>" (0 if none). Blocked iff
# last_mention > last_reply. Author-skip is built in: my own blocks never count as
# mentions to me, killing the self-ack loop too.
# Silent-ack convention: a block whose first content line starts with "." or "[ack]"
# is invisible to the gate — it neither wakes a mentioned target nor counts as an
# addressed reply. Lets agents post acknowledgements/status without costing anyone a
# wake. Sender opt-in, no content guessing.
sp_engagement() {
  local who="$1"
  awk -v who="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" '
    # An ADDRESS is "@name" at line-start or after whitespace — NOT after punctuation
    # like / ` " (), so a quoted/referenced "@name" (e.g. "the @john/@dale discussion")
    # or a backticked `@name` does not count as addressing someone. buf joins lines with
    # a leading space, so (^|[ \t]) covers block-start, every line-start, and mid-sentence.
    function body_mentions(name,   re) { re="(^|[ \t])@" name "([^a-z0-9_-]|$)"; return (buf ~ re) }
    function flush() {
      if (author=="") return
      n++
      if (author==who) {                                                          # my own block:
        if (silent || buf ~ /(^|[ \t])@[a-z0-9_-]/) last_reply=n                 # a silent ack OR a real @-address reply clears my gate
      } else if (!silent && body_mentions(who)) last_mention=n                    # a silent post by another never wakes me; a real address does
    }
    /^## @/ {
      flush()
      a=$2; sub(/^@/,"",a); author=tolower(a); buf=""; silent=0; seen_body=0; infence=0
      next
    }
    # A fenced code block (``` toggles) is never an address — doctor output, diffs and
    # code paste "@name" listings (e.g. "✓ @dale — healthy") must not wake anyone. The
    # fence lines themselves and their contents are excluded from the mention buffer.
    /^[[:space:]]*```/ { infence = !infence; next }
    infence { next }
    # first non-empty content line decides silent-ack (leading "." or "[ack]")
    !seen_body && /[^[:space:]]/ {
      seen_body=1
      b=tolower($0); sub(/^[ \t]*/,"",b); sub(/^(@[a-z0-9_-]+[ \t]*)+/,"",b); sub(/[ \t]+$/,"",b)
      if (b ~ /^(\.|\[ack\])/) silent=1
      if (b ~ /^(ack|read|noted|got it|standing down|standing by|stand by|will do|understood|done here|copy|sounds good)[. !]*$/) silent=1
    }
    # Strip inline code (`...`) before appending to buffer — prevents `@name` in code
    # snippets from counting as an address. Real addresses survive because only the
    # backtick-delimited content is blanked, not the surrounding text.
    { line = tolower($0); gsub(/`[^`]*`/, " ", line); buf = buf " " line }
    END { flush(); print (last_mention+0) " " (last_reply+0) }
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
