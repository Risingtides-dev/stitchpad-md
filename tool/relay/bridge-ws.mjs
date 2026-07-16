#!/usr/bin/env node
// stitchpad bridge-ws — realtime Mac bridge (replaces bridge.sh's polling loop).
//
// One websocket per pad into its PadHub Durable Object (role=bridge):
//   inbound  (instant): say → `stitchpad say` · dm → herdr pane injection ·
//                       file → download into <project>/.stitchpad/dropbox/
//   outbound (instant): fs.watch on stitchpad.md → bridge-push-once.sh → the DO
//                       fans the changed pad out to every connected phone.
// Safety nets: full push sweep every 45s (presence/status refresh), HTTP queue
// drain every 30s (catches messages queued while a socket was down).
//
//   STITCHPAD_RELAY=... STITCHPAD_TOKEN=... node bridge-ws.mjs [roots...]
import { execFile, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, watch, writeFileSync, createWriteStream } from "node:fs";
import { readFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import os from "node:os";

const RELAY = process.env.STITCHPAD_RELAY || "https://stitchpad.agentsworld.org";
const TOKEN = process.env.STITCHPAD_TOKEN;
if (!TOKEN) { console.error("[bridge-ws] STITCHPAD_TOKEN required"); process.exit(1); }
const ROOTS = process.argv.slice(2).length ? process.argv.slice(2) : [os.homedir()];
const HOME = os.homedir();
const SP = existsSync(join(HOME, ".stitchpad/bin/stitchpad")) ? join(HOME, ".stitchpad/bin/stitchpad") : "stitchpad";
const PUSH_ONCE = join(dirname(new URL(import.meta.url).pathname), "bridge-push-once.sh");
const HERDR = existsSync(join(HOME, ".local/bin/herdr")) ? join(HOME, ".local/bin/herdr") : "herdr";
const WSURL = RELAY.replace(/^http/, "ws");

const log = (...a) => console.log(`[bridge-ws ${new Date().toISOString().slice(11, 19)}]`, ...a);
const sh = (cmd, args, opts = {}) => new Promise(res => execFile(cmd, args, { timeout: 60000, ...opts }, (err, stdout, stderr) => res({ err, stdout: String(stdout || ""), stderr: String(stderr || "") })));
const api = (path, opts = {}) => fetch(RELAY + path, { ...opts, headers: { authorization: "Bearer " + TOKEN, "content-type": "application/json", ...(opts.headers || {}) } });

// ── pad discovery ────────────────────────────────────────────
function findPads() {
  const out = [];
  for (const r of ROOTS) {
    // find exits non-zero on permission noise under $HOME — stdout is still good.
    // Prune the heavy trees (Library, node_modules, …): full-home scans were the
    // old bridge's slowest leg by far.
    const res = spawnSync("find", [r, "-maxdepth", "4",
      "(", "-name", "Library", "-o", "-name", "node_modules", "-o", "-name", ".Trash",
      "-o", "-name", ".git", "-o", "-name", ".nvm", "-o", "-name", ".cache",
      "-o", "-name", "target", "-o", "-name", ".cargo", "-o", "-name", ".rustup", ")", "-prune",
      "-o", "-type", "d", "-name", ".stitchpad", "-print"], { timeout: 60000 });
    for (const p of String(res.stdout || "").split("\n")) {
      if (!p || p.includes("/.stitchpad/.stitchpad")) continue;
      if (existsSync(join(p, "stitchpad.md"))) out.push(p);
    }
  }
  return [...new Set(out)].sort();
}

// ── per-pad connection ───────────────────────────────────────
const pads = new Map(); // padd → {name, proj, ws, watcher, pushT, tries, closed}

function pushPad(p, why) {
  clearTimeout(p.pushT);
  p.pushT = setTimeout(async () => {
    const { err } = await sh("bash", [PUSH_ONCE, p.padd], { env: { ...process.env, STITCHPAD_RELAY: RELAY, STITCHPAD_TOKEN: TOKEN } });
    if (err) log(p.name, "push failed:", err.message?.slice(0, 120));
    else if (why !== "sweep") log(p.name, "pushed (" + why + ")");
  }, 250); // debounce bursts of fs events
}

async function onSay(p, msg) {
  const { from, text } = msg;
  if (!text) return;
  await sh(SP, ["say", text], { cwd: p.proj, env: { ...process.env, STITCHPAD_NAME: from || "smaths" } });
  log(p.name, `← @${from}: ${text.slice(0, 50)}`);
  pushPad(p, "say"); // echo lands on phones immediately, not next sweep
}

async function onDm(p, msg) {
  const { from, to, text } = msg;
  if (!to || !text) return;
  let delivered = false;
  const { stdout: roster } = await sh(SP, ["roster"], { cwd: p.proj });
  const row = roster.split("\n").find(l => l.split("|")[0] === to);
  const [, adapter, , target] = (row || "").split("|");
  if (adapter === "herdr" && target && target !== "-") {
    const { stdout: info } = await sh(HERDR, ["agent", "get", target]);
    const pane = (info.match(/"pane_id"\s*:\s*"([^"]*)"/) || [])[1];
    if (pane) {
      const dmsg = `stitchpad DM from @${from} (private — not on the pad; reply lands on the pad unless they DM you back): ${text}`
        .replace(/[\x00-\x1f\x7f]/g, " ").replace(/ +/g, " ");
      const { err } = await sh(HERDR, ["pane", "run", pane, dmsg]);
      delivered = !err;
    }
  }
  if (delivered) log(p.name, `DM @${from} → @${to} terminal (${text.slice(0, 40)})`);
  else {
    await sh(SP, ["say", `@${to} (dm — terminal unreachable) ${text}`], { cwd: p.proj, env: { ...process.env, STITCHPAD_NAME: from || "smaths" } });
    log(p.name, `DM @${from} → @${to} FELL BACK to pad (no live pane)`);
    pushPad(p, "dm-fallback");
  }
}

async function onFile(p, msg) {
  const { name, key } = msg;
  if (!name || !key) return;
  const drop = join(p.padd, "dropbox");
  mkdirSync(drop, { recursive: true });
  try {
    const r = await api("/f/" + key.replace(/^files\//, ""));
    if (!r.ok) throw new Error("HTTP " + r.status);
    writeFileSync(join(drop, name.replace(/[\/\\]/g, "_")), Buffer.from(await r.arrayBuffer()));
    log(p.name, `📎 ${name} → .stitchpad/dropbox/`);
  } catch (e) { log(p.name, `📎 FAILED ${name}: ${e.message}`); }
}

function connect(p) {
  if (p.closed) return;
  const ws = new WebSocket(`${WSURL}/ws?pad=${encodeURIComponent(p.name)}&role=bridge&token=${TOKEN}`);
  p.ws = ws;
  ws.onopen = () => { p.tries = 0; log(p.name, "socket up"); drainQueues(p); };
  ws.onmessage = async e => {
    let m; try { m = JSON.parse(e.data); } catch { return; }
    if (m.type === "say") await onSay(p, m.msg || {});
    else if (m.type === "dm") await onDm(p, m.msg || {});
    else if (m.type === "file") await onFile(p, m.msg || {});
  };
  ws.onclose = () => { if (p.ws !== ws || p.closed) return; p.ws = null; setTimeout(() => connect(p), Math.min(30000, 1000 * 2 ** (p.tries++))); };
  ws.onerror = () => { try { ws.close(); } catch {} };
}

// drain any messages that queued in KV while our socket was down
async function drainQueues(p) {
  for (const [box, handler] of [["outbox", onSay], ["dmbox", onDm], ["filebox", onFile]]) {
    try {
      const r = await api(`/${box}?pad=${encodeURIComponent(p.name)}`);
      if (!r.ok) continue;
      for (const m of (await r.json()).messages || []) await handler(p, m);
    } catch {}
  }
}

function track(padd) {
  if (pads.has(padd)) return;
  const proj = dirname(padd);
  const p = { padd, proj, name: basename(proj), ws: null, watcher: null, pushT: null, tries: 0, closed: false };
  pads.set(padd, p);
  try {
    p.watcher = watch(join(padd, "stitchpad.md"), () => pushPad(p, "fs"));
  } catch { /* file may briefly not exist; sweep still covers it */ }
  connect(p);
  pushPad(p, "startup");
  log("tracking", p.name);
}

// ── main ─────────────────────────────────────────────────────
log(`relay=${RELAY} roots=${ROOTS.join(",")} (websocket mode)`);
findPads().forEach(track);
setInterval(() => findPads().forEach(track), 60000);              // new pads appear live
setInterval(() => pads.forEach(p => pushPad(p, "sweep")), 45000); // presence/status refresh
setInterval(() => pads.forEach(p => p.ws?.readyState === 1 ? p.ws.send('{"type":"ping"}') : null), 25000);
setInterval(() => pads.forEach(p => { if (!p.ws || p.ws.readyState !== 1) drainQueues(p); }), 30000);
// heartbeat file so `stitchpad doctor` can see the bridge is alive
setInterval(() => pads.forEach(p => {
  try { writeFileSync(join(p.padd, ".state", "bridge-heartbeat"), JSON.stringify({ ts: new Date().toISOString(), pad: p.name, mode: "ws" })); } catch {}
}), 15000);
