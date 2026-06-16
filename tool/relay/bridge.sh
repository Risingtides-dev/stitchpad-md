#!/usr/bin/env bash
# stitchpad relay bridge — runs on the Mac. Mirrors EVERY local stitchpad up to
# the Cloudflare relay (keyed by pad name = directory basename), and drains each
# pad's phone→pad queue back into the real pad via `stitchpad say` (which the
# watcher then wakes agents from). The CLI stays the source of truth.
#
#   STITCHPAD_RELAY=https://stitchpad.agentsworld.org \
#   STITCHPAD_TOKEN=<secret> \
#   stitchpad-bridge [roots...]      # roots to scan for .stitchpad dirs (default: ~ )
set -uo pipefail
RELAY="${STITCHPAD_RELAY:?set STITCHPAD_RELAY}"
TOKEN="${STITCHPAD_TOKEN:?set STITCHPAD_TOKEN}"
ROOTS=("${@:-$HOME}")
SP="$(command -v stitchpad || echo "$HOME/.stitchpad/bin/stitchpad")"
INTERVAL="${STITCHPAD_BRIDGE_INTERVAL:-3}"

api() { curl -fsS -H "authorization: Bearer $TOKEN" -H "content-type: application/json" "$@"; }

# find all .stitchpad pads under the roots (skip the ~/.stitchpad install symlink)
find_pads() {
  for r in "${ROOTS[@]}"; do
    find "$r" -maxdepth 4 -type d -name .stitchpad 2>/dev/null
  done | grep -v "/.stitchpad/.stitchpad" | sort -u
}

echo "[bridge] relay=$RELAY  interval=${INTERVAL}s  scanning: ${ROOTS[*]}"
while :; do
  while IFS= read -r padd; do
    [ -f "$padd/stitchpad.md" ] || continue
    name="$(basename "$(dirname "$padd")")"            # pad name = project dir
    md="$(cat "$padd/stitchpad.md")"
    roster="$(cd "$(dirname "$padd")" && "$SP" roster 2>/dev/null | awk -F'|' '{printf "%s{\"name\":\"%s\",\"adapter\":\"%s\"}", (NR>1?",":""), $1, $2}')"
    # file list for the `>` attach dropdown: project files, relative paths, skip junk/dotdirs
    proj="$(dirname "$padd")"
    files="$(cd "$proj" && find . -maxdepth 3 -type f \
        -not -path '*/.git/*' -not -path '*/.stitchpad/*' -not -path '*/node_modules/*' \
        -not -path '*/target/*' -not -path '*/.*/*' 2>/dev/null \
        | sed 's|^\./||' | sort | head -500 | jq -R . | jq -sc .)"
    # collect single-source color map from the pad (flat object: {name: hex})
    colors="$(cd "$proj" && "$SP" color --all 2>/dev/null | jq -R 'split(" ") | {(.[0]): .[1]}' | jq -sc 'add // {}' 2>/dev/null || echo '{}')"
    # collect per-agent profiles (role, persona, skills, model, harness)
    profiles='{}'
    for _name in $(echo "$roster" | jq -r '.[].name' 2>/dev/null); do
      _model="$(cat "$padd/.state/model.$_name" 2>/dev/null || echo '')"
      _persona=""
      _skills='[]'
      _role=''
      # Try to read persona from tool/personas/<name>.md
      _persona_file="$proj/tool/personas/$(echo "$_name" | tr '[:upper:]' '[:lower:]').md"
      if [ -f "$_persona_file" ]; then
        _role="$(head -1 "$_persona_file" | sed 's/^# //')"
        _persona="$(cat "$_persona_file" | head -5 | tail -4)"
      fi
      # Get harness info
      _harness_info="$(cd "$proj" && "$SP" harness "$_name" 2>/dev/null || echo '')"
      _harness="$(echo "$_harness_info" | grep -o 'harness=[^ ]*' | cut -d= -f2 | head -1 || echo '')"
      profiles="$(echo "$profiles" | jq --arg n "$_name" --arg m "$_model" --arg r "$_role" --arg p "$_persona" --argjson s "${_skills:-[]}" --arg h "$_harness" \
        '. + {($n): {role:$r, persona:$p, skills:$s, model:$m, harness:$h}}')"
    done
    # push this pad up (markdown + roster + files + colors + profiles)
    jq -nc --arg pad "$md" --argjson roster "[${roster}]" --argjson files "${files:-[]}" --argjson colors "${colors}" --argjson profiles "${profiles}" \
      '{pad:$pad, roster:$roster, files:$files, colors:$colors, profiles:$profiles}' 2>/dev/null \
      | api -X POST "$RELAY/push?pad=$name" --data-binary @- >/dev/null || true
    # drain phone→pad messages for this pad, inject via stitchpad say
    out="$(api "$RELAY/outbox?pad=$name" 2>/dev/null || echo '{"messages":[]}')"
    echo "$out" | jq -c '.messages[]?' 2>/dev/null | while IFS= read -r m; do
      from="$(echo "$m" | jq -r '.from')"; text="$(echo "$m" | jq -r '.text')"
      ( cd "$(dirname "$padd")" && STITCHPAD_NAME="$from" "$SP" say "$text" >/dev/null 2>&1 ) || true
      echo "[bridge] $name ← @$from: ${text:0:50}"
    done
    # Write heartbeat after successful push+drain for this pad
    printf '{"ts":"%s","pad":"%s","interval":%s}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$INTERVAL" > "$padd/.state/bridge-heartbeat" 2>/dev/null || true
  done < <(find_pads)
  sleep "$INTERVAL"
done
