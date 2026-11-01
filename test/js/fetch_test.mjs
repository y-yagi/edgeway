import assert from "node:assert/strict";
import { parseRequest, performRequest, urlAllowed, DEFAULT_MAX_BYTES } from "../../js/fetch.js";

let count = 0;
async function test(name, fn) {
  await fn();
  count++;
  console.log(`ok   js fetch ${name}`);
}

const spec = (overrides = {}) => ({ method: "GET", url: "https://api.example/x", headers: {}, body: "", timeout_ms: 1000, ...overrides });
const answering = (response) => {
  const fake = async (url, init) => {
    fake.calls.push({ url, init });
    return response();
  };
  fake.calls = [];
  return fake;
};
const streamed = (bytes, headers = {}) => new Response(new ReadableStream({
  start(controller) {
    for (let offset = 0; offset < bytes.length; offset += 4096) controller.enqueue(bytes.slice(offset, offset + 4096));
    controller.close();
  },
}), { status: 200, headers });

await test("https is allowed, http only for localhost", async () => {
  for (const url of ["https://api.example/x", "http://localhost:8788/x", "http://127.0.0.1/x", "http://[::1]:8788/x"]) {
    assert.equal(urlAllowed(url), true, url);
  }
  for (const url of ["http://api.example/x", "ftp://api.example/x", "api.example/x", "http://localhost.evil.example/x", "http://127.0.0.1.evil.example/x"]) {
    assert.equal(urlAllowed(url), false, url);
  }
});

await test("a refused URL is an error and nothing is fetched", async () => {
  const fake = answering(() => new Response("x"));
  const result = await performRequest(spec({ url: "http://api.example/x" }), { fetch: fake });
  assert.match(result.error, /https/);
  assert.equal(fake.calls.length, 0);
});

await test("the answer has the status, lower-case headers and the body in base64", async () => {
  const fake = answering(() => new Response("hello", { status: 201, headers: { "X-Request-Id": "abc", "Content-Type": "text/plain" } }));
  const result = await performRequest(spec({ method: "POST", body: "payload", headers: { Authorization: "Bearer t" } }), { fetch: fake });
  assert.equal(result.status, 201);
  assert.deepEqual(result.headers, { "x-request-id": "abc", "content-type": "text/plain" });
  assert.equal(Buffer.from(result.body_base64, "base64").toString(), "hello");
  assert.equal(fake.calls[0].init.method, "POST");
  assert.equal(fake.calls[0].init.body, "payload");
  assert.deepEqual(fake.calls[0].init.headers, { Authorization: "Bearer t" });
});

await test("an empty body is not sent", async () => {
  const fake = answering(() => new Response("x"));
  await performRequest(spec(), { fetch: fake });
  assert.equal("body" in fake.calls[0].init, false);
});

await test("a binary body round-trips through base64", async () => {
  const bytes = Uint8Array.from({ length: 256 }, (_, index) => index);
  const result = await performRequest(spec(), { fetch: answering(() => new Response(bytes)) });
  assert.deepEqual(new Uint8Array(Buffer.from(result.body_base64, "base64")), bytes);
});

await test("a response over 20000 bytes round-trips (base64 is built in chunks)", async () => {
  const bytes = Uint8Array.from({ length: 20000 }, (_, index) => index % 251);
  const result = await performRequest(spec(), { fetch: answering(() => new Response(bytes)) });
  assert.deepEqual(new Uint8Array(Buffer.from(result.body_base64, "base64")), bytes);
});

await test("a redirect is returned, not followed, with its location", async () => {
  const fake = answering(() => new Response(null, { status: 302, headers: { Location: "https://api.example/y" } }));
  const result = await performRequest(spec(), { fetch: fake });
  assert.equal(result.status, 302);
  assert.equal(result.headers.location, "https://api.example/y");
  assert.equal(fake.calls.length, 1);
  assert.equal(fake.calls[0].init.redirect, "manual");
});

await test("a response without a body is empty", async () => {
  const result = await performRequest(spec(), { fetch: answering(() => new Response(null, { status: 204 })) });
  assert.equal(result.status, 204);
  assert.equal(result.body_base64, "");
});

await test("the timeout aborts the request and is reported as one", async () => {
  const hang = async (url, init) => new Promise((_, reject) => init.signal.addEventListener("abort", () => reject(init.signal.reason)));
  const keepAlive = setTimeout(() => {}, 5000);
  const result = await performRequest(spec({ timeout_ms: 20 }), { fetch: hang });
  clearTimeout(keepAlive);
  assert.equal(result.timeout, true);
  assert.match(result.error, /timed out/);
});

await test("the timeout is the one asked for", async () => {
  const realTimeout = AbortSignal.timeout;
  const asked = [];
  AbortSignal.timeout = (milliseconds) => {
    asked.push(milliseconds);
    return realTimeout.call(AbortSignal, milliseconds);
  };
  try {
    await performRequest(spec({ timeout_ms: 2500 }), { fetch: answering(() => new Response("x")) });
  } finally {
    AbortSignal.timeout = realTimeout;
  }
  assert.deepEqual(asked, [2500]);
});

await test("the timeout covers reading the body", async () => {
  const stalled = (url, init) => Promise.resolve(new Response(new ReadableStream({
    pull: () => new Promise((_, reject) => init.signal.addEventListener("abort", () => reject(init.signal.reason))),
  }), { status: 200, headers: { "content-type": "text/plain" } }));
  const keepAlive = setTimeout(() => {}, 5000);
  const result = await performRequest(spec({ timeout_ms: 20 }), { fetch: stalled });
  clearTimeout(keepAlive);
  assert.equal(result.timeout, true);
});

await test("a request that is not valid UTF-8 or JSON is not parsed", async () => {
  const encoded = new TextEncoder().encode(JSON.stringify(spec({ body: "caf\u00e9" })));
  assert.equal(parseRequest(encoded).body, "caf\u00e9");
  const invalid = Uint8Array.from([...new TextEncoder().encode('{"body":"'), 0xff, ...new TextEncoder().encode('"}')]);
  assert.equal(parseRequest(invalid), null);
  assert.equal(parseRequest(new TextEncoder().encode("{bad")), null);
});

await test("a network failure is an error without the timeout flag", async () => {
  const result = await performRequest(spec(), { fetch: async () => { throw new TypeError("fetch failed"); } });
  assert.deepEqual(result, { error: "fetch failed" });
});

await test("a body over the limit is refused, with or without Content-Length", async () => {
  const limit = 10_000;
  const big = new Uint8Array(limit + 1000);
  const refused = async (response) => (await performRequest(spec(), { fetch: answering(response), maxBytes: limit })).error;
  assert.match(await refused(() => new Response(big, { headers: { "content-length": String(big.length) } })), /too large/);
  assert.match(await refused(() => streamed(big, { "content-length": "10" })), /too large/);
  assert.match(await refused(() => streamed(big)), /too large/);
  const fine = await performRequest(spec(), { fetch: answering(() => streamed(new Uint8Array(limit))), maxBytes: limit });
  assert.equal(fine.status, 200);
});

await test("the default limit is 1 MB", async () => {
  assert.equal(DEFAULT_MAX_BYTES, 1024 * 1024);
  const big = new Uint8Array(DEFAULT_MAX_BYTES + 1);
  assert.match((await performRequest(spec(), { fetch: answering(() => streamed(big)) })).error, /too large/);
  const fine = await performRequest(spec(), { fetch: answering(() => streamed(new Uint8Array(DEFAULT_MAX_BYTES))) });
  assert.equal(fine.status, 200);
});

console.log(`${count} js fetch tests`);
