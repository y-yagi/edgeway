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
const { d1Imports, isTransientD1Error, TRANSIENT_D1_ERRORS } = await import(pathToFileURL(join(dir, "cloudflare.js")));

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
      return stmts.map((_s, i) => ({ meta: { changes: i + 1, last_row_id: 10 + i, rows_read: 10 * (i + 1), rows_written: i + 1, duration: 0.5, served_by_region: `R${i}`, served_by_primary: i === 0 } }));
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
  assert.deepEqual(res, {
    results: [{ changes: 1, last_insert_id: 10 }, { changes: 2, last_insert_id: 11 }],
    meta: { rows_read: 30, rows_written: 3, duration: 1, served_by_region: "R1", served_by_primary: false },
  });
});

function fakeStatement(meta) {
  return { bind() { return this; }, async all() { return { results: [{ id: 1 }], meta }; }, async run() { return { meta }; } };
}

await test("query and execute answer D1's meta", async () => {
  const meta = { rows_read: 5, rows_written: 2, duration: 1.25, served_by_region: "WEUR", served_by_primary: false, changes: 2, last_row_id: 7 };
  const db = { prepare: () => fakeStatement(meta) };
  const expected = { rows_read: 5, rows_written: 2, duration: 1.25, served_by_region: "WEUR", served_by_primary: false };
  assert.deepEqual(await call({ DB: db }, "query", "DB", "SELECT 1", "[]"), { rows: [{ id: 1 }], meta: expected });
  assert.deepEqual(await call({ DB: db }, "execute", "DB", "UPDATE t SET a = 1", "[]"), { changes: 2, last_insert_id: 7, meta: expected });
});

await test("meta fields that D1 leaves out get defaults", async () => {
  const db = { prepare: () => fakeStatement({ rows_read: 3 }) };
  const res = await call({ DB: db }, "query", "DB", "SELECT 1", "[]");
  assert.deepEqual(res.meta, { rows_read: 3, rows_written: 0, duration: 0, served_by_region: "", served_by_primary: true });
});

await test("batch answers an error when D1 rejects it", async () => {
  const db = fakeD1();
  db.fail = "D1_ERROR: UNIQUE constraint failed: tags.name: SQLITE_CONSTRAINT";
  const res = await call({ DB: db }, "batch", "DB", JSON.stringify([["UPDATE t SET a = ?", [1]]]));
  assert.deepEqual(res, { error: db.fail });
  assert.equal("meta" in res, false);
});

await test("meta counts are clamped to 32 bits", async () => {
  const db = { prepare: () => fakeStatement({ rows_read: 3e9, rows_written: 2 }) };
  const res = await call({ DB: db }, "query", "DB", "SELECT 1", "[]");
  assert.equal(res.meta.rows_read, 2147483647);
});

await test("batch with an unknown binding answers an error", async () => {
  const res = await call({}, "batch", "DB", "[]");
  assert.deepEqual(res, { error: "no D1 binding DB" });
});

await test("a transient D1 failure answers unavailable", async () => {
  const db = fakeD1();
  db.fail = "D1_ERROR: Network connection lost";
  const res = await call({ DB: db }, "batch", "DB", JSON.stringify([["UPDATE t SET a = ?", [1]]]));
  assert.deepEqual(res, { error: db.fail, unavailable: true });
  assert.equal(db.batches.length, 1); // never retried
});

await test("query and execute answer unavailable for a transient failure", async () => {
  for (const name of ["query", "execute"]) {
    const db = fakeD1();
    db.prepare = () => ({ bind() { return this; }, async all() { throw new Error("D1 DB is overloaded"); }, async run() { throw new Error("D1 DB is overloaded"); } });
    const res = await call({ DB: db }, name, "DB", "SELECT 1", "[]");
    assert.deepEqual(res, { error: "D1 DB is overloaded", unavailable: true });
  }
});

await test("isTransientD1Error matches the transient messages only", () => {
  for (const m of TRANSIENT_D1_ERRORS) assert.equal(isTransientD1Error(`D1_ERROR: ${m}: x`), true);
  for (const m of ["exceeded its CPU time limit", "memory limit", "timeout", "UNIQUE constraint failed: t.a"]) {
    assert.equal(isTransientD1Error(m), false);
  }
});

rmSync(dir, { recursive: true, force: true });
console.log(`${count} js d1 tests passed`);
