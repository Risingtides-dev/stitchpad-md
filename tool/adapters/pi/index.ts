// stitchpad ← pi adapter (extension).
//
// Pi has no shell-hook system like claude/codex. Its equivalent is the in-process
// extension API (the `pi` object below). This extension is the thin bridge that
// makes pi behave like the claude/codex Stop hook: when the agent goes idle it
// runs the shared `stitchpad wake` command and, if there are messages addressed
// to it, delivers them back into the session as the next turn.
//
// One brain, three adapters: claude.sh / codex (Stop hook) and this file all call
// the SAME `stitchpad wake` command. The only per-runtime part is how the result
// is fed back in — here it's pi.sendMessage(triggerTurn, nextTurn), pi's native
// equivalent of {"decision":"block","reason":...}.
//
// Install (persistent):
//   pi install <path-to-this-dir>        # registers in ~/.pi/agent/settings.json
// Or one session:
//   pi -e <path-to-this-dir>/index.ts
//
// Identity is resolved by the CLI from the pad's .state/whoami (written when the
// agent joins via the MCP `join` tool or `stitchpad join`). No hardcoded name —
// STITCHPAD_NAME only overrides if you choose to pin one.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";

const exec = promisify(execFile);

// Locate the stitchpad CLI: PATH first, then the standard install location.
function stitchpadBin(): string {
  const fallback = join(homedir(), ".stitchpad", "bin", "stitchpad");
  return existsSync(fallback) ? fallback : "stitchpad";
}

export default function stitchpadExtension(pi: ExtensionAPI) {
  const bin = stitchpadBin();
  const pinned = process.env.STITCHPAD_NAME || "";
  const args = pinned ? ["wake", pinned] : ["wake"];

  // The shared drain: ask the CLI for any new @me messages since our cursor.
  // Empty stdout = nothing new → we do nothing (no turn burned). This is the
  // exact "skip when nothing's new" behavior the Stop hook has.
  async function drain(ctx: ExtensionContext) {
    // Only deliver when the agent is actually idle — otherwise sendMessage would
    // collide with an in-flight turn ("already processing").
    if (!ctx.isIdle()) return;
    try {
      const { stdout } = await exec(bin, args, { cwd: ctx.cwd, timeout: 10_000 });
      const msg = stdout.trim();
      if (!msg) return; // nothing addressed to me → skip
      await pi.sendMessage(
        { customType: "stitchpad_message", content: msg, display: true },
        { triggerTurn: true, deliverAs: "nextTurn" }
      );
    } catch {
      // CLI missing / no pad here / non-zero exit → silently no-op.
    }
  }

  // agent_end is pi's true-idle moment (the whole agent run finished) — the real
  // equivalent of claude/codex "Stop". Drain there so a message starts a fresh
  // turn cleanly rather than colliding with an in-progress one.
  pi.on("agent_end", async (_event, ctx) => {
    await drain(ctx);
  });

  // Also drain once at session start so a message that arrived while the agent
  // was offline is picked up on launch.
  pi.on("session_start", async (_event, ctx) => {
    await drain(ctx);
  });
}
