#!/usr/bin/env bash
# stitchpad relay-watch — the AGENT-SIDE poller for joining a REMOTE pad.
#
# THE PROBLEM IT SOLVES
# ---------------------
# The local watcher (tool/bin/watch.sh) runs an fswatch on a LOCAL stitchpad.md
# and fires the kitty adapter whenever someone @-mentions an agent. That only
# works for agents whose pad lives on THIS machine.
#
# A REMOTE agent has no local pad file. The pad lives on someone else's machine
# and is mirrored to the Cloudflare relay. So the remote agent's own machine has
# to POLL the relay for the pad markdown, notice when a NEW message @-mentions
# itself, and wake ITS OWN local kitty window — exactly the nudge the local
# adapter delivers, just sourced from a poll instead of an fswatch event.
#
# This is the INBOUND half of remote-agent-join. The OUTBOUND half (say / read /
# join / leave against the relay) is handled by the relay-mode MCP server
# (tool/mcp/server.mjs, IS_RELAY path). This script only listens and wakes; it
# never posts. Together they make a remote agent a first-class pad member.
#
# CONTRACT (env)
#   STITCHPAD_RELAY   relay base url, e.g. https://pad.example.workers.dev
#   STITCHPAD_TOKEN   relay bearer token
#   STITCHPAD_PAD     pad name on the relay
#   STITCHPAD_NAME    my handle (the @name I answer to)
#   KITTY_LISTEN_ON   my kitty socket (captured at join, same as the MCP does);
#                     KITTY_SOCKET also accepted. Optional — self-heals by title.
#   KITTY_WINDOW_ID   my kitty window id. Optional — self-heals by window title
#                     "🧵 <name>" via `kitty @ ls`, exactly like kitty.sh.
#   RELAY_WATCH_INTERVAL   poll seconds (default 5)
#
# Needs only: curl, python3, kitty. Crash-safe: a bad poll logs and continues.

set -uo pipefail

# ── config ───────────────────────────────────────────────────────────
RELAY="${STITCHPAD_RELAY:-}"
TOKEN="${STITCHPAD_TOKEN:-}"
PAD="${STITCHPAD_PAD:-}"
NAME="${STITCHPAD_NAME:-}"
INTERVAL="${RELAY_WATCH_INTERVAL:-5}"

[ -n "$RELAY" ] || { echo "relay-watch: STITCHPAD_RELAY unset" >&2; exit 1; }
[ -n "$TOKEN" ] || { echo "relay-watch: STITCHPAD_TOKEN unset" >&2; exit 1; }
[ -n "$PAD" ]   || { echo "relay-watch: STITCHPAD_PAD unset" >&2; exit 1; }
[ -n "$NAME" ]  || { echo "relay-watch: STITCHPAD_NAME unset" >&2; exit 1; }
RELAY="${RELAY%/}"   # trim trailing slash so "$RELAY/pad" is clean

# kitty location (same fallback the adapter uses for app-bundle installs).
KITTY_BIN="$(command -v kitty 2>/dev/null || echo /Applications/kitty.app/Contents/MacOS/kitty)"
[ -x "$KITTY_BIN" ] || { echo "relay-watch: kitty not found" >&2; exit 1; }

# State: a cursor = the highest message-block ordinal I've already processed.
# Surviving restarts is nice-to-have, not required, so /tmp is fine.
# State lives under ~/.stitchpad/.state so the cursor PERSISTS across restarts
# (a /tmp cursor re-seeds on reboot → could miss or re-wake mentions). Keyed by
# relay+pad+name so multiple remote pads on one machine don't collide.
KEY="$(printf '%s' "$RELAY/$PAD/$NAME" | tr -c 'A-Za-z0-9' '_')"
STATE_DIR="${STITCHPAD_HOME:-$HOME/.stitchpad}/.state"
mkdir -p "$STATE_DIR" 2>/dev/null || STATE_DIR="${TMPDIR:-/tmp}"
SEEN_FILE="$STATE_DIR/relay-watch.$KEY.seen"
LOG="$STATE_DIR/relay-watch.$KEY.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >>"$LOG"; }

# ── Python helpers as EXTERNAL files (bash-3.2-safe) ─────────────────
# macOS ships bash 3.2, which CANNOT parse a heredoc nested inside $(...) — it
# dies "unexpected EOF / token (", a silent no-wake (henry caught it live). So we
# write the two python programs to temp files ONCE and invoke them normally. No
# heredoc-in-command-substitution anywhere → parses on 3.2 and 4+ alike.
PARSER_PY="$STATE_DIR/relay-watch.$KEY.parser.py"
SEED_PY="$STATE_DIR/relay-watch.$KEY.seed.py"
cat > "$PARSER_PY" <<'PY'
import sys, os, re, json
name = sys.argv[1]
raw = os.environ.get("PADBODY", "")
md = raw
s = raw.lstrip()
if s[:1] in "{[":
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict) and isinstance(obj.get("pad"), str):
            md = obj["pad"]
    except Exception:
        md = raw
try:
    seen = int(os.environ.get("SEEN", "0"))
except ValueError:
    seen = 0
low = name.lower()
mention = re.compile(r'(^|[^a-z0-9_-])@' + re.escape(low) + r'([^a-z0-9_-]|$)')
header = re.compile(r'^##\s+@?([A-Za-z0-9_-]+)')
blocks = []
cur_author, cur_lines, started = None, [], False
for line in md.splitlines():
    m = header.match(line)
    if m:
        if started:
            blocks.append((cur_author, "\n".join(cur_lines)))
        cur_author = m.group(1).lower()
        cur_lines = []
        started = True
    elif started:
        cur_lines.append(line)
if started:
    blocks.append((cur_author, "\n".join(cur_lines)))
maxord = len(blocks)
for i, (author, text) in enumerate(blocks, start=1):
    if i <= seen: continue
    if author == low: continue
    if not mention.search(text.lower()): continue
    first = next((l for l in text.splitlines() if l.strip()), "")
    if first.strip().startswith(".") or first.strip().lower().startswith("[ack]"): continue
    _bad = set('\r\n\\' + chr(96) + chr(34) + chr(39))
    snip = ''.join(c for c in first if c not in _bad)
    snip = re.sub(r'\s+', ' ', snip).strip()[:120]
    print(f"{i}\t{author}\t{snip}")
print(f"MAX {maxord}")
PY
cat > "$SEED_PY" <<'PY'
import os, re, json
raw = os.environ.get("PADBODY", "")
md = raw
s = raw.lstrip()
if s[:1] in "{[":
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict) and isinstance(obj.get("pad"), str):
            md = obj["pad"]
    except Exception:
        md = raw
if not raw.strip():
    print(-1)
else:
    print(sum(1 for l in md.splitlines() if re.match(r'^##\s+@?[A-Za-z0-9_-]+', l)))
PY

# SINGLE-INSTANCE: a second poller for the same relay+pad+name would DOUBLE-inject
# wakes (larry's gate). mkdir is atomic on every POSIX fs — first one wins, dupes
# exit cleanly. Stale lock (dead pid) is reclaimed. Released on exit.
LOCK_DIR="$STATE_DIR/relay-watch.$KEY.lock.d"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  _lpid="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo '')"
  if [ -n "$_lpid" ] && kill -0 "$_lpid" 2>/dev/null; then
    echo "relay-watch: already running for $PAD/@$NAME (pid $_lpid) — exiting (no double-wake)" >&2
    exit 0
  fi
  # stale lock from a dead poller — reclaim
  rm -rf "$LOCK_DIR" 2>/dev/null; mkdir "$LOCK_DIR" 2>/dev/null || { echo "relay-watch: lock race lost" >&2; exit 0; }
fi
echo "$$" > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null; log "relay-watch exiting (cleanup)"' EXIT

echo "relay-watch: polling $RELAY/pad?pad=$PAD as @$NAME every ${INTERVAL}s (log: $LOG)"
log "start poll pad=$PAD name=$NAME interval=${INTERVAL}s lock=$LOCK_DIR"

# Parser helper. Keep Python out of heredocs nested inside command substitution:
# macOS /bin/bash 3.2 mis-parses that pattern before any version guard can run.
PARSER_PY="$STATE_DIR/relay-watch.$KEY.parser.py"
cat > "$PARSER_PY" <<'PY'
import json
import os
import re
import sys

def markdown_from_env():
    raw = os.environ.get("PADBODY", "")
    md = raw
    s = raw.lstrip()
    if s[:1] in "{[":
        try:
            obj = json.loads(raw)
            if isinstance(obj, dict) and isinstance(obj.get("pad"), str):
                md = obj["pad"]
        except Exception:
            md = raw
    return raw, md

def blocks_from_markdown(md):
    header = re.compile(r'^##\s+@?([A-Za-z0-9_-]+)')
    blocks = []
    cur_author, cur_lines, started = None, [], False
    for line in md.splitlines():
        m = header.match(line)
        if m:
            if started:
                blocks.append((cur_author, "\n".join(cur_lines)))
            cur_author = m.group(1).lower()
            cur_lines = []
            started = True
        elif started:
            cur_lines.append(line)
    if started:
        blocks.append((cur_author, "\n".join(cur_lines)))
    return blocks

mode = sys.argv[1] if len(sys.argv) > 1 else ""
raw, md = markdown_from_env()

if mode == "count":
    if not raw.strip():
        print(-1)
    else:
        print(len(blocks_from_markdown(md)))
    raise SystemExit

if mode != "mentions" or len(sys.argv) < 3:
    raise SystemExit(2)

name = sys.argv[2]
try:
    seen = int(os.environ.get("SEEN", "0"))
except ValueError:
    seen = 0

low = name.lower()
mention = re.compile(r'(^|[^a-z0-9_-])@' + re.escape(low) + r'([^a-z0-9_-]|$)')
blocks = blocks_from_markdown(md)

for i, (author, text) in enumerate(blocks, start=1):
    if i <= seen:
        continue
    if author == low:
        continue
    if not mention.search(text.lower()):
        continue
    first = next((l for l in text.splitlines() if l.strip()), "")
    stripped = first.strip()
    if stripped.startswith(".") or stripped.lower().startswith("[ack]"):
        continue
    bad = set("\r\n\\" + chr(96) + chr(34) + chr(39))
    snip = "".join(c for c in first if c not in bad)
    snip = re.sub(r"\s+", " ", snip).strip()[:120]
    print("%s\t%s\t%s" % (i, author, snip))
print("MAX %s" % len(blocks))
PY

# ── kitty target resolution ──────────────────────────────────────────
# Resolve (socket, window) for MY kitty window. Prefer the captured env; else
# self-heal by matching the window title "🧵 <name>" — identical strategy to
# tool/adapters/kitty.sh, so a remote join that couldn't capture KITTY_* still
# wakes. Echoes "<sock>\t<win>" or empty on failure.
resolve_target() {
  local sock="${KITTY_LISTEN_ON:-${KITTY_SOCKET:-}}" win="${KITTY_WINDOW_ID:-}"
  if [ -z "$sock" ]; then
    sock="unix:$(ls /tmp/kitty-* 2>/dev/null | head -1)"
  fi
  if [ -z "$win" ]; then
    win="$("$KITTY_BIN" @ --to "$sock" ls 2>/dev/null | python3 -c '
import sys, json
try:
  d = json.load(sys.stdin); name = sys.argv[1]
  for o in d:
    for t in o["tabs"]:
      for w in t["windows"]:
        if w.get("title", "") == "\U0001F9F5 " + name:
          print(w["id"]); raise SystemExit
except SystemExit: pass
except Exception: pass' "$NAME" 2>/dev/null)"
  fi
  [ -n "$sock" ] && [ -n "$win" ] || return 1
  printf '%s\t%s' "$sock" "$win"
}

# ── kitty wake (inlined; no local pad FILE to hand the adapter) ───────
# Mirrors the adapter's two-step submit: send-text drops the line in the prompt,
# then a SEPARATE send-key enter actually submits it (a trailing \r does NOT
# submit in claude/codex/pi TUIs). Honors the same focus-guard: never inject into
# the window you're typing in (set RELAY_WATCH_FORCE=1 to override). Wakes once
# per new mention — the cursor advance upstream prevents re-spamming.
wake_kitty() {
  local sender="$1" snip="$2" tgt sock win
  tgt="$(resolve_target)" || { log "no kitty target for @$NAME (no env, no '🧵 $NAME' window)"; return 1; }
  sock="${tgt%%$'\t'*}"; win="${tgt##*$'\t'}"

  if [ "${RELAY_WATCH_FORCE:-0}" != "1" ]; then
    local focused
    focused="$("$KITTY_BIN" @ --to "$sock" ls 2>/dev/null | python3 -c '
import sys, json
try:
  d = json.load(sys.stdin); w = sys.argv[1]
  print(any(str(win["id"]) == w and win.get("is_focused") for o in d for t in o["tabs"] for win in t["windows"]))
except Exception: print(False)' "$win" 2>/dev/null)"
    if [ "$focused" = "True" ]; then
      log "@$NAME window $win focused (you're typing) — deferring; will retry next poll"
      return 3   # DEFERRED: do NOT advance cursor, so we re-fire on the next poll
    fi
  fi

  local nudge
  if [ -n "$sender" ] && [ -n "$snip" ]; then
    nudge="stitchpad(relay): NEW from @$sender — $snip — you were @mentioned; run the read tool to see it and reply with @$sender"
  else
    nudge="stitchpad(relay): you were @mentioned — run the read tool to see it"
  fi

  if "$KITTY_BIN" @ --to "$sock" send-text --match "id:$win" -- "$nudge" 2>>"$LOG"; then
    sleep 0.3   # let the TUI register the paste before the Enter keypress
    "$KITTY_BIN" @ --to "$sock" send-key --match "id:$win" enter 2>>"$LOG"
    log "woke @$NAME via kitty (win $win @ $sock) from @${sender:-?}"
    return 0
  fi
  log "kitty send-text failed for @$NAME (win $win @ $sock)"
  return 1
}

# ── poll once: fetch pad, detect unanswered mention, maybe wake ──────
# Returns nothing meaningful; never exits the loop on error.
poll_once() {
  local body http
  # -f would make 4xx return empty; we want to log the status instead, so capture
  # the trailing HTTP code and split it off. --max-time keeps a hung relay from
  # wedging the loop.
  body="$(curl -sS --max-time 20 -w $'\n%{http_code}' \
            -H "authorization: Bearer $TOKEN" \
            "$RELAY/pad?pad=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$PAD")" \
            2>>"$LOG")" || { log "curl failed (network) — continuing"; return 0; }
  http="${body##*$'\n'}"; body="${body%$'\n'*}"
  if [ "$http" != "200" ]; then log "GET /pad → HTTP $http — continuing"; return 0; fi
  [ -n "$body" ] || { log "empty pad body — continuing"; return 0; }

  # The relay's /pad returns EITHER raw markdown (MCP read path uses r.text())
  # OR a JSON envelope {pad, roster, profiles}. Detect + extract the markdown,
  # then walk the "## @author · time" blocks. Print one line per NEW unanswered
  # mention to me: "<ordinal>\t<author>\t<snippet>", plus a final "MAX <n>"
  # giving the highest block ordinal seen (the new cursor). All in one python3
  # pass so the loop body stays cheap.
  local out
  # Call the parser via an EXTERNAL temp file, NOT a heredoc-in-$(). bash 3.2 (the
  # macOS default) cannot parse a heredoc nested inside command substitution — it
  # mis-reads it and dies with "unexpected EOF / token (", a SILENT no-wake on
  # stock Macs (henry caught this live). External-file invocation is 3.2-safe.
  out="$(SEEN="$(cat "$SEEN_FILE" 2>/dev/null || echo 0)" PADBODY="$body" python3 "$PARSER_PY" mentions "$NAME")" \
    || { log "pad parse failed — continuing"; return 0; }

  # Walk the parser output. Fire a wake per new unanswered mention. Advance the
  # cursor to MAX — UNLESS a wake DEFERRED (focus-guard), in which case we hold
  # the cursor just below that mention so it re-fires next poll. This is the
  # wake-once-per-mention guarantee, same spirit as watch.sh's read-clears-gate.
  local newmax="" line ord author snip deferred_at=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "MAX "*) newmax="${line#MAX }" ;;
      *)
        IFS=$'\t' read -r ord author snip <<<"$line"
        echo "relay-watch: unanswered @$NAME from @$author (block $ord) — waking kitty"
        if wake_kitty "$author" "$snip"; then
          :
        else
          local rc=$?
          if [ "$rc" -eq 3 ] && [ -z "$deferred_at" ]; then
            deferred_at="$ord"   # remember the FIRST deferred mention
          fi
        fi
        ;;
    esac
  done <<<"$out"

  # Cursor update. If something deferred, stop the cursor just before it so it
  # comes back next poll; otherwise jump to the newest block.
  if [ -n "$deferred_at" ]; then
    echo $(( deferred_at - 1 )) > "$SEEN_FILE"
  elif [ -n "$newmax" ]; then
    echo "$newmax" > "$SEEN_FILE"
  fi
}

# ── seed the cursor so we don't wake on PRE-EXISTING mentions ────────
# On first run (no state file), set the cursor to the current block count so we
# only react to mentions that arrive AFTER we start watching — mirrors watch.sh
# seeding sp_count_to baselines.
if [ ! -f "$SEEN_FILE" ]; then
  # Retry the seed fetch a few times — the MCP may start the poller a beat before
  # the relay is reachable. We NEVER seed to 0 on failure (that would flood-wake
  # the whole backlog — larry's gate); we retry, then give up cleanly if truly down.
  seed=""
  for _try in 1 2 3 4 5; do
  _seedbody="$(curl -sS --max-time 20 -H "authorization: Bearer $TOKEN" \
            "$RELAY/pad?pad=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$PAD")" 2>>"$LOG")"
  seed="$(PADBODY="$_seedbody" python3 "$SEED_PY")"
    [ -n "$seed" ] && [ "$seed" != "-1" ] && break
    log "seed attempt $_try failed — retrying in 3s"
    sleep 3
  done
  if [ -z "$seed" ] || [ "$seed" = "-1" ]; then
    # seed fetch failed — do NOT create the cursor file. Next start retries; until
    # then the loop won't run (no SEEN_FILE → first poll_once below also can't
    # safely fire, so we just retry). Fail-safe: never wake the backlog. (larry's gate)
    log "seed fetch failed — NOT seeding (will retry next start; backlog stays unwoken)"
    echo "relay-watch: seed fetch failed (relay unreachable?) — retry; not waking backlog" >&2
    exit 1
  fi
  echo "$seed" > "$SEEN_FILE"
  log "seeded cursor at block $seed (ignoring pre-existing mentions)"
fi

# ── the poll loop ────────────────────────────────────────────────────
# Crash-safe by construction: poll_once swallows its own errors and returns 0,
# so the loop runs forever until the process is killed.
trap 'log "relay-watch exiting (signal)"; exit 0' INT TERM
while :; do
  poll_once
  sleep "$INTERVAL"
done
