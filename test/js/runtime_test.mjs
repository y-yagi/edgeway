// Tests of the request body limit and the log routing in js/runtime.js with plain node:
// node test/js/runtime_test.mjs
// Every case is refused before the app runs, so no wasm module is needed.
import assert from "node:assert/strict";
import { runCgi, parseLogLine, logLine, lineSplitter } from "../../js/runtime.js";

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

function recorder() {
  const calls = [];
  const sink = {};
  for (const level of ["debug", "info", "warn", "error"]) sink[level] = (value) => calls.push([level, value]);
  return { calls, sink };
}

await test("a structured line goes to console at its level as an object", () => {
  const { calls, sink } = recorder();
  logLine('{"level":"warn","message":"m","n":1}', {}, sink);
  assert.deepEqual(calls, [["warn", { level: "warn", message: "m", n: 1 }]]);
});

await test("context fields are added and the app's fields win", () => {
  const { calls, sink } = recorder();
  logLine('{"level":"info","message":"m","ray":"app"}', { ray: "ctx", extra: 1 }, sink);
  assert.deepEqual(calls, [["info", { ray: "app", extra: 1, level: "info", message: "m" }]]);
});

await test("other text goes to console.error as text", () => {
  for (const line of ["boom", "{not json", '{"level":"info"}', '{"level":"fatal"}', '{"level":1}', "[1]", '{"message":"m"}', "null"]) {
    const { calls, sink } = recorder();
    logLine(line, { ray: "r" }, sink);
    assert.deepEqual(calls, [["error", line]], line);
  }
  assert.equal(parseLogLine('{"level":"info","message":"m"}').level, "info");
  assert.equal(parseLogLine('{"level":"info"}'), null);
  assert.equal(parseLogLine('{"level":"info","message":1}'), null);
});

await test("lines are cut from chunks, and the last partial one is flushed", () => {
  const lines = [];
  const splitter = lineSplitter((line) => lines.push(line));
  splitter.push("a\nb");
  splitter.push("c\n\nd\ne");
  assert.deepEqual(lines, ["a", "bc", "d"]);
  splitter.flush();
  splitter.flush();
  assert.deepEqual(lines, ["a", "bc", "d", "e"]);
});

console.log(`${count} js runtime tests passed`);
