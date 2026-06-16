// stitchpad relay — a thin remote face on the TUI/pad backend. MULTI-PAD:
// many stitchpads, each keyed by NAME (= its directory basename). The PWA lists
// pads and picks one. The bash CLI stays the source of truth; this just mirrors.
//
//   GET  /pads               → [{name, at}]  list of known stitchpads
//   POST /push?pad=NAME      (Mac bridge)  body {pad, roster} → store under NAME
//   GET  /pad?pad=NAME       (PWA)         → that pad's markdown + roster
//   POST /say?pad=NAME       (PWA)         body {from,text} → queued for NAME
//   GET  /outbox?pad=NAME    (Mac/tunnel)  → drain NAME's queued phone messages
//
// Auth: shared bearer token (STITCHPAD_TOKEN) on every request.
const json = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json", "access-control-allow-origin": "*" } });
const cors = { "access-control-allow-origin": "*", "access-control-allow-methods": "GET,POST,OPTIONS", "access-control-allow-headers": "authorization,content-type" };

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (req.method === "OPTIONS") return new Response(null, { headers: cors });

    // Login: exchange username+password (checked against secrets) for the bearer token.
    if (url.pathname === "/login" && req.method === "POST") {
      const { user, pass } = await req.json().catch(() => ({}));
      if (user === env.STITCHPAD_USER && pass === env.STITCHPAD_PASS) return json({ token: env.STITCHPAD_TOKEN });
      return json({ error: "bad credentials" }, 401);
    }

    // Non-API paths → serve the PWA static assets (index.html, manifest).
    const API = ["/login", "/pads", "/pad", "/push", "/say", "/outbox"];
    if (!API.includes(url.pathname)) {
      return env.ASSETS ? env.ASSETS.fetch(req) : json({ error: "no assets" }, 404);
    }
    const tok = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    if (!env.STITCHPAD_TOKEN || tok !== env.STITCHPAD_TOKEN) return json({ error: "unauthorized" }, 401);

    const pad = (url.searchParams.get("pad") || "").trim();
    const padKey = pad ? `pad:${pad}` : null;

    // list all pads (index maintained on push)
    if (url.pathname === "/pads" && req.method === "GET") {
      const idx = JSON.parse((await env.STITCHPAD.get("index")) || "{}");
      return json(Object.entries(idx).map(([name, at]) => ({ name, at })).sort((a, b) => b.at - a.at));
    }
    if (!pad) return json({ error: "missing ?pad=NAME" }, 400);

    if (url.pathname === "/push" && req.method === "POST") {
      const body = await req.json();
      const at = Date.now();
      await env.STITCHPAD.put(padKey, JSON.stringify({ ...body, name: pad, at }));
      const idx = JSON.parse((await env.STITCHPAD.get("index")) || "{}");
      idx[pad] = at; await env.STITCHPAD.put("index", JSON.stringify(idx));
      return json({ ok: true });
    }
    if (url.pathname === "/pad" && req.method === "GET") {
      const v = await env.STITCHPAD.get(padKey);
      return json(v ? JSON.parse(v) : { pad: "", roster: [], name: pad, at: 0 });
    }
    if (url.pathname === "/say" && req.method === "POST") {
      const { from, text } = await req.json();
      if (!text) return json({ error: "empty" }, 400);
      const qk = `outbox:${pad}`;
      const q = JSON.parse((await env.STITCHPAD.get(qk)) || "[]");
      q.push({ from: from || "smaths", text, at: Date.now() });
      await env.STITCHPAD.put(qk, JSON.stringify(q));
      return json({ ok: true, queued: q.length });
    }
    if (url.pathname === "/outbox" && req.method === "GET") {
      const qk = `outbox:${pad}`;
      const q = JSON.parse((await env.STITCHPAD.get(qk)) || "[]");
      await env.STITCHPAD.put(qk, "[]");
      return json({ messages: q });
    }
    return json({ error: "not found" }, 404);
  },
};
