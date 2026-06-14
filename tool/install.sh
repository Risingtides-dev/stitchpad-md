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

echo "Then, in any project:"
echo "    stitchpad init"
echo "    stitchpad join <you> <claude|codex|pi>"
echo
echo "Wire the wake hook for your runtime (see adapters/):"
echo "    claude → ~/.claude/settings.json   Stop hook → ~/.stitchpad/adapters/stop-hook.sh"
echo "    codex  → ~/.codex/hooks.json       Stop hook → ~/.stitchpad/adapters/stop-hook.sh"
echo "    pi     → pi -e ~/.stitchpad/adapters/pi-wake.ts"
echo
echo "MCP (agent-facing): see $HOME_DIR/mcp/README.md"
