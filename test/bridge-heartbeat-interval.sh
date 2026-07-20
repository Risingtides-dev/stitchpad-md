#!/usr/bin/env bash
# TASK-70 regression: `doctor` must not report a HEALTHY bridge as stale.
#
# The bug: the ws bridge wrote its heartbeat WITHOUT an `interval` field while
# ticking every 15s. `doctor` defaulted the missing field to 3 and computed its
# staleness threshold as interval*3 = 9s, so a perfectly healthy bridge tripped
# a stale warning on every single check. A health check that always warns is
# worse than none — it trains everyone to ignore doctor output.
#
# Two properties are pinned here:
#   1. a fresh heartbeat carrying `interval` reads ALIVE (the writer's fix)
#   2. a fresh heartbeat MISSING `interval` also reads alive (the doctor-side
#      fallback), so a future writer that forgets the field cannot silently
#      reintroduce the false warning
#   3. a genuinely OLD heartbeat still reads STALE — proving the check is not
#      simply disabled by widening the default
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
FIXTURE_DIR="$(mktemp -d)"
cleanup() { rm -rf "$FIXTURE_DIR"; }
trap cleanup EXIT

cd "$FIXTURE_DIR"
"$SP" init --name bridgehb >/dev/null
STATE=".stitchpad/.state"
mkdir -p "$STATE"

fail=0
check() { # name expected_pattern
  local name="$1" pattern="$2" out
  out="$("$SP" doctor 2>&1 | grep -i 'bridge' || true)"
  if printf '%s' "$out" | grep -qi "$pattern"; then
    printf '  PASS %s\n' "$name"
  else
    printf '  FAIL %s — got: %s\n' "$name" "$out"
    fail=1
  fi
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
old_iso() { date -u -r $(( $(date +%s) - 300 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ; }

echo "=== bridge-heartbeat-interval ==="

# 1. Fresh heartbeat WITH interval (what the fixed ws bridge writes).
printf '{"ts":"%s","pad":"bridgehb","mode":"ws","interval":15}' "$(now_iso)" > "$STATE/bridge-heartbeat"
check "fresh heartbeat with interval reads alive" "alive"

# 2. Fresh heartbeat WITHOUT interval — the exact shape that caused the bug.
#    The doctor-side fallback must keep this alive.
printf '{"ts":"%s","pad":"bridgehb","mode":"ws"}' "$(now_iso)" > "$STATE/bridge-heartbeat"
check "fresh heartbeat missing interval still reads alive" "alive"

# 3. A genuinely stale heartbeat must STILL warn — the fix must not have
#    neutered the check by widening the default without bound.
printf '{"ts":"%s","pad":"bridgehb","mode":"ws","interval":15}' "$(old_iso)" > "$STATE/bridge-heartbeat"
check "5-minute-old heartbeat still reads stale" "stale"

if [ "$fail" -ne 0 ]; then
  echo "bridge-heartbeat-interval FAILED"
  exit 1
fi
echo "bridge-heartbeat-interval ok"
