// Tests of js/cors.js with plain node: node test/js/cors_test.mjs
import assert from "node:assert/strict";
import { withCors } from "../../js/cors.js";

let count = 0;
async function test(name, fn) {
  await fn();
  count++;
  console.log(`ok   js cors ${name}`);
}

// A fake app: counts calls and answers `reply()`.
function app(reply = () => new Response("hi", { headers: { "X-App": "1" } })) {
  const inner = async () => {
    inner.calls++;
    return reply();
  };
  inner.calls = 0;
  return inner;
}
const call = (inner, env, url, init, options) => withCors(inner, options)(new Request(url, init), env);
const ORIGIN = "https://app.example";
const preflight = (origin = ORIGIN, extra = {}) => ({
  method: "OPTIONS",
  headers: { Origin: origin, "Access-Control-Request-Method": "GET", ...extra },
});
const ON = { CORS_ORIGINS: ORIGIN };

await test("off when CORS_ORIGINS is unset or empty", async () => {
  for (const env of [{}, { CORS_ORIGINS: "" }, { CORS_ORIGINS: " , " }]) {
    const inner = app();
    const r = await call(inner, env, "http://x/a", { headers: { Origin: ORIGIN } });
    assert.equal(r.headers.get("access-control-allow-origin"), null);
    assert.equal(r.headers.get("vary"), null);
    const p = await call(inner, env, "http://x/a", preflight());
    assert.equal(p.status, 200);
    assert.equal(inner.calls, 2);
  }
});

await test("a preflight from an allowed origin is answered without the app", async () => {
  const inner = app();
  const r = await call(inner, ON, "http://x/todos", preflight());
  assert.equal(r.status, 204);
  assert.equal(await r.text(), "");
  assert.equal(inner.calls, 0);
  assert.equal(r.headers.get("access-control-allow-origin"), ORIGIN);
  assert.equal(r.headers.get("access-control-allow-methods"), "GET, HEAD, POST, PUT, PATCH, DELETE");
  assert.equal(r.headers.get("access-control-allow-headers"), "Authorization, Content-Type");
  assert.equal(r.headers.get("access-control-max-age"), "600");
  assert.equal(r.headers.get("vary"), "Origin, Access-Control-Request-Method, Access-Control-Request-Headers");
  assert.equal(r.headers.get("access-control-allow-credentials"), null);
});

await test("a preflight from another origin is 403 without CORS headers", async () => {
  const inner = app();
  const r = await call(inner, ON, "http://x/todos", preflight("https://evil.example"));
  assert.equal(r.status, 403);
  assert.equal(r.headers.get("content-type"), "application/json");
  assert.equal(await r.text(), '{"error":"origin not allowed"}\n');
  assert.equal(r.headers.get("vary"), "Origin");
  assert.equal([...r.headers.keys()].filter((k) => k.startsWith("access-control-")).length, 0);
  assert.equal(inner.calls, 0);
});

await test("* allows any origin, and the origin is echoed", async () => {
  const r = await call(app(), { CORS_ORIGINS: "*" }, "http://x/a", preflight("https://any.example"));
  assert.equal(r.status, 204);
  assert.equal(r.headers.get("access-control-allow-origin"), "https://any.example");
});

await test("the origin null is never allowed", async () => {
  for (const origins of ["*", "null", `${ORIGIN}, null`]) {
    const env = { CORS_ORIGINS: origins };
    assert.equal((await call(app(), env, "http://x/a", preflight("null"))).status, 403);
    const r = await call(app(), env, "http://x/a", { headers: { Origin: "null" } });
    assert.equal(r.headers.get("access-control-allow-origin"), null);
  }
});

await test("an actual request from an allowed origin gets the headers", async () => {
  const inner = app();
  const r = await call(inner, { ...ON, CORS_EXPOSE_HEADERS: "X-Total-Count" }, "http://x/a", { headers: { Origin: ORIGIN } });
  assert.equal(await r.text(), "hi");
  assert.equal(r.headers.get("x-app"), "1");
  assert.equal(r.headers.get("access-control-allow-origin"), ORIGIN);
  assert.equal(r.headers.get("access-control-expose-headers"), "X-Total-Count");
  assert.equal(r.headers.get("vary"), "Origin");
  assert.equal(r.headers.get("access-control-allow-credentials"), null);
});

await test("no Expose-Headers unless set", async () => {
  const r = await call(app(), ON, "http://x/a", { headers: { Origin: ORIGIN } });
  assert.equal(r.headers.get("access-control-expose-headers"), null);
});

await test("exposeHeaders are added to Expose-Headers once, merged with the app's and CORS_EXPOSE_HEADERS", async () => {
  const exposed = async (env, reply) => (await call(app(reply), env, "http://x/a", { headers: { Origin: ORIGIN } }, { exposeHeaders: ["X-Example"] }))
    .headers.get("access-control-expose-headers");
  assert.equal(await exposed(ON), "X-Example");
  assert.equal(await exposed({ ...ON, CORS_EXPOSE_HEADERS: "x-example, X-A" }), "x-example, X-A");
  const reply = () => new Response("hi", { headers: { "Access-Control-Expose-Headers": "X-App" } });
  assert.equal(await exposed({ ...ON, CORS_EXPOSE_HEADERS: "X-A" }, reply), "X-App, X-A, X-Example");
});

await test("allowHeaders are added to a preflight's Allow-Headers once", async () => {
  const allowed = async (env) => (await call(app(), env, "http://x/a", preflight(), { allowHeaders: ["X-Example"] })).headers.get("access-control-allow-headers");
  assert.equal(await allowed(ON), "Authorization, Content-Type, X-Example");
  assert.equal(await allowed({ ...ON, CORS_HEADERS: "Authorization, X-EXAMPLE" }), "Authorization, X-EXAMPLE");
});

await test("another origin gets no Allow-Origin, but Vary", async () => {
  const inner = app();
  const r = await call(inner, ON, "http://x/a", { headers: { Origin: "https://evil.example" } });
  assert.equal(inner.calls, 1);
  assert.equal(r.headers.get("access-control-allow-origin"), null);
  assert.equal(r.headers.get("vary"), "Origin");
});

await test("a request without Origin changes only Vary", async () => {
  const r = await call(app(), ON, "http://x/a");
  assert.equal(r.headers.get("access-control-allow-origin"), null);
  assert.equal(r.headers.get("vary"), "Origin");
});

await test("Vary is merged, not duplicated", async () => {
  const merge = async (vary) => (await call(app(() => new Response("", { headers: { Vary: vary } })), ON, "http://x/a")).headers.get("vary");
  assert.equal(await merge("Accept-Encoding"), "Accept-Encoding, Origin");
  assert.equal(await merge("accept, origin"), "accept, origin");
  assert.equal(await merge("*"), "*");
});

await test("a bad CORS_MAX_AGE is a 500 for every request", async () => {
  const orig = console.error;
  const logged = [];
  console.error = (m) => logged.push(m);
  try {
    for (const v of ["abc", "-1", "1.5", "10s"]) {
      const inner = app();
      for (const init of [preflight(), { headers: { Origin: ORIGIN } }, undefined]) {
        const r = await call(inner, { ...ON, CORS_MAX_AGE: v }, "http://x/a", init);
        assert.equal(r.status, 500);
        assert.equal(r.headers.get("content-type"), "application/json");
        assert.equal(await r.text(), '{"error":"internal error"}\n');
      }
      assert.equal(inner.calls, 0);
    }
  } finally {
    console.error = orig;
  }
  assert.equal(logged.length, 12);
});

await test("CORS_MAX_AGE sets Max-Age (0 is valid)", async () => {
  const r = await call(app(), { ...ON, CORS_MAX_AGE: "0" }, "http://x/a", preflight());
  assert.equal(r.headers.get("access-control-max-age"), "0");
});

await test("a 500 from the handler still gets the CORS headers", async () => {
  const inner = app(() => new Response('{"error":"internal error"}\n', { status: 500 }));
  const r = await call(inner, ON, "http://x/a", { headers: { Origin: ORIGIN } });
  assert.equal(r.status, 500);
  assert.equal(r.headers.get("access-control-allow-origin"), ORIGIN);
});

await test("an OPTIONS that is not a preflight goes to the app", async () => {
  const inner = app(() => new Response("", { status: 404 }));
  for (const headers of [{ Origin: ORIGIN }, { "Access-Control-Request-Method": "GET" }, {}]) {
    const r = await call(inner, ON, "http://x/a", { method: "OPTIONS", headers });
    assert.equal(r.status, 404);
  }
  assert.equal(inner.calls, 3);
});

await test("whitespace around CORS_ORIGINS entries is trimmed; matching is exact", async () => {
  const env = { CORS_ORIGINS: "  https://a.example ,\thttp://localhost:3000 " };
  assert.equal((await call(app(), env, "http://x/a", preflight("http://localhost:3000"))).status, 204);
  assert.equal((await call(app(), env, "http://x/a", preflight("https://a.example"))).status, 204);
  assert.equal((await call(app(), env, "http://x/a", preflight("https://a.example/"))).status, 403);
  assert.equal((await call(app(), env, "http://x/a", preflight("https://A.example"))).status, 403);
});

await test("CORS_HEADERS sets Allow-Headers", async () => {
  const r = await call(app(), { ...ON, CORS_HEADERS: "Authorization, X-Foo" }, "http://x/a", preflight());
  assert.equal(r.headers.get("access-control-allow-headers"), "Authorization, X-Foo");
});

console.log(`${count} js cors tests passed`);
