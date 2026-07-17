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
import { execFile, spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, watch, writeFileSync, readFileSync, readdirSync, truncateSync, statSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import os from "node:os";

const RELAY = process.env.STITCHPAD_RELAY || "https://stitchpad.agentsworld.org";
const TOKEN = process.env.STITCHPAD_TOKEN;
if (!TOKEN) { console.error("[bridge-ws] STITCHPAD_TOKEN required"); process.exit(1); }
const ROOTS = process.argv.slice(2).length ? process.argv.slice(2) : [os.homedir()];
// optional allowlist: STITCHPAD_PADS="ocean-surface,ocean-os" → only these sync
const ONLY = (process.env.STITCHPAD_PADS || "").split(",").map(s => s.trim()).filter(Boolean);
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
      if (ONLY.length && !ONLY.includes(basename(dirname(p)))) continue;
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

// resolve an agent's live herdr pane: roster herdr target, else the terminal
// its HEARTBEAT records (pull-mode agents live somewhere too)
async function resolvePane(p, name) {
  const { stdout: roster } = await sh(SP, ["roster"], { cwd: p.proj });
  const row = roster.split("\n").find(l => l.split("|")[0] === name);
  let [, adapter, , target] = (row || "").split("|");
  if (adapter !== "herdr" || !target || target === "-") {
    try {
      const hb = JSON.parse(readFileSync(join(p.padd, ".state", "alive." + name), "utf8"));
      if (hb.surface) { adapter = "herdr"; target = hb.surface; }
    } catch {}
  }
  if (adapter !== "herdr" || !target || target === "-") return null;
  // ONE TERMINAL = ONE PAD: refuse routing a DM into a terminal that is live in
  // a different pad or under a different name (~/.stitchpad-terminals registry).
  try {
    const surface = target.split("@@").pop();
    const [lpad, lname, lts] = readFileSync(join(HOME, ".stitchpad-terminals", surface), "utf8").trim().split("|");
    if (Date.now() / 1000 - (+lts || 0) < 300 && (lpad !== p.padd || lname !== name)) {
      log(p.name, `CROSS-PAD BLOCKED: DM for @${name} — terminal ${surface} is live as @${lname} in ${lpad}`);
      return null;
    }
  } catch {}
  const { stdout: info } = await sh(HERDR, ["agent", "get", target]);
  return (info.match(/"pane_id"\s*:\s*"([^"]*)"/) || [])[1] || null;
}

// DM pane content: the agent's TERMINAL SESSION rendered as chat — the
// operator's injected messages (user turns) and the agent's replies (assistant
// turns), read from the harness session transcript. Claude Code writes
// ~/.claude/projects/<proj-slug>/<session-id>.jsonl; the freshest session
// bound to this agent name in .state/sessions is the live one.
function sessionTranscript(p, agent) {
  const sdir = join(p.padd, ".state", "sessions");
  let best = null;
  try {
    for (const f of readdirSync(sdir)) {
      try {
        if (readFileSync(join(sdir, f), "utf8").trim() !== agent) continue;
        const t = join(HOME, ".claude", "projects", p.proj.replaceAll("/", "-"), f + ".jsonl");
        if (!existsSync(t)) continue;
        const m = statSync(t).mtimeMs;
        if (!best || m > best.m) best = { t, m };
      } catch {}
    }
  } catch {}
  return best?.t || null;
}
function parseTranscript(file) {
  const msgs = [];
  for (const line of readFileSync(file, "utf8").split("\n")) {
    if (!line.trim()) continue;
    let e; try { e = JSON.parse(line); } catch { continue; }
    if (e.isMeta || !e.message) continue;
    const at = e.timestamp ? Date.parse(e.timestamp) : 0;
    const c = e.message.content;
    if (e.type === "user") {
      // only real typed/injected text — skip tool results and harness noise
      const text = typeof c === "string" ? c : (Array.isArray(c) ? c.filter(b => b.type === "text").map(b => b.text).join("\n") : "");
      if (!text || text.startsWith("<") || text.startsWith("Caveat:")) continue;
      msgs.push({ role: "user", text: text.slice(0, 4000), at });
    } else if (e.type === "assistant") {
      const text = Array.isArray(c) ? c.filter(b => b.type === "text").map(b => b.text).join("\n") : "";
      if (!text.trim()) continue;
      // consecutive assistant chunks of one turn → merge
      const last = msgs[msgs.length - 1];
      if (last && last.role === "assistant" && at - last.at < 120000) last.text = (last.text + "\n\n" + text).slice(0, 8000);
      else msgs.push({ role: "assistant", text: text.slice(0, 8000), at });
    }
  }
  return msgs.slice(-60);
}
async function onTerm(p, msg) {
  const agent = msg.agent; if (!agent) return;
  let out = { agent, msgs: null, error: "", at: Date.now() };
  const file = sessionTranscript(p, agent);
  if (file) { try { out.msgs = parseTranscript(file); } catch (e) { out.error = "transcript parse failed: " + e.message; } }
  else out.error = "no session transcript for @" + agent + " (non-claude harness or session not bound)";
  const r = await api(`/term-in?pad=${encodeURIComponent(p.name)}`, { method: "POST", body: JSON.stringify(out) }).catch(e => ({ ok: false, statusText: e.message }));
  log(p.name, `session-chat @${agent}: ${out.error || (out.msgs?.length + " msgs")} → posted ${r.ok ? "ok" : "FAILED " + (r.status || r.statusText)}`);
}

// commands that open interactive dialogs/pickers — dead ends from a phone
const MODAL_CMDS = new Set(["status", "config", "permissions", "help", "doctor", "login", "logout", "exit", "quit", "vim", "hooks", "mcp", "agents", "resume", "theme", "terminal-setup", "install-github-app", "ide", "bug"]);
const OCEAN_URL = process.env.OCEAN_DAEMON_URL || "http://127.0.0.1:4780";
// delivery receipts: report each DM's outcome back to the relay (stamps the
// pair-log entry + pushes a live {type:"dmstatus"} to the phone) and remember
// the last outcome per agent for the doctor snapshot.
const LAST_DM = {};   // "<pad>:<agent>" → {at, status, detail}
async function dmStatus(p, msg, status, detail) {
  LAST_DM[`${p.name}:${msg.to}`] = { at: Date.now(), status, detail };
  if (!msg.id) return;
  await api(`/dm-status?pad=${encodeURIComponent(p.name)}`, {
    method: "POST",
    body: JSON.stringify({ id: msg.id, from: msg.from, to: msg.to, status, detail }),
  }).catch(() => {});
}
async function onDm(p, msg) {
  const { from, to, text } = msg;
  if (!to || !text) return;
  let delivered = false;
  // OCEAN-ADAPTER agents live as daemon sessions, not terminals — deliver the
  // DM as a turn on their session. (Without this, the heartbeat-surface
  // fallback routed @ocean DMs into whatever terminal last started its
  // heartbeat — the operator's own, in practice.)
  try {
    const { stdout: roster } = await sh(SP, ["roster"], { cwd: p.proj });
    const row = (roster.split("\n").find(l => l.split("|")[0] === to) || "").split("|").map(s => (s || "").trim());
    if (row[1] === "ocean" && row[3] && row[3] !== "-") {
      const prompt = `stitchpad DM from @${from} (private — not on the pad): ${text}\n\nReply PRIVATELY (do not post on the pad) with:\n  cd ${p.proj} && STITCHPAD_NAME=${to} ~/.stitchpad/bin/stitchpad dm ${from} '<your reply>'`;
      const r = await fetch(`${OCEAN_URL}/v1/agent/turns`, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ session_id: row[3], prompt, cwd: p.proj, client_type: "stitchpad" }),
      });
      if (r.ok) { log(p.name, `DM @${from} → @${to} ocean daemon turn (${text.slice(0, 40)})`); await dmStatus(p, msg, "delivered", "daemon session"); return; }
      log(p.name, `DM @${from} → @${to} daemon POST ${r.status} — falling back`);
    }
  } catch {}
  const pane = await resolvePane(p, to);
  {
    if (pane) {
      // A DM starting with "/" is a REAL slash command for the harness — inject
      // it raw (no DM wrapper, which would turn it into chat text). Modal
      // commands are refused: they open a dialog nobody on a phone can Esc out
      // of, freezing the agent's terminal.
      const clean = text.replace(/[\x00-\x1f\x7f]/g, " ").replace(/ +/g, " ").trim();
      const cmd = (clean.match(/^\/([a-zA-Z0-9_:-]+)/) || [])[1]?.toLowerCase();
      if (cmd && MODAL_CMDS.has(cmd)) {
        log(p.name, `DM @${from} → @${to} refused modal /${cmd}`);
        await dmStatus(p, msg, "refused", `/${cmd} is interactive-only`);
        await api(`/dm-in?pad=${encodeURIComponent(p.name)}`, { method: "POST", body: JSON.stringify({ from: to, to: from, text: `⚠ /${cmd} opens a dialog only a keyboard can close — not sent. Commands that work from here: /compact, /clear, /model <name>, or any skill.`, at: Date.now() }) }).catch(() => {});
        return;
      }
      const dmsg = cmd ? clean
        : `stitchpad DM from @${from} (private — not on the pad; reply lands on the pad unless they DM you back): ${clean}`;
      const { err } = await sh(HERDR, ["pane", "run", pane, dmsg]);
      delivered = !err;
      if (delivered) {
        // SETTLE-RETRY: the Enter from `pane run` can fire before the TUI
        // finishes ingesting the paste, leaving the text parked in the input
        // box. After a beat, one bare Enter submits it; if it already went
        // through, a bare Enter on an empty input is a no-op. (Same trick as
        // the wake adapter.)
        await new Promise(r => setTimeout(r, 2000));
        await sh(HERDR, ["pane", "run", pane, ""]).catch(() => {});
      }
      if (delivered && cmd) log(p.name, `DM @${from} → @${to} slash /${cmd} injected raw`);
    }
  }
  if (delivered) {
    log(p.name, `DM @${from} → @${to} terminal (${text.slice(0, 40)})`);
    await dmStatus(p, msg, "delivered", "terminal");
  } else {
    await sh(SP, ["say", `@${to} (dm — terminal unreachable) ${text}`], { cwd: p.proj, env: { ...process.env, STITCHPAD_NAME: from || "smaths" } });
    log(p.name, `DM @${from} → @${to} FELL BACK to pad (no live pane)`);
    await dmStatus(p, msg, "failed", "terminal unreachable — posted on the pad instead");
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
    else if (m.type === "summarize") summarize(p, m.msg || {});   // async, don't block the socket
    else if (m.type === "term") onTerm(p, m.msg || {});           // live terminal capture
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

// thread summarizer: PWA button → ws {type:"summarize"} → run headless claude
// over the pad tail → POST /summary-in (relay stores + notifies every phone).
const CLAUDE = existsSync(join(HOME, ".local/bin/claude")) ? join(HOME, ".local/bin/claude") : "claude";
async function summarize(p, msg) {
  log(p.name, `summarize requested by @${msg.by || "?"}`);
  let padTxt = "";
  try { padTxt = readFileSync(join(p.padd, "stitchpad.md"), "utf8"); } catch {}
  const tail = padTxt.split("\n").slice(-600).join("\n");
  const prompt = `Summarize this multi-agent coding thread for the human operator (@${msg.by || "smaths"}). ` +
    `Plain english, short bullets, under 180 words. Cover: (1) current state / what just happened, ` +
    `(2) what each agent is working on, (3) decisions made, (4) anything BLOCKED waiting on the operator — put that first if it exists. ` +
    `Respond with ONLY the summary text.`;
  const post = async body => api(`/summary-in?pad=${encodeURIComponent(p.name)}`, { method: "POST", body: JSON.stringify({ ...body, by: msg.by }) }).catch(() => {});
  try {
    const c = spawn(CLAUDE, ["-p", prompt, "--model", "haiku"], { env: process.env, stdio: ["pipe", "pipe", "pipe"] });
    let out = "", errS = "";
    c.stdout.on("data", d => out += d);
    c.stderr.on("data", d => errS += d);
    const t = setTimeout(() => { try { c.kill("SIGKILL"); } catch {} }, 180000);
    c.on("close", async code => {
      clearTimeout(t);
      const text = out.trim();
      if (code === 0 && text) { await post({ text }); log(p.name, "summary posted"); }
      else { await post({ error: (errS || "summarizer exited " + code).slice(0, 300) }); log(p.name, "summary FAILED:", (errS || String(code)).slice(0, 120)); }
    });
    c.stdin.write("THREAD:\n\n" + tail); c.stdin.end();
  } catch (e) { await post({ error: e.message }); }
}

// agent → human DMs: `stitchpad dm` appends to .state/dmout.jsonl; forward each
// line to the relay (/dm-in records it in the pair log + broadcasts to phones).
async function drainDmOut(p) {
  const f = join(p.padd, ".state", "dmout.jsonl");
  try { if (!existsSync(f) || statSync(f).size === 0) return; } catch { return; }
  let raw = "";
  try { raw = readFileSync(f, "utf8"); truncateSync(f, 0); } catch { return; }
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      const m = JSON.parse(line);
      await api(`/dm-in?pad=${encodeURIComponent(p.name)}`, { method: "POST", body: JSON.stringify(m) });
      log(p.name, `DM @${m.from} → @${m.to} (agent → phone)`);
    } catch (e) { log(p.name, "dm-in forward failed:", e.message); }
  }
}

// DOCTOR: the pad's health snapshot, pushed every 30s so the phone can show
// per-agent vitals — heartbeat freshness, wake gate, terminal lock, last
// wake/DM outcome — instead of the operator diagnosing by vibes.
function lastWakeFor(p, name) {
  // adapter logs are the delivery ground truth; scan the tails
  let best = null;
  for (const f of ["adapter.herdr.log", "adapter.velocity.log", "adapter.codex.log"]) {
    let raw; try { raw = readFileSync(join(p.padd, ".state", f), "utf8"); } catch { continue; }
    const lines = raw.trimEnd().split("\n").slice(-200);
    for (let i = lines.length - 1; i >= 0; i--) {
      const l = lines[i];
      if (!l.includes(`@${name}`)) continue;
      const ts = (l.match(/^\[([^\]]+)\]/) || [])[1] || "";
      if (l.includes(`delivered wake to @${name}`)) { best = best || { at: ts, ok: true }; break; }
      if (l.includes("CROSS-PAD BLOCKED") || l.includes("failed")) { best = best || { at: ts, ok: false, why: l.includes("CROSS-PAD") ? "cross-pad blocked" : "delivery failed" }; break; }
    }
    if (best) break;
  }
  return best;
}
async function buildDoctor(p) {
  let roster;
  try { roster = (await sh(SP, ["roster"], { cwd: p.proj })).stdout; } catch { return null; }
  const agents = [];
  for (const line of roster.split("\n")) {
    const [name, adapter, wake, target] = line.split("|").map(s => (s || "").trim());
    if (!name) continue;
    const a = { name, adapter, wake: wake || "-", target: target || "-" };
    try {
      const hb = JSON.parse(readFileSync(join(p.padd, ".state", "alive." + name), "utf8"));
      a.hb_age = Math.max(0, Math.round(Date.now() / 1000 - (hb.ts || 0)));
    } catch { a.hb_age = -1; }   // -1 = no heartbeat file
    if (target && target !== "-" && adapter !== "ocean") {
      try {
        const surface = target.split("@@").pop();
        const [lpad, lname, lts] = readFileSync(join(HOME, ".stitchpad-terminals", surface), "utf8").trim().split("|");
        const fresh = Date.now() / 1000 - (+lts || 0) < 300;
        a.lock = !fresh ? "stale" : (lpad === p.padd && lname === name) ? "ok"
          : lname === "operator" ? "OPERATOR TERMINAL" : `CONFLICT: @${lname} in ${lpad.split("/").slice(-2, -1)[0]}`;
      } catch { a.lock = "unclaimed"; }
    }
    try {
      const { stdout } = await sh(SP, ["wake", name, "--peek-ordinal"], { cwd: p.proj });
      a.gate = stdout.trim() ? "owes a reply" : "idle";
    } catch { a.gate = "?"; }
    const w = lastWakeFor(p, name);
    if (w) a.last_wake = w;
    const d = LAST_DM[`${p.name}:${name}`];
    if (d) a.last_dm = { status: d.status, detail: d.detail, ago: Math.round((Date.now() - d.at) / 1000) };
    agents.push(a);
  }
  return { pad: p.name, at: Date.now(), bridge: "ws", agents };
}
async function pushDoctor(p) {
  const doc = await buildDoctor(p);
  if (!doc) return;
  await api(`/doctor-in?pad=${encodeURIComponent(p.name)}`, { method: "POST", body: JSON.stringify(doc) }).catch(() => {});
}
setInterval(() => pads.forEach(pushDoctor), 30000);

// AUTO-HEAL roster wake targets: the roster row is written ONCE (at join or a
// manual set-wake) while terminals churn constantly, so its pane pointer rots.
// The agent's own heartbeat (alive.<name>) rewrites its current pane every few
// seconds — the live source of truth. When a fresh heartbeat disagrees with
// the roster target, rewrite the roster row (keeping wake mode + adapter).
async function healRoster(p) {
  let roster;
  try { roster = (await sh(SP, ["roster"], { cwd: p.proj })).stdout; } catch { return; }
  for (const line of roster.split("\n")) {
    const [name, adapter, wake, target] = line.split("|").map(s => (s || "").trim());
    if (!name || !(wake === "push" || wake === "pull")) continue;
    // herdr rows only: other adapters (ocean, velocity) key their target on
    // adapter-specific ids (session uuids), not panes — a heartbeat pane would
    // clobber them. Their DMs already fall back to the heartbeat in resolvePane.
    if (adapter !== "herdr") continue;
    let hb;
    try { hb = JSON.parse(readFileSync(join(p.padd, ".state", "alive." + name), "utf8")); } catch { continue; }
    if (!hb.surface || Date.now() / 1000 - (hb.ts || 0) > 300) continue; // no fresh heartbeat → leave it
    if (hb.surface === target) continue;
    try {
      await sh(SP, ["set-wake", name, wake, hb.surface, adapter && adapter !== "-" ? adapter : "herdr"], { cwd: p.proj });
      log(p.name, `heal: @${name} target ${target || "-"} → ${hb.surface} (from heartbeat)`);
    } catch (e) { log(p.name, `heal failed for @${name}:`, e.message); }
  }
}
setInterval(() => pads.forEach(healRoster), 60000);

// ── main ─────────────────────────────────────────────────────
log(`relay=${RELAY} roots=${ROOTS.join(",")} (websocket mode)`);
findPads().forEach(track);
setInterval(() => findPads().forEach(track), 60000);              // new pads appear live
setInterval(() => pads.forEach(p => pushPad(p, "sweep")), 45000); // presence/status refresh
setInterval(() => pads.forEach(p => p.ws?.readyState === 1 ? p.ws.send('{"type":"ping"}') : null), 25000);
setInterval(() => pads.forEach(p => { if (!p.ws || p.ws.readyState !== 1) drainQueues(p); }), 30000);
setInterval(() => pads.forEach(drainDmOut), 2000);                // agent DM replies
// heartbeat file so `stitchpad doctor` can see the bridge is alive
setInterval(() => pads.forEach(p => {
  try { writeFileSync(join(p.padd, ".state", "bridge-heartbeat"), JSON.stringify({ ts: new Date().toISOString(), pad: p.name, mode: "ws" })); } catch {}
}), 15000);
