// WebAssembly.Suspending (JSPI) is replaced even when node has it; the stand-in
// keeps the function so the import can be called.
import assert from "node:assert/strict";
import { kvImports, putOptions, MIN_EXPIRATION_TTL } from "../../js/cloudflare-kv.js";

WebAssembly.Suspending = class { constructor(fn) { this.fn = fn; } };

let count = 0;
async function test(name, fn) {
  await fn();
  count++;
  console.log(`ok   js cloudflare kv ${name}`);
}

const memory = new WebAssembly.Memory({ initial: 1 });
const encoder = new TextEncoder();
const decoder = new TextDecoder();

function fakeNamespace() {
  const namespace = {
    entries: new Map(),
    puts: [],
    gets: [],
    deletes: [],
    async get(key, type) {
      namespace.gets.push([key, type]);
      if (namespace.failure) throw new Error(namespace.failure);
      return namespace.entries.has(key) ? namespace.entries.get(key) : null;
    },
    async put(key, value, options) {
      namespace.puts.push([key, value, options]);
      if (namespace.failure) throw new Error(namespace.failure);
      namespace.entries.set(key, value);
    },
    async getWithMetadata(key) {
      return { value: await namespace.get(key, "text"), metadata: null };
    },
    async delete(key) {
      namespace.deletes.push(key);
      if (namespace.failure) throw new Error(namespace.failure);
      namespace.entries.delete(key);
    },
  };
  return namespace;
}

async function callBytes(env, name, byteArrays, expiresIn) {
  const imports = kvImports(env, () => ({ exports: { memory } })).edgeway_kv;
  const bytes = new Uint8Array(memory.buffer);
  let offset = 16;
  const pointers = byteArrays.map((encoded) => {
    bytes.set(encoded, offset);
    bytes[offset + encoded.length] = 0;
    const pointer = offset;
    offset += encoded.length + 1;
    return pointer;
  });
  const extra = expiresIn === undefined ? [] : [expiresIn];
  const length = await imports[name].fn(...pointers, ...extra);
  imports.take(4096);
  return JSON.parse(decoder.decode(bytes.subarray(4096, 4096 + length)));
}

async function call(env, name, strings, expiresIn) {
  return callBytes(env, name, strings.map((text) => encoder.encode(text)), expiresIn);
}

await test("get answers the text, or null for a miss", async () => {
  const namespace = fakeNamespace();
  namespace.entries.set("greeting", "{\"v\":\"hello\"}");
  const env = { CACHE: namespace };
  assert.deepEqual(await call(env, "get", ["CACHE", "greeting"]), { value: "{\"v\":\"hello\"}" });
  assert.deepEqual(await call(env, "get", ["CACHE", "absent"]), { value: null });
  assert.deepEqual(namespace.gets, [["greeting", "text"], ["absent", "text"]]);
});

await test("put stores the text and passes the expiry as expirationTtl", async () => {
  const namespace = fakeNamespace();
  const env = { CACHE: namespace };
  assert.deepEqual(await call(env, "put", ["CACHE", "a", "{\"v\":1}"], 300), { ok: true });
  assert.deepEqual(namespace.puts, [["a", "{\"v\":1}", { expirationTtl: 300 }]]);
  assert.equal(namespace.entries.get("a"), "{\"v\":1}");
});

await test("an expiry under KV's minimum is raised to it", async () => {
  const namespace = fakeNamespace();
  const env = { CACHE: namespace };
  await call(env, "put", ["CACHE", "a", "x"], 10);
  await call(env, "put", ["CACHE", "b", "x"], 60);
  await call(env, "put", ["CACHE", "c", "x"], 61);
  assert.deepEqual(namespace.puts.map(([, , options]) => options), [
    { expirationTtl: MIN_EXPIRATION_TTL }, { expirationTtl: 60 }, { expirationTtl: 61 },
  ]);
});

await test("put without an expiry passes no options", async () => {
  const namespace = fakeNamespace();
  await call({ CACHE: namespace }, "put", ["CACHE", "a", "x"], 0);
  assert.equal(namespace.puts[0][2], undefined);
  assert.equal(putOptions(0), undefined);
  assert.equal(putOptions(-1), undefined);
});

await test("delete removes the key", async () => {
  const namespace = fakeNamespace();
  namespace.entries.set("a", "x");
  assert.deepEqual(await call({ CACHE: namespace }, "delete", ["CACHE", "a"]), { ok: true });
  assert.deepEqual(namespace.deletes, ["a"]);
  assert.equal(namespace.entries.has("a"), false);
});

await test("keys and texts cross as UTF-8", async () => {
  const namespace = fakeNamespace();
  const env = { CACHE: namespace };
  await call(env, "put", ["CACHE", "日本:café", "{\"v\":\"日本\"}"], 0);
  assert.deepEqual(await call(env, "get", ["CACHE", "日本:café"]), { value: "{\"v\":\"日本\"}" });
});

await test("a KV failure is an error result", async () => {
  const namespace = fakeNamespace();
  namespace.failure = "KV PUT failed: 429 Too Many Requests";
  const env = { CACHE: namespace };
  assert.deepEqual(await call(env, "get", ["CACHE", "a"]), { error: "KV PUT failed: 429 Too Many Requests" });
  assert.deepEqual(await call(env, "put", ["CACHE", "a", "x"], 0), { error: "KV PUT failed: 429 Too Many Requests" });
  assert.deepEqual(await call(env, "delete", ["CACHE", "a"]), { error: "KV PUT failed: 429 Too Many Requests" });
});

await test("a missing binding is an error result naming it", async () => {
  const bucket = { get() {}, put() {}, delete() {} };
  for (const env of [{}, { CACHE: "not a namespace" }, { CACHE: null }, { CACHE: bucket }]) {
    assert.deepEqual(await call(env, "get", ["CACHE", "a"]), { error: "no KV binding CACHE" });
    assert.deepEqual(await call(env, "put", ["CACHE", "a", "x"], 0), { error: "no KV binding CACHE" });
    assert.deepEqual(await call(env, "delete", ["CACHE", "a"]), { error: "no KV binding CACHE" });
  }
});

await test("the binding is chosen per call", async () => {
  const first = fakeNamespace();
  const second = fakeNamespace();
  const env = { FIRST: first, SECOND: second };
  await call(env, "put", ["FIRST", "a", "1"], 0);
  await call(env, "put", ["SECOND", "a", "2"], 0);
  assert.equal(first.entries.get("a"), "1");
  assert.equal(second.entries.get("a"), "2");
});

await test("a key that is not valid UTF-8 is an error result and reaches no namespace", async () => {
  const namespace = fakeNamespace();
  const env = { CACHE: namespace };
  const result = await callBytes(env, "get", [encoder.encode("CACHE"), Uint8Array.of(0x6b, 0xff, 0x6b)]);
  assert.equal(typeof result.error, "string");
  assert.deepEqual(namespace.gets, []);
});

await test("take copies a result larger than the previous one in full", async () => {
  const namespace = fakeNamespace();
  const big = "x".repeat(900);
  namespace.entries.set("small", "a");
  namespace.entries.set("big", big);
  const env = { CACHE: namespace };
  assert.deepEqual(await call(env, "get", ["CACHE", "small"]), { value: "a" });
  assert.deepEqual(await call(env, "get", ["CACHE", "big"]), { value: big });
});

console.log(`${count} js cloudflare kv tests passed`);
