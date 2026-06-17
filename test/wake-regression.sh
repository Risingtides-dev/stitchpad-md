#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

tmp="$(mktemp -d /tmp/stitchpad-wake-regression.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

export STITCHPAD_HOME="$ROOT/tool"

# Regression 1: an addressed block should not sweep later replies into the wake
# prompt. The hook prompt should contain only the addressed message block.
case1="$tmp/case1"
mkdir "$case1"
cd "$case1"
"$SP" init --name case1 >/dev/null
"$SP" join dale codex >/dev/null
"$SP" daemon stop >/dev/null 2>&1 || true   # isolate wake logic from watcher
pkill -f "fswatch.*$case1" 2>/dev/null || true
sleep 0.2
STITCHPAD_NAME=tester "$SP" say '@dale first ping' >/dev/null
STITCHPAD_NAME=larry "$SP" say 'unrelated after first ping' >/dev/null
out="$("$SP" wake dale)"
contains "$out" '@dale first ping' || fail 'wake did not include addressed message'
if contains "$out" 'unrelated after first ping'; then
  fail 'wake included a later unrelated block'
fi

# Regression 2: an unrelated commit must not clear an unanswered mention; only
# an addressed reply by that agent clears it.
case2="$tmp/case2"
mkdir "$case2"
cd "$case2"
"$SP" init --name case2 >/dev/null
"$SP" join dale codex >/dev/null
"$SP" daemon stop >/dev/null 2>&1 || true   # isolate wake logic from watcher
pkill -f "fswatch.*$case2" 2>/dev/null || true  # daemon stop may orphan fswatch
sleep 0.2
STITCHPAD_NAME=tester "$SP" say '@dale one-shot ping' >/dev/null
first="$("$SP" wake dale)"
contains "$first" '@dale one-shot ping' || fail 'first wake missed addressed message'
STITCHPAD_NAME=larry "$SP" say 'unrelated status update' >/dev/null
second="$("$SP" wake dale)"
contains "$second" '@dale one-shot ping' || fail 'unrelated commit incorrectly cleared unanswered mention'
STITCHPAD_NAME=dale "$SP" say '@tester addressed reply clears ping' >/dev/null
third="$("$SP" wake dale)"
if [ -n "$third" ]; then
  printf '%s\n' "$third" >&2
  fail 'addressed reply did not clear unanswered mention'
fi

# Regression 3: hook identity must be explicit. A hook with no STITCHPAD_NAME is
# silent; a hook pinned as larry wakes Larry even if Dale is also in the room.
case3="$tmp/case3"
mkdir "$case3"
cd "$case3"
"$SP" init --name case3 >/dev/null
"$SP" join larry codex >/dev/null
"$SP" join dale claude >/dev/null
"$SP" daemon stop >/dev/null 2>&1 || true   # isolate wake logic from watcher
pkill -f "fswatch.*$case3" 2>/dev/null || true
sleep 0.2
STITCHPAD_NAME=tester "$SP" say '@larry identity ping' >/dev/null
unbound="$(printf '{"cwd":"%s","stop_hook_active":false}' "$case3" | "$SP" hook)"
[ -z "$unbound" ] || fail 'unbound hook should not guess an identity'
pinned="$(printf '{"cwd":"%s","stop_hook_active":false}' "$case3" | STITCHPAD_NAME=larry "$SP" hook)"
contains "$pinned" '"decision":"block"' || fail 'pinned Larry hook did not block'
contains "$pinned" '@larry identity ping' || fail 'pinned Larry hook missed message'

# Regression 4: real chat often includes a speaker prefix before the mention
# ("dale @larry ..."). That should still wake larry; requiring @name at column 1
# makes agents silently miss messages.
case4="$tmp/case4"
mkdir "$case4"
cd "$case4"
"$SP" init --name case4 >/dev/null
"$SP" join larry codex >/dev/null
"$SP" daemon stop >/dev/null 2>&1 || true   # isolate wake logic from watcher
pkill -f "fswatch.*$case4" 2>/dev/null || true
sleep 0.2
STITCHPAD_NAME=dale "$SP" say 'dale @larry inline ping' >/dev/null
inline="$(STITCHPAD_NAME=larry "$SP" wake --peek)"
contains "$inline" 'dale @larry inline ping' || fail 'inline @mention did not wake larry'

printf 'wake regression ok\n'
