#!/usr/bin/env node
// stitchpad pi-host — run pi as an AUTONOMOUS stitchpad teammate (no terminal).
//
// Why this exists: pi's hooks are suggest-only — no hook can force the agent to
// reply (confirmed across pi-yaml-hooks and oh-my-pi: turn_end is informational,
// no block contract). The only way to COMPEL a reply is to own the loop. This
// host imports stock pi (no fork) and drives it: after each turn it re-checks the
// pad and re-feeds until the mention is actually answered. That IS the enforcement
// claude/codex get from their Stop hook — here it lives in our loop, not pi's core.
//
// It loads your full pi config (createAgentSession's DefaultResourceLoader pulls
// skills, extensions, prompts, models, context from ~/.pi/agent + cwd).
//
//   STITCHPAD_NAME=pi node ~/.stitchpad/hosts/pi-host.mjs     (run in a pad dir)
//
// vs. the extension (tool/adapters/stitchpad): that's for INTERACTIVE pi and is
// suggest-only. This host is for an UNATTENDED worker and is compel + idle-wake.

import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

// pi's SDK lives in the GLOBAL node_modules (pi is a global install), so a bare
// import won't resolve when this host runs from a project dir. Resolve the global
// root once and import the package by absolute path.
const gRoot = execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim();
const { createAgentSession } = await import(
  join(gRoot, "@earendil-works/pi-coding-agent/dist/index.js")
);

const exec = promisify(execFile);
const SP = existsSync(join(homedir(), ".stitchpad/bin/stitchpad"))
  ? join(homedir(), ".stitchpad/bin/stitchpad") : "stitchpad";
const NAME = process.env.STITCHPAD_NAME;
const IDLE_MS = Number(process.env.STITCHPAD_POLL_MS || 4000);

if (!NAME) { console.error("set STITCHPAD_NAME=<your handle>"); process.exit(1); }

const sp = (args) => exec(SP, args, { env: { ...process.env, STITCHPAD_NAME: NAME } })
  .then(r => (r.stdout || "").trim()).catch(() => "");

// Register identity in the pad (roster + pad-default whoami) so wake resolves us.
await sp(["join", NAME, "pi", "push", "-"]);
await sp(["bind-session", "-", NAME]);
console.error(`[stitchpad pi-host] @${NAME} online — watching the pad`);

const { session } = await createAgentSession();   // loads full pi config

// The loop = the enforcement. `wake` prints the unanswered mention (or nothing).
// prompt() runs a real pi turn and resolves when done; then we check again. The
// agent stays driven until the pad shows its reply, so it can't just shrug it off.
let stop = false;
for (const s of ["SIGINT", "SIGTERM"]) process.on(s, async () => { stop = true; await sp(["leave", NAME]); process.exit(0); });

while (!stop) {
  const msg = await sp(["wake", NAME]);
  if (msg) {
    await session.prompt(msg).catch((e) => console.error("[pi-host] turn error:", e?.message));
  } else {
    await new Promise(r => setTimeout(r, IDLE_MS));   // ponytail: poll, not a socket. fine for a worker.
  }
}
