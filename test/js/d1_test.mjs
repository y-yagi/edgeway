// Tests of the edgeway_d1 imports in js/cloudflare.js with plain node and a
// fake D1: node test/js/d1_test.mjs
// cloudflare.js needs config.js, which `edgeway build` writes, so js/ is copied
// to a temp dir with a stub. WebAssembly.Suspending (JSPI) is replaced even
// when node has it; the stand-in keeps the function so the import can be called.
import assert from "node:assert/strict";
import { cpSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

WebAssembly.Suspending = class { constructor(fn) { this.fn = fn; } };

const dir = mkdtempSync(join(tmpdir(), "edgeway-js-"));
cpSync(join(dirname(fileURLToPath(import.meta.url)), "../../js"), dir, { recursive: true });
writeFileSync(join(dir, "config.js"), 'export default { env: "test", d1Binding: "DB" };\n');
const { d1Imports } = await import(pathToFileURL(join(dir, "cloudflare.js")));

let count = 0;
async function test(name, fn) {
  await fn();
  count++;
  console.log(`ok   js d1 ${name}`);
}

// Wasm memory with C strings; call(fn, ...strings) runs an import and
// answers the JSON it leaves for take().
const memory = new WebAssembly.Memory({ initial: 1 });
const enc = new TextEncoder();
function fakeD1() {
  const db = {
    batches: [],
    prepare(sql) {
      return { sql, binds: [], bind(...b) { this.binds = b; return this; } };
    },
    async batch(stmts) {
      db.batches.push(stmts.map((s) => [s.sql, s.binds]));
      if (db.fail) throw new Error(db.fail);
      return stmts.map((_s, i) => ({ meta: { changes: i + 1, last_row_id: 10 + i } }));
    },
  };
  return db;
}
async function call(env, name, ...strings) {
  const imports = d1Imports(env, () => ({ exports: { memory } })).edgeway_d1;
  const bytes = new Uint8Array(memory.buffer);
  let at = 16;
  const ptrs = strings.map((s) => {
    const p = at;
    bytes.set(enc.encode(s), p);
    bytes[p + enc.encode(s).length] = 0;
    at += enc.encode(s).length + 1;
    return p;
  });
  const length = await imports[name].fn(...ptrs);
  imports.take(4096);
  return JSON.parse(new TextDecoder().decode(bytes.subarray(4096, 4096 + length)));
}

await test("batch sends the statements in one db.batch and answers a result each", async () => {
  const db = fakeD1();
  const res = await call({ DB: db }, "batch", "DB", JSON.stringify([["UPDATE t SET a = ?", [1]], ["DELETE FROM t", []]]));
  assert.deepEqual(db.batches, [[["UPDATE t SET a = ?", [1]], ["DELETE FROM t", []]]]);
  assert.deepEqual(res, { results: [{ changes: 1, last_insert_id: 10 }, { changes: 2, last_insert_id: 11 }] });
});

await test("batch answers an error when D1 rejects it", async () => {
  const db = fakeD1();
  db.fail = "D1_ERROR: UNIQUE constraint failed: tags.name: SQLITE_CONSTRAINT";
  const res = await call({ DB: db }, "batch", "DB", JSON.stringify([["UPDATE t SET a = ?", [1]]]));
  assert.deepEqual(res, { error: db.fail });
});

await test("batch with an unknown binding answers an error", async () => {
  const res = await call({}, "batch", "DB", "[]");
  assert.deepEqual(res, { error: "no D1 binding DB" });
});

rmSync(dir, { recursive: true, force: true });
console.log(`${count} js d1 tests passed`);
