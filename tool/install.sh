#!/usr/bin/env bash
# stitchpad installer — symlinks the CLI + TUI onto your PATH and exposes the
# checkout at a stable path (~/.stitchpad) so the wake adapters resolve from
# hook configs no matter where you cloned the repo.
#
# Usage:
#   ./tool/install.sh            # CLI into ~/.local/bin, home at ~/.stitchpad
#   ./tool/install.sh /usr/local/bin
set -euo pipefail

SRC_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/bin" && pwd)"
HOME_DIR="$(dirname "$SRC_BIN")"          # the tool/ dir = STITCHPAD_HOME
DEST="${1:-$HOME/.local/bin}"
STD_HOME="$HOME/.stitchpad"

mkdir -p "$DEST"
ln -sf "$SRC_BIN/stitchpad"     "$DEST/stitchpad"
ln -sf "$SRC_BIN/stitchpad-tui" "$DEST/stitchpad-tui"

# Stable home symlink so adapters/bin resolve from a fixed path in hook configs.
# (If ~/.stitchpad is already a real dir, leave it; only manage the symlink.)
if [ -L "$STD_HOME" ] || [ ! -e "$STD_HOME" ]; then
  ln -sfn "$HOME_DIR" "$STD_HOME"
  echo "✓ home: $STD_HOME -> $HOME_DIR"
else
  echo "⚠  $STD_HOME exists and is not a symlink — leaving it."
  echo "    Point hook commands at: $HOME_DIR/adapters/  and  $HOME_DIR/bin/"
fi

echo "✓ linked:"
echo "    $DEST/stitchpad     -> $SRC_BIN/stitchpad"
echo "    $DEST/stitchpad-tui -> $SRC_BIN/stitchpad-tui"
echo

case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "⚠  $DEST is not on your PATH — add it:"
     echo "    export PATH=\"$DEST:\$PATH\""; echo;;
esac

# ─── WIRE THE WAKE HOOKS AUTOMATICALLY ───────────────────────────────────────
# The plugin must ship working hooks, not instructions to hand-edit configs.
# Each runtime's Stop hook runs the same stable shim (adapters/stop-hook.sh →
# `stitchpad hook`). Idempotent: only adds if missing. Needs python3 (ships on macOS).
SHIM="$STD_HOME/adapters/stop-hook.sh"

# Claude Code: ~/.claude/settings.json  hooks.Stop[]
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if command -v python3 >/dev/null 2>&1; then
  mkdir -p "$HOME/.claude"
  [ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
  python3 - "$CLAUDE_SETTINGS" "$SHIM" <<'PY' && echo "✓ Claude Stop hook wired ($CLAUDE_SETTINGS)"
import json,sys
p,shim=sys.argv[1],sys.argv[2]
d=json.load(open(p))
hooks=d.setdefault("hooks",{}); stop=hooks.setdefault("Stop",[])
def wired(s): return any(h.get("command")==shim for blk in s for h in blk.get("hooks",[]))
if not wired(stop):
    stop.append({"hooks":[{"type":"command","command":shim,"timeout":15}]})
    json.dump(d,open(p,"w"),indent=2)
PY

  # Claude PreToolUse claim hook (hard-deny on Write/Edit for claimed files)
  CLAIM_SHIM="$STD_HOME/adapters/claim-hook.sh"
  python3 - "$CLAUDE_SETTINGS" "$CLAIM_SHIM" <<'PY' && echo "✓ Claude PreToolUse claim hook wired"
import json,sys
p,shim=sys.argv[1],sys.argv[2]
d=json.load(open(p)); hooks=d.setdefault("hooks",{}); pre=hooks.setdefault("PreToolUse",[])
def wired(s): return any(h.get("command")==shim for blk in s for h in blk.get("hooks",[]))
if not wired(pre):
    pre.append({"matcher":"Write|Edit|MultiEdit","hooks":[{"type":"command","command":shim,"timeout":10}]})
    json.dump(d,open(p,"w"),indent=2)
PY

  # Codex: ~/.codex/hooks.json  hooks.Stop[]
  CODEX_HOOKS="$HOME/.codex/hooks.json"
  if [ -d "$HOME/.codex" ] || [ -f "$CODEX_HOOKS" ]; then
    [ -f "$CODEX_HOOKS" ] || { mkdir -p "$HOME/.codex"; echo '{}' > "$CODEX_HOOKS"; }
    python3 - "$CODEX_HOOKS" "$SHIM" <<'PY' && echo "✓ Codex Stop hook wired ($CODEX_HOOKS)"
import json,sys
p,shim=sys.argv[1],sys.argv[2]
d=json.load(open(p))
hooks=d.setdefault("hooks",{}); stop=hooks.setdefault("Stop",[])
def wired(s): return any(h.get("command")==shim for blk in s for h in blk.get("hooks",[]))
if not wired(stop):
    stop.append({"hooks":[{"type":"command","command":shim,"timeout":15}]})
    json.dump(d,open(p,"w"),indent=2)
PY
  fi
else
  echo "⚠  python3 not found — cannot auto-wire hooks. Wire manually (see adapters/)."
fi

# MCP server deps — install so `node mcp/server.mjs` doesn't crash (-32000).
if [ -f "$HOME_DIR/mcp/package.json" ] && command -v npm >/dev/null 2>&1; then
  ( cd "$HOME_DIR/mcp" && npm install --silent >/dev/null 2>&1 ) \
    && echo "✓ MCP server deps installed ($HOME_DIR/mcp)" \
    || echo "⚠  MCP deps install failed — run: (cd $HOME_DIR/mcp && npm install)"
fi

echo

# ─── MCP SERVER REGISTRATION (idempotent) ──────────────────────────────────
# Same python3 merge pattern as hook wiring above — checks if already
# registered, adds if missing. No duplicate errors, no interactive prompts.
MCP_SERVER="$HOME_DIR/mcp/server.mjs"

# Claude: ~/.claude.json  mcpServers.stitchpad
if command -v python3 >/dev/null 2>&1; then
  python3 - "$CLAUDE_SETTINGS" "$MCP_SERVER" <<'PY' && echo "✓ Claude MCP stitchpad registered ($CLAUDE_SETTINGS)"
import json,sys
p,sp=sys.argv[1],sys.argv[2]
d=json.load(open(p))
srv=d.setdefault("mcpServers",{})
if "stitchpad" not in srv:
    srv["stitchpad"]={"type":"stdio","command":"node","args":[sp],"env":{}}
    json.dump(d,open(p,"w"),indent=2)
PY

  # Codex: ~/.codex/config.toml  [mcp_servers.stitchpad]
  CODEX_CONFIG="$HOME/.codex/config.toml"
  if [ -d "$HOME/.codex" ] || [ -f "$CODEX_CONFIG" ]; then
    [ -f "$CODEX_CONFIG" ] || { mkdir -p "$HOME/.codex"; touch "$CODEX_CONFIG"; }
    if ! grep -q '^\[mcp_servers\.stitchpad\]' "$CODEX_CONFIG" 2>/dev/null; then
      printf '\n[mcp_servers.stitchpad]\ncommand = "node"\nargs = ["%s"]\n' "$MCP_SERVER" >> "$CODEX_CONFIG"
      echo "✓ Codex MCP stitchpad registered ($CODEX_CONFIG)"
    fi
  fi
fi

# Pi: pi install the stitchpad extension (idempotent)
if command -v pi >/dev/null 2>&1; then
  pi install "$HOME_DIR/adapters/stitchpad" 2>/dev/null && echo "✓ Pi stitchpad extension installed" || echo "⚠  Pi extension install failed"
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ stitchpad installed — multi-agent collaboration is wired."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
# Echo back what actually got wired this run (detected, not assumed) so the user
# sees a real system, not a TODO list. Each runtime line only prints if present.
echo "  Wired on this machine:"
command -v claude >/dev/null 2>&1 && echo "    • Claude   — Stop wake + PreToolUse claim hook + MCP"
command -v codex  >/dev/null 2>&1 && echo "    • Codex    — Stop wake hook + MCP"
command -v pi     >/dev/null 2>&1 && echo "    • pi       — wake extension + MCP"
command -v claude >/dev/null 2>&1 || command -v codex >/dev/null 2>&1 || command -v pi >/dev/null 2>&1 || \
  echo "    • (no claude/codex/pi runtime detected — install one, then re-run this)"
echo
echo "  Start a room (in any project):"
echo "    stitchpad init                     # create the pad + start its watcher"
echo "    stitchpad join <you> <claude|codex|pi>"
echo "    export STITCHPAD_NAME=<you>        # so your wake hook knows who you are"
echo "    stitchpad say \"@teammate hello\"     # @mention wakes them"
echo "    stitchpad-tui                      # watch the room live"
echo
echo "  Optional — mirror every pad to the web PWA (login service, survives reboot):"
echo "    STITCHPAD_RELAY=<url> STITCHPAD_TOKEN=<tok> stitchpad bridge install"
echo
echo "  Verify any time:  stitchpad doctor"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
