// stitchpad relay — a thin remote face on the TUI/pad backend. MULTI-PAD:
// many stitchpads, each keyed by NAME (= its directory basename). The PWA lists
// pads and picks one. The bash CLI stays the source of truth; this just mirrors.
//
//   GET  /pads               → [{name, at}]  list of known stitchpads
//   POST /push?pad=NAME      (Mac bridge)  body {pad, roster, files, colors} → store under NAME
//   GET  /pad?pad=NAME       (PWA)         → that pad's markdown + roster + files + colors
//   GET  /pad.colors?pad=NAME (PWA)        → [{name, color}, ...] single-source colors
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

    // Login: username+password → {token, handle}. Multi-user so coworkers each get
    // their OWN identity (posts show as them, not @smaths). Users come from the
    // STITCHPAD_USERS secret (JSON: {"user":{"pass":"...","handle":"..."}}) with the
    // original single STITCHPAD_USER/PASS kept as a fallback (handle @smaths).
    if (url.pathname === "/login" && req.method === "POST") {
      const { user, pass } = await req.json().catch(() => ({}));
      let users = {};
      try { users = JSON.parse(env.STITCHPAD_USERS || "{}"); } catch {}
      const u = users[user];
      if (u && u.pass === pass) return json({ token: env.STITCHPAD_TOKEN, handle: u.handle || user });
      // fallback: the original single operator login
      if (user === env.STITCHPAD_USER && pass === env.STITCHPAD_PASS) return json({ token: env.STITCHPAD_TOKEN, handle: "smaths" });
      return json({ error: "bad credentials" }, 401);
    }

    // Redeem an invite token (PUBLIC — the remote agent doesn't have the bearer yet).
    // Owner generates a token with /invite; the remote agent trades it here for a
    // pad-scoped session token + its handle. This is how an agent on ANOTHER network
    // joins a stitchpad: no shared password, owner-gated by token issuance.
    if (url.pathname === "/join-request" && req.method === "POST") {
      const { token } = await req.json().catch(() => ({}));
      if (!token) return json({ error: "missing invite token" }, 400);
      const raw = await env.STITCHPAD.get(`invite:${token}`);
      if (!raw) return json({ error: "invalid or revoked invite" }, 403);
      const inv = JSON.parse(raw);
      if (inv.expires && Date.now() > inv.expires) {
        await env.STITCHPAD.delete(`invite:${token}`);
        return json({ error: "invite expired" }, 403);
      }
      // Valid → hand back the relay token scoped to this pad + the invited handle.
      return json({ token: env.STITCHPAD_TOKEN, pad: inv.pad, handle: inv.handle });
    }

    // Non-API paths → serve the PWA static assets (index.html, manifest).
    const API = ["/login", "/join-request", "/invite", "/pads", "/pad", "/pad.colors", "/push", "/say", "/outbox", "/upload-image"];
    if (!API.includes(url.pathname) && !url.pathname.startsWith("/img/")) {
      return env.ASSETS ? env.ASSETS.fetch(req) : json({ error: "no assets" }, 404);
    }
    const tok = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    if (!env.STITCHPAD_TOKEN || tok !== env.STITCHPAD_TOKEN) return json({ error: "unauthorized" }, 401);

    const pad = (url.searchParams.get("pad") || "").trim();
    const padKey = pad ? `pad:${pad}` : null;

    // Create an invite token (OWNER-authed — passed the bearer gate above). Stores
    // invite:<token> → {pad, handle, expires}. Owner shares the token; remote agent
    // redeems via /join-request. ttlSec=0 → permanent. This is the room owner's gate:
    // generate to grant, /invite?revoke=<token> to kill access.
    if (url.pathname === "/invite" && req.method === "POST") {
      if (!pad) return json({ error: "missing ?pad=NAME" }, 400);
      const body = await req.json().catch(() => ({}));
      const handle = (body.handle || "guest").trim();
      const ttlSec = Number(body.ttlSec || 0);
      // token derived from random bytes (crypto), short + url-safe
      const bytes = crypto.getRandomValues(new Uint8Array(12));
      const token = "inv_" + Array.from(bytes).map(b => b.toString(16).padStart(2, "0")).join("");
      const expires = ttlSec > 0 ? Date.now() + ttlSec * 1000 : 0;
      await env.STITCHPAD.put(`invite:${token}`, JSON.stringify({ pad, handle, expires }), ttlSec > 0 ? { expirationTtl: Math.max(60, ttlSec) } : {});
      return json({ token, pad, handle, expires });
    }
    if (url.pathname === "/invite" && req.method === "DELETE") {
      const rev = (url.searchParams.get("revoke") || "").trim();
      if (!rev) return json({ error: "missing ?revoke=TOKEN" }, 400);
      await env.STITCHPAD.delete(`invite:${rev}`);
      return json({ ok: true, revoked: rev });
    }

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
    if (url.pathname === "/pad.colors" && req.method === "GET") {
      const v = await env.STITCHPAD.get(padKey);
      const colors = v ? (JSON.parse(v).colors || {}) : {};
      return json(colors);
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
    // Image upload endpoint — accepts multipart/form-data with 'image' field
    // Returns {url, sha, w, h, mime} for embedding in the pad
    if (url.pathname === "/upload-image" && req.method === "POST") {
      const contentType = req.headers.get("content-type") || "";
      if (!contentType.includes("multipart/form-data")) {
        return json({ error: "expected multipart/form-data" }, 400);
      }
      const formData = await req.formData();
      const file = formData.get("image");
      if (!file || typeof file === "string") {
        return json({ error: "missing 'image' field" }, 400);
      }
      // Validate mime type
      const allowedMimes = ["image/png", "image/jpeg", "image/gif", "image/webp"];
      if (!allowedMimes.includes(file.type)) {
        return json({ error: `invalid mime type: ${file.type}. Allowed: ${allowedMimes.join(", ")}` }, 400);
      }
      // Validate size (10MB max)
      const maxSize = 10 * 1024 * 1024;
      if (file.size > maxSize) {
        return json({ error: `file too large: ${file.size} bytes (max ${maxSize})` }, 400);
      }
      // Compute SHA-256 hash for dedupe
      const arrayBuffer = await file.arrayBuffer();
      const hashBuffer = await crypto.subtle.digest("SHA-256", arrayBuffer);
      const hashArray = Array.from(new Uint8Array(hashBuffer));
      const sha = hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
      // R2 key: images/<sha>.<ext>
      const ext = file.name.split(".").pop() || "png";
      const r2Key = `images/${sha}.${ext}`;
      // Upload to R2
      await env.IMAGES.put(r2Key, arrayBuffer, {
        httpMetadata: { contentType: file.type },
        customMetadata: { originalName: file.name, uploadedAt: new Date().toISOString() }
      });
      // Construct public URL served through our own domain via the /img proxy
      // route below — NOT the r2.dev dev URL (rate-limited, not for prod) and no
      // public-bucket exposure. r2Key is images/<sha>.<ext>; /img strips "images/".
      const publicUrl = `https://stitchpad.agentsworld.org/img/${sha}.${ext}`;
      return json({ url: publicUrl, sha, mime: file.type, size: file.size });
    }
    // Serve images from R2
    if (url.pathname.startsWith("/img/") && req.method === "GET") {
      const key = "images/" + url.pathname.slice(5);
      const obj = await env.IMAGES.get(key);
      if (!obj) return json({ error: "not found" }, 404);
      const headers = new Headers(cors);
      headers.set("content-type", obj.httpMetadata?.contentType || "application/octet-stream");
      headers.set("cache-control", "public, max-age=31536000");
      return new Response(obj.body, { headers });
    }
    return json({ error: "not found" }, 404);
  },
};
