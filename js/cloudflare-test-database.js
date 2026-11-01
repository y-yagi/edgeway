// The databases of `edgeway test` on a local D1: dropped and migrated again
// before each test, so every test starts from the migrations' state.
import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

// What wrangler and D1 keep in the database themselves.
const KEPT_OBJECT = /^(sqlite_|_cf_)|^d1_migrations$/;

const quoted = (name) => `"${name.replaceAll('"', '""')}"`;

const COMMENT = /--[^\n]*|\/\*[\s\S]*?\*\//g;
const withoutComments = (sql) => sql.replace(COMMENT, " ");
const startsTrigger = (statement) => /^\s*create\s+(temp(orary)?\s+)?trigger\b/i.test(withoutComments(statement));
// A trigger's body is statements ending in ';', and the trigger ends at the
// END after the last of them (sqlite3_complete's rule): not at the END of a
// CASE, nor a column named end.
const triggerEnded = (statement) => /;\s*end\s*$/i.test(withoutComments(statement));

// SQL text split into statements at the ';' outside strings, comments and a
// trigger's body. Each statement is run with prepare(), which takes one.
// Text with nothing but comments is no statement (D1 refuses it).
export function splitStatements(sql) {
  const statements = [];
  let current = "";
  let at = 0;
  const copyUntil = (terminator) => {
    const stop = sql.indexOf(terminator, at + 1);
    const end = stop === -1 ? sql.length : stop + terminator.length;
    current += sql.slice(at, end);
    at = end;
  };
  const endsStatement = () => !startsTrigger(current) || triggerEnded(current);
  while (at < sql.length) {
    const char = sql[at];
    if (char === "'" || char === '"' || char === "`") copyUntil(char);
    else if (char === "[") copyUntil("]");
    else if (sql.startsWith("--", at)) copyUntil("\n");
    else if (sql.startsWith("/*", at)) copyUntil("*/");
    else if (char === ";" && endsStatement()) {
      statements.push(current.trim());
      current = "";
      at++;
    } else {
      current += char;
      at++;
    }
  }
  statements.push(current.trim());
  return statements.filter((statement) => withoutComments(statement).trim() !== "");
}

// The files of a migrations directory in file name order, each as
// { name, statements }. A directory that is not there has none.
export function migrationFiles(directory, { readdir = readdirSync, read = readFileSync, exists = existsSync } = {}) {
  if (!exists(directory)) return [];
  return readdir(directory)
    .filter((name) => name.endsWith(".sql"))
    .sort()
    .map((name) => ({ name, statements: splitStatements(read(join(directory, name), "utf8")) }));
}

// databases: [{ binding, migrations: directory }]
export function loadMigrations(databases, options) {
  return databases.map(({ binding, migrations }) => ({ binding, files: migrationFiles(migrations, options) }));
}

// The statements that empty a database, from the rows of sqlite_master
// ({ type, name }). Dropping a table drops its indexes and triggers. Foreign
// keys are enforced, so the checks wait for the end of the batch.
export function dropStatements(objects) {
  const dropped = objects.filter(({ name }) => !KEPT_OBJECT.test(name));
  const views = dropped.filter(({ type }) => type === "view");
  const tables = dropped.filter(({ type }) => type === "table");
  if (views.length + tables.length === 0) return [];
  return [
    "PRAGMA defer_foreign_keys = on",
    ...views.map(({ name }) => `DROP VIEW IF EXISTS ${quoted(name)}`),
    ...tables.map(({ name }) => `DROP TABLE IF EXISTS ${quoted(name)}`),
  ];
}

async function dropEverything(database) {
  const { results } = await database.prepare("SELECT type, name FROM sqlite_master WHERE type IN ('table', 'view')").all();
  const statements = dropStatements(results);
  if (statements.length > 0) await database.batch(statements.map((sql) => database.prepare(sql)));
}

async function migrate(database, files) {
  for (const { name, statements } of files) {
    if (statements.length === 0) continue;
    try {
      await database.batch(statements.map((sql) => database.prepare(sql)));
    } catch (error) {
      throw new Error(`migration ${name}: ${error?.message ?? error}`);
    }
  }
}

// migrations: loadMigrations' answer. Entries that share a binding are one
// database: it is emptied once, then every entry's files are applied in order.
export async function resetDatabases(env, migrations) {
  const filesByBinding = new Map();
  for (const { binding, files } of migrations) {
    filesByBinding.set(binding, [...(filesByBinding.get(binding) ?? []), ...files]);
  }
  for (const [binding, files] of filesByBinding) {
    const database = env[binding];
    if (!database) throw new Error(`no D1 binding ${binding} in wrangler.toml`);
    await dropEverything(database);
    await migrate(database, files);
  }
}
