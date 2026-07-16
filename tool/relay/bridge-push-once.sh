#!/usr/bin/env bash
# stitchpad bridge — push ONE pad snapshot to the relay, once.
# Extracted from bridge.sh so the websocket sidecar (bridge-ws.mjs) and the
# legacy polling bridge share a single payload implementation.
#
#   STITCHPAD_RELAY=... STITCHPAD_TOKEN=... bridge-push-once.sh <path/to/.stitchpad>
set -uo pipefail
RELAY="${STITCHPAD_RELAY:?set STITCHPAD_RELAY}"
TOKEN="${STITCHPAD_TOKEN:?set STITCHPAD_TOKEN}"
padd="${1:?usage: bridge-push-once.sh <path/to/.stitchpad>}"
SP="$(command -v stitchpad || echo "$HOME/.stitchpad/bin/stitchpad")"

api() { curl -fsS -H "authorization: Bearer $TOKEN" -H "content-type: application/json" "$@"; }

[ -f "$padd/stitchpad.md" ] || exit 0
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
for _name in $(echo "[$roster]" | jq -r '.[].name' 2>/dev/null); do
  _model="$(cat "$padd/.state/model.$_name" 2>/dev/null || echo '')"
  _role="$(cat "$padd/.state/role.$_name" 2>/dev/null || echo '')"
  _level="$(cat "$padd/.state/level.$_name" 2>/dev/null || echo '')"
  _persona=""
  _skills='[]'
  _persona_dir="${STITCHPAD_HOME:+$STITCHPAD_HOME/tool/personas}"
  [ -z "$_persona_dir" ] || [ ! -d "$_persona_dir" ] && _persona_dir="$HOME/.stitchpad/personas"
  [ -d "$_persona_dir" ] || _persona_dir="$HOME/.stitchpad/tool/personas"
  _persona_file="$_persona_dir/$(echo "$_name" | tr '[:upper:]' '[:lower:]').md"
  if [ -f "$_persona_file" ]; then
    [ -z "$_role" ] && _role="$(grep -m1 '^ROLE:' "$_persona_file" | sed 's/^ROLE:[[:space:]]*//')"
    [ -z "$_role" ] && _role="$(head -1 "$_persona_file" | sed 's/^# //')"
    _persona="$(grep -m1 '^PERSONA:' "$_persona_file" | sed 's/^PERSONA:[[:space:]]*//')"
    _skills="$(python3 -c "
import json
with open('$_persona_file') as f:
    lines = f.readlines()
in_skills = False
skills = []
for line in lines:
    line = line.strip()
    if line.startswith('SKILLS:'):
        in_skills = True
        continue
    if in_skills and line.startswith('- '):
        parts = line[2:].split(' — ', 1)
        name = parts[0].strip()
        desc = parts[1].strip() if len(parts) > 1 else ''
        skills.append({'name': name, 'desc': desc})
    elif in_skills and not line.startswith('- ') and line:
        break
print(json.dumps(skills))
" 2>/dev/null || echo '[]')"
    [ -z "$_skills" ] && _skills='[]'
  fi
  _adapter="$(echo "[$roster]" | jq -r '.[] | select(.name=="'"$_name"'") | .adapter // ""' 2>/dev/null || echo '')"
  _status="available"
  if [ -f "$padd/.state/dnd.$_name" ]; then
    _status="dnd"
  else
    _last_post_epoch="$(grep -a "^## @$_name" "$padd/stitchpad.md" | tail -1 | grep -o '[0-9]\{2\}:[0-9]\{2\}' | tail -1 | xargs -I{} date -j -f '%H:%M' '{}' +%s 2>/dev/null || echo 0)"
    _now_hour="$(date +%H:%M)"
    _now_epoch="$(date -j -f '%H:%M' "$_now_hour" +%s 2>/dev/null || echo 0)"
    _post_age=$(( _now_epoch - _last_post_epoch ))
    if [ "$_post_age" -gt 0 ] && [ "$_post_age" -lt 90 ]; then
      _status="working"
    fi
  fi
  _online="false"
  _alive="$padd/.state/alive.$_name"
  if [ -f "$_alive" ]; then
    _alive_ts="$(stat -f %m "$_alive" 2>/dev/null || stat -c %Y "$_alive" 2>/dev/null || echo 0)"
    _alive_age=$(( $(date +%s) - _alive_ts ))
    if [ "$_alive_age" -lt 90 ]; then
      _alive_pid="$(grep -o '"pid":[0-9]*' "$_alive" 2>/dev/null | head -1 | cut -d: -f2)"
      [ -n "$_alive_pid" ] && kill -0 "$_alive_pid" 2>/dev/null && _online="true"
    fi
  fi
  profiles="$(echo "$profiles" | jq --arg n "$_name" --arg m "$_model" --arg r "$_role" --arg lv "$_level" --arg p "$_persona" --argjson s "${_skills:-[]}" --arg h "$_adapter" --arg st "$_status" --argjson on "$_online"\
    '. + {($n): {role:$r, level:$lv, persona:$p, skills:$s, model:$m, harness:$h, status:$st, online:$on}}')"
done
# file-write claims (who holds a lease on what) — tolerated absent
claims="$(cd "$proj" && "$SP" claims --json 2>/dev/null || echo '[]')"
echo "$claims" | jq -e . >/dev/null 2>&1 || claims='[]'
# push this pad up (markdown + roster + files + colors + profiles)
jq -nc --arg pad "$md" --argjson roster "[${roster}]" --argjson files "${files:-[]}" --argjson colors "${colors}" --argjson profiles "${profiles}" --argjson claims "${claims}" \
  '{pad:$pad, roster:$roster, files:$files, colors:$colors, profiles:$profiles, claims:$claims}' 2>/dev/null \
  | api -X POST "$RELAY/push?pad=$name" --data-binary @- >/dev/null || exit 1
exit 0
