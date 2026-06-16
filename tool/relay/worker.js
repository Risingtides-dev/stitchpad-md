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

    // Login: exchange username+password (checked against secrets) for the bearer token.
    if (url.pathname === "/login" && req.method === "POST") {
      const { user, pass } = await req.json().catch(() => ({}));
      if (user === env.STITCHPAD_USER && pass === env.STITCHPAD_PASS) return json({ token: env.STITCHPAD_TOKEN });
      return json({ error: "bad credentials" }, 401);
    }

    // Non-API paths → serve the PWA static assets (index.html, manifest).
    const API = ["/login", "/pads", "/pad", "/pad.colors", "/push", "/say", "/outbox", "/upload-image"];
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
      // Construct public URL (R2 dev URL)
      const publicUrl = `https://pub-ac6a4a8a53874251ae65685bf1c45fe9.r2.dev/${r2Key}`;
      return json({ url: publicUrl, sha, mime: file.type, size: file.size });
    }
    return json({ error: "not found" }, 404);
  },
};
