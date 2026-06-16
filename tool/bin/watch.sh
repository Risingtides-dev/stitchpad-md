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
    echo "[stitchpad] no adapter '$adapter' for @$name (looked in $ADAPTER_DIR)"; return 0
  fi
  local taskfile; taskfile="$(mktemp)"
  sp_latest_to "$name" > "$taskfile"
  local rc=0
  SP_WAKE="$wake" SP_TARGET="$target" SP_PAD_DIR="$PAD_DIR" SP_PAD_MD="$PAD_MD" \
    bash "$script" mention "$name" "$PAD_MD" "$taskfile" </dev/null || rc=$?
  rm -f "$taskfile"
  # Return the adapter's exit code so the caller can distinguish DELIVERED (0) from
  # DEFERRED (3, focus-guard) or FAILED (1). Only a real delivery should consume the
  # gate (read-clears-gate); a defer must re-fire later, so it must NOT consume.
  [ "$rc" -ne 0 ] && echo "[stitchpad] adapter $adapter for @$name → exit $rc (not consuming gate)"
  return "$rc"
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
    # the pending message iff unanswered and does NOT advance any cursor.
    #
    # READ-CLEARS-GATE: after a SUCCESSFUL fire, consume the mention by running a
    # non-peek `wake` (which advances .state/seen.<name> to that mention ordinal).
    # The nudge was delivered once; the agent has now "read" it via the wake, so we
    # don't re-fire the SAME mention forever waiting for a reply. A genuinely newer
    # mention (higher ordinal) still fires. This is the structural loop-killer: an
    # agent can legitimately go silent (no post needed) and the gate is satisfied.
    if [ -n "$("$BIN_DIR/stitchpad" wake "$name" --peek 2>/dev/null)" ]; then
      echo "[stitchpad] unanswered @$name -> firing ${adapter} (${wake})"
      if fire_adapter "$name" "$adapter" "$wake" "$target"; then
        # consume only if the adapter actually delivered (focus-guard/defer returns
        # 0 too, but it logs a defer and leaves the prompt untouched — re-firing on
        # the next pad change is correct there, so we key off the wake's own output)
        "$BIN_DIR/stitchpad" wake "$name" >/dev/null 2>&1 || true
      fi
    fi
  done
}

# Trap errors in the main loop so the watcher doesn't die on a single adapter failure.
trap 'echo "[stitchpad] watcher error at line $LINENO — continuing" >&2' ERR

fswatch -0 "$PAD_MD" | while read -r -d "" _ev; do react </dev/null; done
