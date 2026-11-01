// Tests of js/cloudflare-test-database.js with plain node and a fake D1:
// node test/js/cloudflare_test_database_test.mjs
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { splitStatements, migrationFiles, loadMigrations, dropStatements, resetDatabases } from "../../js/cloudflare-test-database.js";

let count = 0;
async function test(name, fn) {
  await fn();
  count++;
  console.log(`ok   js test database ${name}`);
}

function fakeDatabase(objects) {
  const calls = [];
  return {
    calls,
    prepare: (sql) => ({
      sql,
      all: async () => ({ results: objects }),
    }),
    batch: async (statements) => calls.push(statements.map((statement) => statement.sql)),
  };
}

await test("splitStatements splits at semicolons outside strings and comments", () => {
  const sql = "CREATE TABLE a (x TEXT);\n-- one; two\nINSERT INTO a VALUES ('a;b', \"c;d\"); /* e; */ INSERT INTO a VALUES ('it''s');\n";
  assert.deepEqual(splitStatements(sql), [
    "CREATE TABLE a (x TEXT)",
    "-- one; two\nINSERT INTO a VALUES ('a;b', \"c;d\")",
    "/* e; */ INSERT INTO a VALUES ('it''s')",
  ]);
});

await test("splitStatements keeps a trigger body whole", () => {
  const trigger = "CREATE TRIGGER t AFTER INSERT ON a BEGIN\n  UPDATE a SET x = 1;\n  UPDATE a SET x = 2;\nEND";
  assert.deepEqual(splitStatements(`${trigger};\nSELECT 1;`), [trigger, "SELECT 1"]);
});

await test("splitStatements answers the last statement without a semicolon and none for blank text", () => {
  assert.deepEqual(splitStatements("SELECT 1; SELECT 2"), ["SELECT 1", "SELECT 2"]);
  assert.deepEqual(splitStatements(" \n"), []);
});

await test("splitStatements drops text that is only comments", () => {
  assert.deepEqual(splitStatements("SELECT 1;\n-- trailing\n"), ["SELECT 1"]);
  assert.deepEqual(splitStatements("-- only a comment\n/* and another */\n"), []);
  assert.deepEqual(splitStatements("SELECT 1; /* c */ ; SELECT 2;"), ["SELECT 1", "SELECT 2"]);
});

await test("splitStatements ends a trigger only at the END after a ';'", () => {
  const caseTrigger = "CREATE TRIGGER t AFTER INSERT ON a BEGIN\n  UPDATE a SET x = CASE WHEN 1 THEN 2 END;\n  UPDATE a SET y = 1;\nEND";
  assert.deepEqual(splitStatements(`${caseTrigger};\nSELECT 1;`), [caseTrigger, "SELECT 1"]);
  const columnTrigger = "CREATE TRIGGER t AFTER INSERT ON a BEGIN\n  UPDATE a SET y = new.end;\n  -- done\nEND";
  assert.deepEqual(splitStatements(`${columnTrigger};`), [columnTrigger]);
});

await test("migrationFiles reads the .sql files in file name order", () => {
  const directory = mkdtempSync(join(tmpdir(), "edgeway-migrations-"));
  writeFileSync(join(directory, "0002_b.sql"), "CREATE TABLE b (id INTEGER);");
  writeFileSync(join(directory, "0010_c.sql"), "SELECT 1;");
  writeFileSync(join(directory, "0001_a.sql"), "CREATE TABLE a (id INTEGER);\nINSERT INTO a VALUES (1);");
  writeFileSync(join(directory, "notes.txt"), "not a migration");
  mkdirSync(join(directory, "sub.sql.d"));
  assert.deepEqual(migrationFiles(directory), [
    { name: "0001_a.sql", statements: ["CREATE TABLE a (id INTEGER)", "INSERT INTO a VALUES (1)"] },
    { name: "0002_b.sql", statements: ["CREATE TABLE b (id INTEGER)"] },
    { name: "0010_c.sql", statements: ["SELECT 1"] },
  ]);
});

await test("migrationFiles has no files for a missing directory", () => {
  assert.deepEqual(migrationFiles("/no/such/migrations"), []);
});

await test("loadMigrations pairs each binding with its files", () => {
  const directory = mkdtempSync(join(tmpdir(), "edgeway-migrations-"));
  writeFileSync(join(directory, "0001.sql"), "SELECT 1;");
  assert.deepEqual(loadMigrations([{ binding: "DB", migrations: directory }]),
    [{ binding: "DB", files: [{ name: "0001.sql", statements: ["SELECT 1"] }] }]);
});

await test("dropStatements drops views and tables, and keeps SQLite's and Cloudflare's own", () => {
  const objects = [
    { type: "table", name: "posts" },
    { type: "table", name: "sqlite_sequence" },
    { type: "table", name: "_cf_KV" },
    { type: "table", name: "d1_migrations" },
    { type: "view", name: "post_titles" },
    { type: "table", name: 'we"ird' },
  ];
  assert.deepEqual(dropStatements(objects), [
    "PRAGMA defer_foreign_keys = on",
    'DROP VIEW IF EXISTS "post_titles"',
    'DROP TABLE IF EXISTS "posts"',
    'DROP TABLE IF EXISTS "we""ird"',
  ]);
});

await test("dropStatements has nothing to run for an empty database", () => {
  assert.deepEqual(dropStatements([{ type: "table", name: "sqlite_sequence" }]), []);
});

await test("resetDatabases drops, then applies each migration file in a batch", async () => {
  const database = fakeDatabase([{ type: "table", name: "posts" }]);
  const files = [
    { name: "0001.sql", statements: ["CREATE TABLE posts (id INTEGER)", "INSERT INTO posts VALUES (1)"] },
    { name: "0002.sql", statements: ["CREATE TABLE tags (id INTEGER)"] },
  ];
  await resetDatabases({ DB: database }, [{ binding: "DB", files }]);
  assert.deepEqual(database.calls, [
    ["PRAGMA defer_foreign_keys = on", 'DROP TABLE IF EXISTS "posts"'],
    ["CREATE TABLE posts (id INTEGER)", "INSERT INTO posts VALUES (1)"],
    ["CREATE TABLE tags (id INTEGER)"],
  ]);
});

await test("resetDatabases empties a binding once for the entries that share it", async () => {
  const database = fakeDatabase([{ type: "table", name: "old" }]);
  const migrations = [
    { binding: "DB", files: [{ name: "0001.sql", statements: ["CREATE TABLE a (id INTEGER)"] }] },
    { binding: "DB", files: [{ name: "0001.sql", statements: ["CREATE TABLE b (id INTEGER)"] }] },
  ];
  await resetDatabases({ DB: database }, migrations);
  assert.deepEqual(database.calls, [
    ["PRAGMA defer_foreign_keys = on", 'DROP TABLE IF EXISTS "old"'],
    ["CREATE TABLE a (id INTEGER)"],
    ["CREATE TABLE b (id INTEGER)"],
  ]);
});

await test("resetDatabases runs nothing for a migration with only comments", async () => {
  const database = fakeDatabase([]);
  await resetDatabases({ DB: database }, [{ binding: "DB", files: [{ name: "0001.sql", statements: splitStatements("-- nothing\n") }] }]);
  assert.deepEqual(database.calls, []);
});

await test("resetDatabases names the migration that failed", async () => {
  const database = fakeDatabase([]);
  database.batch = async () => { throw new Error("syntax error"); };
  await assert.rejects(
    resetDatabases({ DB: database }, [{ binding: "DB", files: [{ name: "0001_bad.sql", statements: ["oops"] }] }]),
    /migration 0001_bad.sql: syntax error/,
  );
});

await test("resetDatabases names a binding that wrangler.toml lacks", async () => {
  await assert.rejects(resetDatabases({}, [{ binding: "ANALYTICS", files: [] }]), /no D1 binding ANALYTICS in wrangler.toml/);
});

console.log(`${count} js test database tests passed`);
