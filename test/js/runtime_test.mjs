// Tests of the request body limit in js/runtime.js with plain node:
// node test/js/runtime_test.mjs
// Every case is refused before the app runs, so no wasm module is needed.
import assert from "node:assert/strict";
import { runCgi } from "../../js/runtime.js";

let count = 0;
async function test(name, fn) {
  await fn();
  count++;
  console.log(`ok   js runtime ${name}`);
}

async function assertTooLarge(r) {
  assert.equal(r.status, 413);
  assert.equal(r.headers.get("content-type"), "application/json");
  assert.equal(await r.text(), '{"error":"payload too large"}\n');
}

const over = 1024 * 1024 + 1;

await test("a Content-Length over the limit is a 413", async () => {
  // A Request does not keep a forged Content-Length; a plain object does.
  const forged = { method: "POST", headers: new Headers({ "content-length": String(over) }), body: null };
  await assertTooLarge(await runCgi(null, forged));
});

await test("a body over the limit without Content-Length is a 413", async () => {
  const req = new Request("https://x.example/", { method: "POST", body: new Uint8Array(over) });
  req.headers.delete("content-length");
  await assertTooLarge(await runCgi(null, req));
});

await test("a streamed body over the limit is a 413", async () => {
  const chunk = new Uint8Array(512 * 1024);
  let sent = 0;
  const stream = new ReadableStream({
    pull(c) { sent < 3 ? (sent++, c.enqueue(chunk)) : c.close(); },
  });
  const req = new Request("https://x.example/", { method: "POST", body: stream, duplex: "half" });
  await assertTooLarge(await runCgi(null, req));
});

console.log(`${count} js runtime tests passed`);
