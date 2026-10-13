// Tests of js/cgi.js with plain node: node test/js/cgi_test.mjs
import assert from "node:assert/strict";
import { cgiEnv, cgiResponse } from "../../js/cgi.js";

const enc = new TextEncoder();
const run = (text) => cgiResponse(enc.encode(text));
let count = 0;
async function test(name, fn) {
  await fn();
  count++;
  console.log(`ok   js ${name}`);
}

await test("parses status, headers and body", async () => {
  const r = run('Status: 201\nContent-Type: application/json\nX-A: 1\n\n{"ok":true}\n');
  assert.equal(r.status, 201);
  assert.equal(r.headers.get("x-a"), "1");
  assert.equal(await r.text(), '{"ok":true}\n');
});

await test("the first Status wins, a later one is dropped", () => {
  const r = run("Status: 200\nX-Name: a\nSet-Cookie: s=1\nStatus: 302\nLocation: https://evil.example\n\nbody");
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("x-name"), "a");
});

await test("a bad status is a fixed JSON 500", async () => {
  const r = run("Status: 99\n\nsecret");
  assert.equal(r.status, 500);
  assert.equal(r.headers.get("content-type"), "application/json");
  assert.equal(await r.text(), '{"error":"internal error"}\n');
});

await test("204 has no body, and Location without Status is 302", async () => {
  assert.equal(run("Status: 204\n\nignored").body, null);
  assert.equal(run("Location: /x\n\n").status, 302);
});

await test("output without a blank line is the whole body", async () => {
  const r = run("plain text");
  assert.equal(r.status, 200);
  assert.equal(await r.text(), "plain text");
});

await test("request headers: underscores dropped, proxy dropped", () => {
  const req = new Request("https://x.example/todos/a%20b%2Fc/%E3%81%82?q=1", {
    headers: { "X-Foo": "1", X_Foo: "2", Proxy: "p", "Content-Type": "application/json" },
  });
  const env = cgiEnv(req, new Uint8Array(3));
  assert.equal(env.HTTP_X_FOO, "1");
  assert.equal(Object.keys(env).filter((k) => k.startsWith("HTTP_")).length, 1);
  assert.equal(env.CONTENT_TYPE, "application/json");
  assert.equal(env.CONTENT_LENGTH, "3");
  assert.equal(env.PATH_INFO, "/todos/a b%2Fc/あ");
  assert.equal(env.QUERY_STRING, "q=1");
  assert.equal(env.REQUEST_METHOD, "GET");
});

console.log(`${count} js tests passed`);
