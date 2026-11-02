// WebAssembly.Suspending (JSPI) is replaced even when node has it; the stand-in
// keeps the function so the import can be called.
import assert from "node:assert/strict";
import { rateLimitImports } from "../../js/cloudflare-ratelimit.js";

WebAssembly.Suspending = class { constructor(fn) { this.fn = fn; } };

let count = 0;
async function test(name, fn) {
  await fn();
  count++;
  console.log(`ok   js cloudflare ratelimit ${name}`);
}

const memory = new WebAssembly.Memory({ initial: 1 });
const encoder = new TextEncoder();
const decoder = new TextDecoder();

function fakeRateLimit(allowed) {
  const rateLimit = {
    calls: [],
    async limit(options) {
      rateLimit.calls.push(options);
      if (rateLimit.failure) throw new Error(rateLimit.failure);
      return { success: allowed(rateLimit.calls.length) };
    },
  };
  return rateLimit;
}

async function callBytes(env, byteArrays) {
  const imports = rateLimitImports(env, () => ({ exports: { memory } })).edgeway_ratelimit;
  const bytes = new Uint8Array(memory.buffer);
  let offset = 16;
  const pointers = byteArrays.map((encoded) => {
    bytes.set(encoded, offset);
    bytes[offset + encoded.length] = 0;
    const pointer = offset;
    offset += encoded.length + 1;
    return pointer;
  });
  const length = await imports.check.fn(...pointers);
  imports.take(4096);
  return JSON.parse(decoder.decode(bytes.subarray(4096, 4096 + length)));
}

const check = (env, bindingName, key) => callBytes(env, [encoder.encode(bindingName), encoder.encode(key)]);

await test("check answers success from the binding", async () => {
  const rateLimit = fakeRateLimit((calls) => calls <= 2);
  const env = { API_LIMITER: rateLimit };
  assert.deepEqual(await check(env, "API_LIMITER", "user:1"), { success: true });
  assert.deepEqual(await check(env, "API_LIMITER", "user:1"), { success: true });
  assert.deepEqual(await check(env, "API_LIMITER", "user:1"), { success: false });
  assert.deepEqual(rateLimit.calls, [{ key: "user:1" }, { key: "user:1" }, { key: "user:1" }]);
});

await test("keys cross as UTF-8", async () => {
  const rateLimit = fakeRateLimit(() => true);
  await check({ API_LIMITER: rateLimit }, "API_LIMITER", "日本:café");
  assert.deepEqual(rateLimit.calls, [{ key: "日本:café" }]);
});

await test("the binding is chosen per call", async () => {
  const first = fakeRateLimit(() => true);
  const second = fakeRateLimit(() => false);
  const env = { FIRST: first, SECOND: second };
  assert.deepEqual(await check(env, "FIRST", "k"), { success: true });
  assert.deepEqual(await check(env, "SECOND", "k"), { success: false });
});

await test("a failure of the binding is an error result", async () => {
  const rateLimit = fakeRateLimit(() => true);
  rateLimit.failure = "invalid key: 1";
  assert.deepEqual(await check({ API_LIMITER: rateLimit }, "API_LIMITER", "k"), { error: "invalid key: 1" });
});

await test("a missing binding is a misconfiguration naming it, not an error", async () => {
  const bucket = { get() {}, put() {}, delete() {} };
  for (const env of [{}, { API_LIMITER: "not a limiter" }, { API_LIMITER: null }, { API_LIMITER: bucket }]) {
    assert.deepEqual(await check(env, "API_LIMITER", "k"), { misconfigured: "no rate limit binding API_LIMITER" });
  }
});

await test("a binding name that is not valid UTF-8 is an error result and reaches no binding", async () => {
  const rateLimit = fakeRateLimit(() => true);
  const result = await callBytes({ API_LIMITER: rateLimit }, [Uint8Array.of(0x41, 0xff), encoder.encode("k")]);
  assert.equal(typeof result.error, "string");
  assert.deepEqual(rateLimit.calls, []);
});

await test("an answer without success is not exceeded, and only success: false is", async () => {
  for (const [answer, expected] of [[{}, true], [{ success: false }, false], [{ success: true }, true], [{ success: 0 }, true]]) {
    const rateLimit = { async limit() { return answer; } };
    assert.deepEqual(await check({ API_LIMITER: rateLimit }, "API_LIMITER", "k"), { success: expected });
  }
});

await test("take copies a result larger than the previous one in full", async () => {
  const big = "x".repeat(900);
  const env = { API_LIMITER: fakeRateLimit(() => true), [big]: null };
  assert.deepEqual(await check(env, "API_LIMITER", "k"), { success: true });
  const result = await check(env, big, "k");
  assert.equal(result.misconfigured, `no rate limit binding ${big}`);
});

console.log(`${count} js cloudflare ratelimit tests passed`);
