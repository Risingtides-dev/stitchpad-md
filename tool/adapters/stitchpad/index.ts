// stitchpad ← pi extension (self-contained: tools + wake).
//
// earendil pi (@earendil-works/pi-coding-agent) has NO built-in MCP — by design
// (usage.md: "intentionally does not include built-in MCP ... build or install
// as extensions or packages"). So unlike claude/codex (which get stitchpad via
// the MCP server), pi gets everything from THIS extension:
//   - registers join/say/read/who/leave as native pi tools (pi.registerTool)
//   - wakes at agent_end by draining the pad and steering messages in
//
// Identity: pi exposes no per-session id, so we use the pad-default identity
// (.state/whoami, written by `join`). One pi per pad — that's correct, not a
// collision. STITCHPAD_NAME overrides if you want to pin one.
//
// Install:  pi install <this-dir>     ·     One session:  pi -e <this-dir>/index.ts

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const exec = promisify(execFile);

function stitchpadBin(): string {
  const fallback = join(homedir(), ".stitchpad", "bin", "stitchpad");
  return existsSync(fallback) ? fallback : "stitchpad";
}

export default function stitchpadExtension(pi: ExtensionAPI) {
  const bin = stitchpadBin();
  const pinned = process.env.STITCHPAD_NAME || "";
  // Track the per-instance session key set during join (e.g. KITTY_WINDOW_ID).
  // This lets sp_me() resolve via sessions/<key> instead of shared whoami.
  let sessionKey = "";

  // Run a stitchpad CLI command in the session's cwd. `name` pins STITCHPAD_NAME
  // so the CLI derives the sender from identity, never a trusted arg.
  // Also exports STITCHPAD_SESSION so sp_me() resolves via sessions/<key>.
  async function sp(args: string[], cwd: string, name?: string): Promise<string> {
    const env = {
      ...process.env,
      ...(name ? { STITCHPAD_NAME: name } : {}),
      ...(sessionKey ? { STITCHPAD_SESSION: sessionKey } : {}),
    };
    const { stdout, stderr } = await exec(bin, args, { cwd, timeout: 10_000, env });
    return (stdout || "") + (stderr ? `\n${stderr}` : "");
  }
  const ok = (text: string) => ({ content: [{ type: "text" as const, text: text.trim() || "(ok)" }], details: {} });

  // ── Tools (native pi, no MCP) ──────────────────────────────────────
  pi.registerTool({
    name: "stitchpad_join",
    label: "stitchpad: join",
    description: "Join the stitchpad (shared agent chat for this project): pick your handle. Call once at startup. After joining, @your-name mentions wake you at turn-end.",
    parameters: Type.Object({ name: Type.String({ description: "Your handle, e.g. 'pi'." }) }),
    async execute(_id, params, _sig, _upd, ctx) {
      // Capture this kitty window as the wake target (socket|window_id) so the
      // watcher can kitty-wake this pi. We run inside pi = we see the env.
      const sock = process.env.KITTY_LISTEN_ON || "";
      const win = process.env.KITTY_WINDOW_ID || "";
      const target = sock && win ? `${sock}@@${win}` : "-";   // @@ not | (roster is pipe-delimited)
      if (sock && win) {
        const k = "/Applications/kitty.app/Contents/MacOS/kitty";
        await exec(k, ["@", "--to", sock, "set-window-title", "--match", `id:${win}`, `🧵 ${params.name}`]).catch(() => {});
        await exec(k, ["@", "--to", sock, "set-tab-title", "--match", `id:${win}`, `🧵 ${params.name}`]).catch(() => {});
      }
      await sp(["join", params.name, "kitty", "push", target], ctx.cwd).catch(() => {});
      // Use KITTY_WINDOW_ID as session key (not shared "-") so multiple pi
      // agents on the same pad each get their own identity in sessions/<winid>.
      // Falls back to shared whoami only when no kitty window is available.
      sessionKey = win || "-";
      await sp(["bind-session", sessionKey, params.name], ctx.cwd).catch(() => {});
      return ok(`joined as @${params.name}${target === "-" ? " (no kitty window — external wake off)" : ""}. Reply with the stitchpad_say tool.`);
    },
  });

  pi.registerTool({
    name: "stitchpad_say",
    label: "stitchpad: say",
    description: "Post a message to the stitchpad as yourself. Start the text with @name to address + wake a teammate. Use this to reply when woken with an incoming message.",
    parameters: Type.Object({ text: Type.String({ description: "The message. Start with @name to address someone." }) }),
    async execute(_id, params, _sig, _upd, ctx) {
      return ok(await sp(["say", params.text], ctx.cwd, pinned || undefined));
    },
  });

  pi.registerTool({
    name: "stitchpad_read",
    label: "stitchpad: read",
    description: "Read the recent stitchpad conversation.",
    parameters: Type.Object({ lines: Type.Optional(Type.Number({ description: "Trailing lines (default 80)." })) }),
    async execute(_id, params, _sig, _upd, ctx) {
      return ok(await sp(["read", "-n", String(params.lines || 80)], ctx.cwd));
    },
  });

  pi.registerTool({
    name: "stitchpad_who",
    label: "stitchpad: who",
    description: "List who is in the stitchpad (the roster).",
    parameters: Type.Object({}),
    async execute(_id, _params, _sig, _upd, ctx) { return ok(await sp(["roster"], ctx.cwd)); },
  });

  pi.registerTool({
    name: "stitchpad_leave",
    label: "stitchpad: leave",
    description: "Leave the stitchpad: remove yourself from the roster and post a departure note.",
    parameters: Type.Object({}),
    async execute(_id, _params, _sig, _upd, ctx) { return ok(await sp(["leave"], ctx.cwd, pinned || undefined)); },
  });

  // ── Wake (agent_end = pi's idle moment, the claude/codex Stop equivalent) ──
  async function drain(ctx: ExtensionContext) {
    if (!ctx.isIdle()) return;   // don't collide with an in-flight turn
    try {
      const args = pinned ? ["wake", pinned] : ["wake"];
      const { stdout } = await exec(bin, args, { cwd: ctx.cwd, timeout: 10_000 });
      const msg = stdout.trim();
      if (!msg) return;
      await pi.sendMessage(
        { customType: "stitchpad_message", content: msg, display: true },
        { triggerTurn: true, deliverAs: "nextTurn" }
      );
    } catch {
      // no pad here / CLI missing / non-zero → silent no-op
    }
  }

  pi.on("agent_end", async (_e, ctx) => { await drain(ctx); });
  pi.on("session_start", async (_e, ctx) => { await drain(ctx); });
}
