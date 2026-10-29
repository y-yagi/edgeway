// CORS, done in the Worker around the app (see README "CORS"). A preflight is
// answered without starting the wasm, and a response made by the JS layer
// itself (the 500 of a trap) gets the headers too, so a browser sees the real
// status instead of an opaque CORS error. Nothing here is specific to a
// platform. Cookies are not supported: Access-Control-Allow-Credentials is
// never sent.
import { addVary, withHeaders } from "./headers.js";

const DEFAULT_HEADERS = "Authorization, Content-Type";
const DEFAULT_MAX_AGE = "600";
const METHODS = "GET, HEAD, POST, PUT, PATCH, DELETE";

function json(status, body, headers = {}) {
  return new Response(body, { status, headers: { "Content-Type": "application/json", ...headers } });
}

// The settings from the Worker's variables, or null when CORS is off.
// A bad CORS_MAX_AGE is { error }: like JWT, a misconfiguration is a 500, not
// a silent default.
function settings(env, { exposeHeaders, allowHeaders }) {
  const list = (env.CORS_ORIGINS ?? "").split(",").map((origin) => origin.trim()).filter(Boolean);
  if (list.length === 0) return null;
  const maxAge = (env.CORS_MAX_AGE ?? "").trim() || DEFAULT_MAX_AGE;
  if (!/^\d+$/.test(maxAge)) return { error: `CORS_MAX_AGE must be a non-negative integer, got "${env.CORS_MAX_AGE}"` };
  return {
    any: list.includes("*"),
    origins: new Set(list),
    headers: withHeaders((env.CORS_HEADERS ?? "").trim() || DEFAULT_HEADERS, ...allowHeaders),
    maxAge,
    expose: withHeaders(env.CORS_EXPOSE_HEADERS, ...exposeHeaders),
  };
}

// "null" is what sandboxed iframes and file: pages send; it names no site, so
// it is refused even for "*".
function allowed(cfg, origin) {
  if (origin === null || origin === "null") return false;
  return cfg.any || cfg.origins.has(origin);
}

function exposeOn(headers, expose) {
  const merged = withHeaders(headers.get("Access-Control-Expose-Headers"), ...expose.split(", ").filter(Boolean));
  if (merged) headers.set("Access-Control-Expose-Headers", merged);
}

// Wraps a fetch handler (request, env, ctx) -> Response. exposeHeaders and
// allowHeaders are names the platform layer always adds to the exposed and the
// preflight-allowed headers.
export function withCors(handler, { exposeHeaders = [], allowHeaders = [] } = {}) {
  return async (request, env, ctx) => {
    const cfg = settings(env, { exposeHeaders, allowHeaders });
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
      exposeOn(out.headers, cfg.expose);
    }
    addVary(out.headers, "Origin");
    return out;
  };
}
