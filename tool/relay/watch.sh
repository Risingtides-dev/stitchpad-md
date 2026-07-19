#!/usr/bin/env bash
# relay-watch — remote-agent mention poller.
#
# Polls the relay GET /pad endpoint for new @mentions of the local agent.
# When a mention is found, wakes the local Velocity surface (same as watch.sh).
#
# Usage:
#   STITCHPAD_RELAY=https://stitchpad.agentsworld.org \
#   STITCHPAD_TOKEN=<invite-or-relay-token> \
#   STITCHPAD_NAME=<your-handle> \
#   stitchpad relay-watch
#
# Requires: $VELOCITY_SURFACE_ID + $VELOCITY_TAB_ID in env (Velocity injects
# these into every surface's shell).

set -euo pipefail

RELAY="${STITCHPAD_RELAY:-}"
TOKEN="${STITCHPAD_TOKEN:-}"
HANDLE="${STITCHPAD_NAME:-}"
POLL_INTERVAL="${STITCHPAD_POLL_INTERVAL:-5}"  # seconds

if [ -z "$RELAY" ] || [ -z "$TOKEN" ] || [ -z "$HANDLE" ]; then
  echo "relay-watch: STITCHPAD_RELAY, STITCHPAD_TOKEN, and STITCHPAD_NAME required" >&2
  exit 1
fi

SC_SURFACE="${VELOCITY_SURFACE_ID:-}"
SC_TAB="${VELOCITY_TAB_ID:-}"
SC_WORKTREE="${VELOCITY_WORKTREE_ID:-}"
SURFACE_APP="velocity"

if [ -z "$SC_SURFACE" ] || [ -z "$SC_TAB" ]; then
  echo "relay-watch: surface + tab IDs required (run in Velocity)" >&2
  exit 1
fi

if [ -n "${STITCHPAD_SURFACE_CLI:-}" ]; then
  SC_BIN="$STITCHPAD_SURFACE_CLI"
else
  SC_BIN="$(command -v velocity 2>/dev/null || echo /Applications/Velocity.app/Contents/Resources/bin/velocity)"
fi
[ -x "$SC_BIN" ] || { echo "relay-watch: velocity CLI not found at $SC_BIN" >&2; exit 1; }

LAST_SEEN=0  # track mention ordinal to avoid re-firing
SEEN_FILE="${STITCHPAD_HOME:-$HOME/.stitchpad}/.state/relay-watch-seen.${HANDLE}"
mkdir -p "$(dirname "$SEEN_FILE")" 2>/dev/null || true
# Restore cursor from previous run (survives restart)
if [ -f "$SEEN_FILE" ]; then
  LAST_SEEN=$(cat "$SEEN_FILE" 2>/dev/null || echo 0)
  echo "[relay-watch] restored cursor: seen ${LAST_SEEN} mentions"
fi
echo "[relay-watch] polling ${RELAY} as ${HANDLE} every ${POLL_INTERVAL}s"

while true; do
  # Fetch the pad from relay
  resp=$(curl -sf -H "Authorization: Bearer ${TOKEN}" "${RELAY}/pad?pad=" 2>/dev/null || true)
  if [ -z "$resp" ]; then
    echo "[relay-watch] relay unreachable, retrying in ${POLL_INTERVAL}s"
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Extract markdown from relay payload (JSON {md,roster,...})
  md=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('md',''))" 2>/dev/null || echo "")
  if [ -z "$md" ]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Count @mentions of our handle since LAST_SEEN
  mention_count=$(echo "$md" | grep -c "@${HANDLE}\b" 2>/dev/null || echo 0)

  if [ "$mention_count" -gt "$LAST_SEEN" ]; then
    NEW_COUNT=$(( mention_count - LAST_SEEN ))
    echo "[relay-watch] ${NEW_COUNT} new @${HANDLE} mentions — waking ${SURFACE_APP} surface ${SC_SURFACE}"

    # Wake the surface: insert the nudge then submit it (same as velocity.sh).
    nudge="stitchpad wake ${HANDLE}"
    "$SC_BIN" surface focus -w "$SC_WORKTREE" -t "$SC_TAB" -s "$SC_SURFACE" -i "$nudge" >/dev/null 2>&1 || true
    "$SC_BIN" surface send-key -w "$SC_WORKTREE" -t "$SC_TAB" -s "$SC_SURFACE" --key Enter >/dev/null 2>&1 || true

    LAST_SEEN="$mention_count"
    echo "$LAST_SEEN" > "$SEEN_FILE"
  fi

  sleep "$POLL_INTERVAL"
done
