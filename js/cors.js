// CORS, done in the Worker around the app (see README "CORS"). A preflight is
// answered without starting the wasm, and a response made by the JS layer
// itself (the 500 of a trap) gets the headers too, so a browser sees the real
// status instead of an opaque CORS error. Nothing here is specific to a
// platform. Cookies are not supported: Access-Control-Allow-Credentials is
// never sent.
const DEFAULT_HEADERS = "Authorization, Content-Type";
const DEFAULT_MAX_AGE = "600";
const METHODS = "GET, HEAD, POST, PUT, PATCH, DELETE";

function json(status, body, headers = {}) {
  return new Response(body, { status, headers: { "Content-Type": "application/json", ...headers } });
}

// The settings from the Worker's variables, or null when CORS is off.
// A bad CORS_MAX_AGE is { error }: like JWT, a misconfiguration is a 500, not
// a silent default.
function settings(env) {
  const list = (env.CORS_ORIGINS ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (list.length === 0) return null;
  const maxAge = (env.CORS_MAX_AGE ?? "").trim() || DEFAULT_MAX_AGE;
  if (!/^\d+$/.test(maxAge)) return { error: `CORS_MAX_AGE must be a non-negative integer, got "${env.CORS_MAX_AGE}"` };
  return {
    any: list.includes("*"),
    origins: new Set(list),
    headers: (env.CORS_HEADERS ?? "").trim() || DEFAULT_HEADERS,
    maxAge,
    expose: (env.CORS_EXPOSE_HEADERS ?? "").trim(),
  };
}

// "null" is what sandboxed iframes and file: pages send; it names no site, so
// it is refused even for "*".
function allowed(cfg, origin) {
  if (origin === null || origin === "null") return false;
  return cfg.any || cfg.origins.has(origin);
}

// Appends Origin to Vary unless it (or *) is already there.
function addVary(headers, ...names) {
  const have = (headers.get("Vary") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (have.includes("*")) return;
  for (const n of names) {
    if (!have.some((h) => h.toLowerCase() === n.toLowerCase())) have.push(n);
  }
  headers.set("Vary", have.join(", "));
}

// Wraps a fetch handler (request, env, ctx) -> Response.
export function withCors(handler) {
  return async (request, env, ctx) => {
    const cfg = settings(env);
    if (!cfg) return handler(request, env, ctx);
    if (cfg.error) {
      console.error(cfg.error);
      return json(500, '{"error":"internal error"}\n');
    }

    const origin = request.headers.get("Origin");
    const ok = origin !== null && allowed(cfg, origin);

    if (request.method === "OPTIONS" && origin !== null && request.headers.has("Access-Control-Request-Method")) {
      if (!ok) return json(403, '{"error":"origin not allowed"}\n', { Vary: "Origin" });
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": origin,
          "Access-Control-Allow-Methods": METHODS,
          // Listed, not *: a * does not cover Authorization.
          "Access-Control-Allow-Headers": cfg.headers,
          "Access-Control-Max-Age": cfg.maxAge,
          Vary: "Origin, Access-Control-Request-Method, Access-Control-Request-Headers",
        },
      });
    }

    // Copied so the headers can be changed whatever the handler returned.
    const res = await handler(request, env, ctx);
    const out = new Response(res.body, res);
    if (ok) {
      out.headers.set("Access-Control-Allow-Origin", origin);
      if (cfg.expose) out.headers.set("Access-Control-Expose-Headers", cfg.expose);
    }
    addVary(out.headers, "Origin");
    return out;
  };
}
