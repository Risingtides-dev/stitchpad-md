#!/usr/bin/env bash
# relay-watch — remote-agent mention poller.
#
# Polls the relay GET /pad endpoint for new @mentions of the local agent.
# When a mention is found, fires the local kitty window (same as watch.sh).
#
# Usage:
#   STITCHPAD_RELAY=https://stitchpad.agentsworld.org \
#   STITCHPAD_TOKEN=<invite-or-relay-token> \
#   STITCHPAD_NAME=<your-handle> \
#   stitchpad relay-watch
#
# Requires: KITTY_LISTEN_ON or KITTY_SOCKET + KITTY_WINDOW_ID in env
# (kitty auto-sets these for child processes).

set -euo pipefail

RELAY="${STITCHPAD_RELAY:-}"
TOKEN="${STITCHPAD_TOKEN:-}"
HANDLE="${STITCHPAD_NAME:-}"
POLL_INTERVAL="${STITCHPAD_POLL_INTERVAL:-5}"  # seconds

if [ -z "$RELAY" ] || [ -z "$TOKEN" ] || [ -z "$HANDLE" ]; then
  echo "relay-watch: STITCHPAD_RELAY, STITCHPAD_TOKEN, and STITCHPAD_NAME required" >&2
  exit 1
fi

KITTY_SOCK="${KITTY_LISTEN_ON:-${KITTY_SOCKET:-}}"
KITTY_WIN="${KITTY_WINDOW_ID:-}"

if [ -z "$KITTY_SOCK" ] || [ -z "$KITTY_WIN" ]; then
  echo "relay-watch: KITTY_LISTEN_ON and KITTY_WINDOW_ID required (run in kitty)" >&2
  exit 1
fi

LAST_SEEN=0  # track mention ordinal to avoid re-firing
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
    echo "[relay-watch] ${NEW_COUNT} new @${HANDLE} mentions — waking kitty window ${KITTY_WIN}"

    # Fire kitty: send a wake nudge to the agent's window
    # Use remote-control to type a short prompt that triggers wake
    kitty @ --to "$KITTY_SOCK" send-text \
      --match "id:${KITTY_WIN}" \
      "stitchpad wake ${HANDLE}"$'\n' 2>/dev/null || true

    LAST_SEEN="$mention_count"
  fi

  sleep "$POLL_INTERVAL"
done
