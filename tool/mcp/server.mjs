#!/usr/bin/env node
// stitchpad MCP server — the agent-facing side of stitchpad.
//
// The MCP is the ROSTER + TALKING surface. An agent adds this server and, at
// startup, calls `join` to pick its name and declare which runtime it is. The
// runtime's wake hook still needs STITCHPAD_NAME pinned to that name. The MCP
// does NOT do the wake itself.
//
// Tools:
//   join  — add yourself to the roster
//   say   — post a message to the pad (start with @name to address a teammate)
//   read  — read the recent conversation
//   who   — list the roster
//
// There is intentionally no `wait_for_mention`: the wake is the runtime's own
// turn-end hook reading the pad, not an MCP poll. MCP = register + talk; the
// hook does the waking.
//
// All state lives in stitchpad.md + the isolated git, written via the `stitchpad`
// CLI so there is exactly one implementation of roster/commit logic.

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { execFile } from "node:child_process";
import { readdir } from "node:fs/promises";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import path from "node:path";

const execFileP = promisify(execFile);

// Resolve the stitchpad CLI relative to this file: tool/mcp/server.mjs -> tool/bin/stitchpad
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const STITCHPAD_HOME = path.resolve(__dirname, "..");
const CLI = path.join(STITCHPAD_HOME, "bin", "stitchpad");

// Where is the pad? An agent's cwd is the project; the CLI walks up for .stitchpad.
// Allow override via STITCHPAD_CWD (the dir to resolve the pad from).
const PAD_CWD = process.env.STITCHPAD_CWD || process.cwd();

// `me` pins STITCHPAD_NAME for this call so the CLI derives the sender from
// identity, not a trusted arg.
async function sp(args, me, extraEnv = {}) {
  const { stdout, stderr } = await execFileP(CLI, args, {
    cwd: PAD_CWD,
    env: { ...process.env, STITCHPAD_HOME, ...extraEnv, ...(me ? { STITCHPAD_NAME: me } : {}) },
    maxBuffer: 1024 * 1024,
  });
  return (stdout || "") + (stderr ? `\n${stderr}` : "");
}

function envValue(text, key) {
  const match = text.match(new RegExp(`(?:^|\\s)${key}=([^\\s]+)`));
  return match ? match[1] : "";
}

async function parentKittyEnv() {
  try {
    const { stdout } = await execFileP("ps", ["eww", "-p", String(process.ppid), "-o", "command="], {
      maxBuffer: 1024 * 1024,
    });
    return {
      sock: envValue(stdout, "KITTY_LISTEN_ON") || envValue(stdout, "KITTY_SOCKET"),
      win: envValue(stdout, "KITTY_WINDOW_ID"),
    };
  } catch {
    return { sock: "", win: "" };
  }
}

async function kittySockets(preferred) {
  const sockets = [];
  const add = (sock) => {
    if (sock && !sockets.includes(sock)) sockets.push(sock);
  };
  add(preferred);
  try {
    for (const entry of await readdir("/tmp")) {
      if (entry.startsWith("kitty-")) add(`unix:/tmp/${entry}`);
    }
  } catch {
    // No socket directory or no permission; join can still fall back to hook wake.
  }
  return sockets;
}

function findWindowForPid(kittyState, pid) {
  const needle = Number(pid);
  for (const osWindow of kittyState) {
    for (const tab of osWindow.tabs || []) {
      for (const win of tab.windows || []) {
        if (Number(win.pid) === needle) return win.id;
        for (const proc of win.foreground_processes || []) {
          if (Number(proc.pid) === needle) return win.id;
        }
      }
    }
  }
  return "";
}

async function discoverKittyTarget() {
  let sock = process.env.KITTY_LISTEN_ON || process.env.KITTY_SOCKET || "";
  let win = process.env.KITTY_WINDOW_ID || "";

  if (!sock || !win) {
    const parentEnv = await parentKittyEnv();
    sock ||= parentEnv.sock;
    win ||= parentEnv.win;
  }
  if (sock && win) return { sock, win };

  for (const candidate of await kittySockets(sock)) {
    try {
      const { stdout } = await execFileP("kitty", ["@", "--to", candidate, "ls"], {
        maxBuffer: 4 * 1024 * 1024,
      });
      const found = findWindowForPid(JSON.parse(stdout), process.ppid);
      if (found) return { sock: candidate, win: String(found) };
    } catch {
      // Try the next socket.
    }
  }
  return { sock: "", win: "" };
}

// ── Identity, server-side ─────────────────────────────────────────────
// This server process serves exactly ONE agent session. The agent declares its
// name once via join(); we hold it here in memory so say/reply derive the sender
// — the agent never passes a name, so it cannot post as anyone else. We also
// write .state/sessions/<session_id> = name so the (separate) Stop-hook process
// can resolve the same identity from its payload's session_id.
let ME = null;                                   // the joined name; null until join
const SESSION_ID =
  process.env.STITCHPAD_SESSION ||
  process.env.CLAUDE_CODE_SESSION_ID ||
  process.env.CODEX_SESSION_ID ||
  "";

async function bindSession(name, extraEnv = {}) {
  ME = name;
  // With a session id (claude/codex): bind sessions/<id> so the Stop hook resolves
  // it from its payload. Without one (pi exposes no session id): bind the pad-level
  // default identity, which the pi extension's wake reads. pi is single-identity
  // per pad, so a pad default is correct, not a collision risk.
  const arg = SESSION_ID || "-";   // "-" = pad default (see CLI bind-session)
  await sp(["bind-session", arg, name], name, extraEnv).catch(() => {});
}

const server = new Server(
  { name: "stitchpad", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

const TOOLS = [
  {
    name: "join",
    description:
      "Join the stitchpad: pick your handle and declare your runtime. Call once " +
      "at startup. Your runtime's wake hook must also be pinned with " +
      "STITCHPAD_NAME=<your-name> so it knows to deliver messages addressed to " +
      "@you. After joining, you'll be woken at each turn-end whenever someone " +
      "posts a line starting with @your-name.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Your handle in the room, e.g. 'larry'." },
        adapter: {
          type: "string",
          enum: ["claude", "codex", "pi"],
          description:
            "Which runtime you are — selects how you get woken: claude/codex via " +
            "their Stop hook, pi via the pi adapter extension. All read the pad at " +
            "turn-end; no keystrokes are sent to your terminal.",
        },
      },
      required: ["name", "adapter"],
    },
  },
  {
    name: "say",
    description:
      "Post a message to the stitchpad as yourself (the name you joined as — the " +
      "server knows who you are, you cannot post as anyone else). To address a " +
      "teammate and wake them, start your text with @their-name. This is also how " +
      "you reply when the wake hook blocks you with an incoming message.",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "The message. Start with @name to address+wake someone." },
      },
      required: ["text"],
    },
  },
  {
    name: "read",
    description: "Read the recent stitchpad conversation.",
    inputSchema: {
      type: "object",
      properties: {
        lines: { type: "number", description: "How many trailing lines to show (default 80).", default: 80 },
      },
    },
  },
  {
    name: "who",
    description: "List who is in the room (the parsed roster).",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "leave",
    description:
      "Leave the stitchpad: remove yourself from the roster and post a departure " +
      "note. Call when you're done collaborating or shutting down.",
    inputSchema: { type: "object", properties: {} },
  },
];

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: a = {} } = req.params;
  try {
    let out;
    switch (name) {
      case "join": {
        const adapter = a.adapter;
        if (!["claude", "codex", "pi"].includes(adapter)) {
          return text("adapter must be one of: claude, codex, pi");
        }
        // Capture this kitty window as the wake target. Codex may scrub KITTY_*
        // from the MCP child even when the parent Codex process is in kitty, so
        // recover it from the parent env or kitty's window list when needed.
        const { sock, win } = await discoverKittyTarget();
        const target = sock && win ? `${sock}@@${win}` : "-";   // @@ not | (roster is pipe-delimited)
        const kittyEnv = sock && win ? { KITTY_LISTEN_ON: sock, KITTY_WINDOW_ID: win } : {};
        // Tag the kitty window+tab with the agent's name so you can see who's who.
        if (sock && win) {
          await execFileP("kitty", ["@", "--to", sock, "set-window-title", "--match", `id:${win}`, `🧵 ${a.name}`]).catch(() => {});
          await execFileP("kitty", ["@", "--to", sock, "set-tab-title", "--match", `id:${win}`, `🧵 ${a.name}`]).catch(() => {});
        }
        // adapter column = "kitty" (the universal wake); runtime metadata records
        // the actual harness (claude/codex/pi) for TUI roster classifiers.
        out = await sp(["join", a.name, "kitty", "push", target], undefined, kittyEnv);
        await sp(["meta", "set", a.name, "runtime", adapter]).catch(() => {});
        const model =
          process.env.STITCHPAD_MODEL ||
          process.env.CODEX_MODEL ||
          process.env.CLAUDE_MODEL ||
          process.env.ANTHROPIC_MODEL ||
          "";
        if (model) {
          await sp(["meta", "set", a.name, "model", model]).catch(() => {});
        }
        await bindSession(a.name, kittyEnv);   // hold identity + write session record for the hook
        out += target === "-"
          ? `\n(you are @${a.name}, but no kitty window detected — external wake won't work unless you run in kitty. Hook-based turn-end wake still applies.)`
          : `\n(you are @${a.name}; @${a.name} mentions wake this kitty window. Reply with the say tool — identity is fixed server-side.)`;
        break;
      }
      case "say":
        if (!ME) return text("call join first — you have no identity in this stitchpad yet.", true);
        out = await sp(["say", a.text], ME);   // sender derived from server memory, never the agent
        break;
      case "read":
        out = await sp(["read", "-n", String(a.lines || 80)]);
        break;
      case "who":
        out = await sp(["roster"]);
        break;
      case "leave":
        if (!ME) return text("you haven't joined this stitchpad.", true);
        out = await sp(["leave", ME], ME);
        ME = null;
        break;
      default:
        return text(`unknown tool: ${name}`, true);
    }
    return text(out.trim() || "(ok)");
  } catch (err) {
    return text(`stitchpad error: ${err.stderr || err.message}`, true);
  }
});

function text(s, isError = false) {
  return { content: [{ type: "text", text: s }], isError };
}

// Auto-leave when the agent's session ends (the runtime kills this server).
// Best-effort + synchronous-ish: post the departure note before we exit.
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, async () => {
    if (ME) await sp(["leave", ME], ME).catch(() => {});
    process.exit(0);
  });
}

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("[stitchpad-mcp] ready");
