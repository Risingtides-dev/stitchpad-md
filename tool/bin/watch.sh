#!/usr/bin/env bash
# stitchpad watcher (daemon body). One fswatch on stitchpad.md. On every change:
#   - auto-commit to the isolated pad git
#   - for EACH roster member, if new lines address them (@name), fire their adapter
#
# Adapters live in ~/.stitchpad/adapters/<adapter>.sh and are called as:
#   adapter.sh <event> <to> <stitchpad.md> <task-text-file>
# where event = "mention". The adapter decides push (spawn) vs pull (flag/notify)
# vs trigger (claude.ai remote-trigger) using the wake mode passed via $SP_WAKE.
#
# BUG HISTORY: an earlier version let inner `read`s consume the fswatch pipe's
# stdin, corrupting variable names ("old<mojibake>: unbound variable"). Fixed by
# (1) snapshotting the roster into an array, (2) redirecting every inner command
# that could read stdin from /dev/null, and (3) feeding the fswatch loop a
# function that itself takes no stdin.
set -uo pipefail
_src="${BASH_SOURCE[0]}"; while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"; _src="$(readlink "$_src")"
  [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
done
BIN_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
source "$BIN_DIR/lib.sh"
sp_init_paths || { echo "no stitchpad"; exit 1; }

# Per-user mention counters live in state.
count_file() { echo "$PAD_STATE/count.$1"; }

# Seed baselines so we only react to NEW mentions. Snapshot the roster first so
# this loop doesn't hold a process-substitution fd open across the body.
declare -a SEED=()
while IFS= read -r _l; do SEED+=("$_l"); done < <(sp_roster)
for _m in "${SEED[@]}"; do
  IFS='|' read -r _name _ _ _ <<< "$_m"
  [ -n "$_name" ] || continue
  sp_count_to "$_name" > "$(count_file "$_name")"
done

echo "[stitchpad] watching $PAD_MD"
for _m in "${SEED[@]}"; do
  IFS='|' read -r _name _adapter _wake _ <<< "$_m"
  [ -n "$_name" ] || continue
  echo "  · @$_name → adapter=$_adapter wake=$_wake"
done

fire_adapter() {
  local name="$1" adapter="$2" wake="$3" target="$4"
  local script="$ADAPTER_DIR/$adapter.sh"
  if [ ! -f "$script" ]; then
    echo "[stitchpad] no adapter '$adapter' for @$name (looked in $ADAPTER_DIR)"; return 1
  fi
  local taskfile; taskfile="$(mktemp)"
  sp_latest_to "$name" > "$taskfile"
  SP_WAKE="$wake" SP_TARGET="$target" SP_PAD_DIR="$PAD_DIR" SP_PAD_MD="$PAD_MD" \
    bash "$script" mention "$name" "$PAD_MD" "$taskfile" </dev/null \
    || echo "[stitchpad] adapter $adapter failed for @$name"
  rm -f "$taskfile"
}

# react() takes NO stdin — everything inside redirects from /dev/null where it
# might otherwise read the fswatch pipe.
react() {
  sp_commit "update ($(date '+%H:%M:%S'))"
  local -a members=()
  local rline
  while IFS= read -r rline; do members+=("$rline"); done < <(sp_roster)
  local m name adapter wake target
  for m in "${members[@]}"; do
    IFS='|' read -r name adapter wake target <<< "$m"
    [ -n "$name" ] || continue
    # Fire ONLY if there's an UNANSWERED mention — the same engagement gate the
    # hook wake uses (a @name newer than name's last @-reply). `wake --peek` prints
    # the pending message iff unanswered and does NOT advance any cursor, so the
    # nudge → agent replies → reply clears the gate. Raw count-up looped forever
    # because an agent's own reply re-incremented the other's count.
    if [ -n "$("$BIN_DIR/stitchpad" wake "$name" --peek 2>/dev/null)" ]; then
      echo "[stitchpad] unanswered @$name -> firing ${adapter} (${wake})"
      fire_adapter "$name" "$adapter" "$wake" "$target"
    fi
  done
}

fswatch -0 "$PAD_MD" | while read -r -d "" _ev; do react </dev/null; done
