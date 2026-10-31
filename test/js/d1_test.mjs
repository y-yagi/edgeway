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
const { D1Sessions, parseBookmarks } = await import(pathToFileURL(join(dir, "cloudflare-d1-sessions.js")));
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
  return callWith(new D1Sessions(env), env, name, ...strings);
}
async function callWith(sessions, env, name, ...strings) {
  const imports = d1Imports(env, () => ({ exports: { memory } }), sessions).edgeway_d1;
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

function recordingStatement(rows) {
  return { binds: [], bind(...b) { this.binds = b; return this; }, async all() { return { results: rows, meta: {} }; }, async run() { return { meta: {} }; } };
}

const blob = (...bytes) => ({ $blob: btoa(String.fromCharCode(...bytes)) });

await test("a $blob bind is bound as an ArrayBuffer of its bytes", async () => {
  const statement = recordingStatement([]);
  const db = { prepare: () => statement };
  await call({ DB: db }, "execute", "DB", "INSERT INTO t (d, n) VALUES (?, ?)", JSON.stringify([blob(0, 1, 255, 0, 128), 7]));
  assert.ok(statement.binds[0] instanceof ArrayBuffer);
  assert.deepEqual([...new Uint8Array(statement.binds[0])], [0, 1, 255, 0, 128]);
  assert.equal(statement.binds[1], 7);
});

await test("other binds are left as they are", async () => {
  const statement = recordingStatement([]);
  const db = { prepare: () => statement };
  await call({ DB: db }, "query", "DB", "SELECT 1", JSON.stringify([null, "text", 1.5, "3000000000", { other: 1 }]));
  assert.deepEqual(statement.binds, [null, "text", 1.5, "3000000000", { other: 1 }]);
});

await test("batch binds a $blob as bytes in every statement", async () => {
  const db = fakeD1();
  const bound = [];
  db.prepare = (sql) => ({ sql, bind(...b) { bound.push(b); return this; } });
  await call({ DB: db }, "batch", "DB", JSON.stringify([["UPDATE t SET d = ?", [blob(9, 0)]], ["UPDATE t SET d = ?", [blob(255)]]]));
  assert.deepEqual(bound.map(([bytes]) => [...new Uint8Array(bytes)]), [[9, 0], [255]]);
});

await test("a BLOB column is answered as $blob, whatever shape D1 gives", async () => {
  const bytes = [0, 1, 255, 0, 128];
  const rows = [
    { id: 1, d: bytes },
    { id: 2, d: Uint8Array.from(bytes) },
    { id: 3, d: Uint8Array.from(bytes).buffer },
    { id: 4, d: null, name: "x", score: 1.5 },
  ];
  const db = { prepare: () => recordingStatement(rows) };
  const res = await call({ DB: db }, "query", "DB", "SELECT * FROM t", "[]");
  const expected = blob(...bytes);
  assert.deepEqual(res.rows, [{ id: 1, d: expected }, { id: 2, d: expected }, { id: 3, d: expected }, { id: 4, d: null, name: "x", score: 1.5 }]);
});

await test("a large BLOB round-trips through base64", async () => {
  const bytes = Array.from({ length: 20000 }, (_v, i) => i % 256);
  const db = { prepare: () => recordingStatement([{ d: bytes }]) };
  const res = await call({ DB: db }, "query", "DB", "SELECT d FROM t", "[]");
  assert.deepEqual([...Uint8Array.from(atob(res.rows[0].d.$blob), (c) => c.charCodeAt(0))], bytes);
});

await test("execute answers a rowid beyond 32 bits as the number D1 gave", async () => {
  const db = { prepare: () => fakeStatement({ changes: 1, last_row_id: 3000000000 }) };
  const res = await call({ DB: db }, "execute", "DB", "INSERT INTO t DEFAULT VALUES", "[]");
  assert.equal(res.last_insert_id, 3000000000);
});

await test("meta fields that D1 leaves out get defaults", async () => {
  const db = { prepare: () => fakeStatement({ rows_read: 3 }) };
  const res = await call({ DB: db }, "query", "DB", "SELECT 1", "[]");
  assert.deepEqual(res.meta, { rows_read: 3, rows_written: 0, duration: 0, served_by_region: "", served_by_primary: true });
});

await test("exec runs the SQL text and answers D1's count and duration", async () => {
  const sqls = [];
  const db = { async exec(sql) { sqls.push(sql); return { count: 2, duration: 0.75 }; } };
  const res = await call({ DB: db }, "exec", "DB", "CREATE TABLE t (a)\nINSERT INTO t VALUES (1)");
  assert.deepEqual(sqls, ["CREATE TABLE t (a)\nINSERT INTO t VALUES (1)"]);
  assert.deepEqual(res, { count: 2, meta: { rows_read: 0, rows_written: 0, duration: 0.75 } });
});

await test("exec answers an error when D1 rejects it", async () => {
  const db = { async exec() { throw new Error("D1_EXEC_ERROR: syntax error"); } };
  assert.deepEqual(await call({ DB: db }, "exec", "DB", "NOPE"), { error: "D1_EXEC_ERROR: syntax error" });
});

await test("exec answers a transient D1 error as unavailable", async () => {
  const error = TRANSIENT_D1_ERRORS[0];
  const db = { async exec() { throw new Error(error); } };
  assert.deepEqual(await call({ DB: db }, "exec", "DB", "NOPE"), { error, unavailable: true });
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

function sessionDb(label, log) {
  const db = fakeD1();
  db.withSession = (start) => {
    log.push([label, start]);
    const session = fakeD1();
    session.getBookmark = () => `bm-${label}`;
    db.session = session;
    return session;
  };
  return db;
}
const requestWith = (method, bookmarkHeader) =>
  new Request("http://x/a", { method, headers: bookmarkHeader ? { "X-D1-Bookmark": bookmarkHeader } : {} });
const sessionsFor = (env, request, names = Object.keys(env)) => new D1Sessions(env, request, names);

await test("a session binding starts first-unconstrained for GET and HEAD, first-primary otherwise", async () => {
  for (const [method, constraint] of [["GET", "first-unconstrained"], ["HEAD", "first-unconstrained"], ["POST", "first-primary"], ["DELETE", "first-primary"]]) {
    const log = [];
    const env = { DB: sessionDb("DB", log) };
    await callWith(sessionsFor(env, requestWith(method)), env, "query", "DB", "SELECT 1", "[]");
    assert.deepEqual(log, [["DB", constraint]]);
  }
});

await test("the bookmark the request sent starts the session", async () => {
  const log = [];
  const env = { DB: sessionDb("DB", log), ANALYTICS: sessionDb("ANALYTICS", log) };
  const sessions = sessionsFor(env, requestWith("GET", "ANALYTICS=abc, DB = 0def "));
  await callWith(sessions, env, "query", "DB", "SELECT 1", "[]");
  await callWith(sessions, env, "query", "ANALYTICS", "SELECT 1", "[]");
  assert.deepEqual(log, [["DB", "0def"], ["ANALYTICS", "abc"]]);
});

await test("a write ignores the bookmark the request sent and starts first-primary", async () => {
  for (const method of ["POST", "PUT", "PATCH", "DELETE"]) {
    const log = [];
    const env = { DB: sessionDb("DB", log) };
    await callWith(sessionsFor(env, requestWith(method, "DB=0def")), env, "query", "DB", "SELECT 1", "[]");
    assert.deepEqual(log, [["DB", "first-primary"]]);
  }
});

await test("a write still echoes the sent bookmark of a session binding it did not use", async () => {
  const env = { DB: sessionDb("DB", []), ANALYTICS: sessionDb("ANALYTICS", []) };
  const sessions = sessionsFor(env, requestWith("POST", "ANALYTICS=b, DB=a"));
  await callWith(sessions, env, "batch", "DB", "[]");
  assert.equal(sessions.header(), "DB=bm-DB, ANALYTICS=b");
});

await test("a HEAD starts from the bookmark the request sent", async () => {
  const log = [];
  const env = { DB: sessionDb("DB", log) };
  await callWith(sessionsFor(env, requestWith("HEAD", "DB=0def")), env, "query", "DB", "SELECT 1", "[]");
  assert.deepEqual(log, [["DB", "0def"]]);
});

await test("the session is created once per request and used by query, execute and batch", async () => {
  const log = [];
  const env = { DB: sessionDb("DB", log) };
  const sessions = sessionsFor(env, requestWith("POST"));
  env.DB.withSession = ((withSession) => (start) => {
    const session = withSession(start);
    session.prepare = () => ({ bind() { return this; }, async all() { return { results: [{ id: "session" }], meta: {} }; }, async run() { return { meta: { changes: 5 } }; } });
    return session;
  })(env.DB.withSession);
  assert.equal((await callWith(sessions, env, "execute", "DB", "UPDATE t SET a = 1", "[]")).changes, 5);
  assert.deepEqual((await callWith(sessions, env, "query", "DB", "SELECT 1", "[]")).rows, [{ id: "session" }]);
  const res = await callWith(sessions, env, "batch", "DB", JSON.stringify([["UPDATE t SET a = ?", [1]]]));
  assert.equal(log.length, 1);
  assert.deepEqual(res.results, [{ changes: 1, last_insert_id: 10 }]);
  assert.deepEqual(env.DB.batches, [], "the batch ran on the session, not on the binding");
  assert.equal(env.DB.session.batches.length, 1);
});

await test("a binding that is not a session binding is used directly", async () => {
  const log = [];
  const env = { DB: sessionDb("DB", log), PLAIN: sessionDb("PLAIN", log) };
  const sessions = sessionsFor(env, requestWith("GET", "PLAIN=zzz"), ["DB"]);
  await callWith(sessions, env, "batch", "DB", "[]");
  await callWith(sessions, env, "batch", "PLAIN", "[]");
  assert.deepEqual(log, [["DB", "first-unconstrained"]]);
  assert.equal(env.PLAIN.batches.length, 1);
  assert.equal(sessions.header(), "DB=bm-DB");
});

await test("a bookmark for an unknown binding or garbage is ignored", async () => {
  const log = [];
  const env = { DB: sessionDb("DB", log) };
  const sessions = sessionsFor(env, requestWith("GET", "NOPE=1,,=a,DB=,junk, ,DB"));
  await callWith(sessions, env, "batch", "DB", "[]");
  assert.deepEqual(log, [["DB", "first-unconstrained"]]);
});

await test("a bookmark that does not look like D1's is ignored and not echoed", async () => {
  for (const bad of ["ABC-DEF", "zzzz-garbage", "a".repeat(129), "00000000 00000001", "<script>"]) {
    const log = [];
    const env = { DB: sessionDb("DB", log) };
    const sessions = sessionsFor(env, requestWith("GET", `DB=${bad}`));
    assert.equal(sessions.header(), "");
    await callWith(sessions, env, "batch", "DB", "[]");
    assert.deepEqual(log, [["DB", "first-unconstrained"]]);
  }
});

await test("a binding name that is not an identifier is ignored", async () => {
  assert.deepEqual(parseBookmarks("my-db=0a, 1DB=0b, DB_2=0c"), { DB_2: "0c" });
});

await test("the response header lists the used sessions as BINDING=bookmark pairs", async () => {
  const env = { DB: sessionDb("DB", []), ANALYTICS: sessionDb("ANALYTICS", []), IDLE: sessionDb("IDLE", []) };
  const sessions = sessionsFor(env, requestWith("GET"));
  assert.equal(sessions.header(), "");
  await callWith(sessions, env, "batch", "DB", "[]");
  assert.equal(sessions.header(), "DB=bm-DB");
  await callWith(sessions, env, "batch", "ANALYTICS", "[]");
  const response = sessions.annotate(new Response("ok"));
  assert.equal(response.headers.get("x-d1-bookmark"), "DB=bm-DB, ANALYTICS=bm-ANALYTICS");
});

await test("the header keeps the sent bookmark of a session binding the request did not use", async () => {
  const env = { DB: sessionDb("DB", []), ANALYTICS: sessionDb("ANALYTICS", []) };
  const sessions = sessionsFor(env, requestWith("GET", "ANALYTICS=b, DB=a, OTHER=c"), ["DB", "ANALYTICS"]);
  await callWith(sessions, env, "batch", "DB", "[]");
  assert.equal(sessions.header(), "DB=bm-DB, ANALYTICS=b");
  const untouched = sessionsFor(env, requestWith("GET", "DB=a, ANALYTICS=b, OTHER=c"), ["DB", "ANALYTICS"]);
  assert.equal(untouched.header(), "DB=a, ANALYTICS=b");
});

await test("a response varies on the bookmark header when sessions are configured", async () => {
  const env = { DB: sessionDb("DB", []) };
  const vary = (names, existing) => sessionsFor(env, requestWith("GET"), names)
    .annotate(new Response("ok", { headers: existing ? { Vary: existing } : {} })).headers.get("vary");
  assert.equal(vary(["DB"]), "X-D1-Bookmark");
  assert.equal(vary(["DB"], "Accept-Encoding"), "Accept-Encoding, X-D1-Bookmark");
  assert.equal(vary([]), null);
});

await test("a session without a bookmark adds no header, and an unused one neither", async () => {
  const env = { DB: sessionDb("DB", []) };
  const sessions = sessionsFor(env, requestWith("GET"));
  assert.equal(sessions.annotate(new Response("ok")).headers.get("x-d1-bookmark"), null);
  await callWith(sessions, env, "batch", "DB", "[]");
  sessions.sessions.get("DB").getBookmark = () => null;
  assert.equal(sessions.annotate(new Response("ok")).headers.get("x-d1-bookmark"), null);
});

await test("exec on a database with sessions answers an error", async () => {
  const log = [];
  const execs = [];
  const env = { DB: sessionDb("DB", log) };
  env.DB.exec = async (sql) => { execs.push(sql); return { count: 1, duration: 0 }; };
  const sessions = sessionsFor(env, requestWith("POST"));
  const res = await callWith(sessions, env, "exec", "DB", "DROP TABLE t");
  assert.match(res.error, /exec\(\) is not available on a database with sessions: true/);
  assert.deepEqual(execs, []);
  assert.deepEqual(log, []);
  assert.equal(sessions.header(), "");
});

rmSync(dir, { recursive: true, force: true });
console.log(`${count} js d1 tests passed`);
