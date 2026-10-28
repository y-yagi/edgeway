// The Cloudflare Workers side of an Edgeway app. A worker is three lines:
//
//   import app from "../build/app.wasm";
//   import { createWorker } from "../build/edgeway/cloudflare.js";
//   export default createWorker(app);
//
// build/edgeway/config.js is written by `edgeway build` from
// config/database.yml: the environment name and the D1 binding.
import { runCgi } from "./runtime.js";
import config from "./config.js";
import { jwtImports } from "./jwt.js";
import { withCors } from "./cors.js";

// D1's transient errors, which are worth a retry by the client
// (developers.cloudflare.com/d1/observability/debug-d1/). D1 retries read-only
// queries itself; Edgeway never retries, as a write is not idempotent.
// "exceeded", "CPU time limit", "memory limit" and "timeout" are not here.
export const TRANSIENT_D1_ERRORS = [
  "Network connection lost",
  "reset because its code was updated",
  "storage caused object to be reset",
  "Replica disconnected from primary",
  "transient issue on remote node",
  "Can't read from request stream because client disconnected",
  "D1 DB is overloaded",
];

export const isTransientD1Error = (message) => TRANSIENT_D1_ERRORS.some((s) => message.includes(s));

// Counts are 32-bit in wasm: a larger one is clamped.
const MAX_COUNT = 2147483647;

// D1's result.meta in the shape of META above. A local D1 (wrangler dev) may
// leave fields out.
export function metaOf(meta) {
  return {
    rows_read: Math.min(meta?.rows_read ?? 0, MAX_COUNT),
    rows_written: Math.min(meta?.rows_written ?? 0, MAX_COUNT),
    duration: meta?.duration ?? 0,
    served_by_region: meta?.served_by_region ?? "",
    served_by_primary: meta?.served_by_primary ?? true,
  };
}

export function sumMeta(metas) {
  const all = metas.map(metaOf);
  const sum = (field) => all.reduce((total, meta) => total + meta[field], 0);
  return {
    ...all[all.length - 1],
    rows_read: Math.min(sum("rows_read"), MAX_COUNT),
    rows_written: Math.min(sum("rows_written"), MAX_COUNT),
    duration: sum("duration"),
  };
}

// A BLOB crosses as {"$blob": "<base64>"}. D1 binds an ArrayBuffer as a BLOB and
// answers a BLOB column as an Array of byte numbers.
export function bindOf(value) {
  if (value === null || typeof value !== "object" || typeof value.$blob !== "string") return value;
  return Uint8Array.from(atob(value.$blob), (char) => char.charCodeAt(0)).buffer;
}

const isBytes = (value) => Array.isArray(value) || value instanceof ArrayBuffer || ArrayBuffer.isView(value);

function bytesOf(value) {
  if (Array.isArray(value)) return Uint8Array.from(value);
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  return new Uint8Array(value);
}

function base64Of(value) {
  const bytes = bytesOf(value);
  let binary = "";
  for (let at = 0; at < bytes.length; at += 8192) binary += String.fromCharCode(...bytes.subarray(at, at + 8192));
  return btoa(binary);
}

export function rowOf(row) {
  for (const column of Object.keys(row)) {
    const value = row[column];
    if (value !== null && typeof value === "object" && isBytes(value)) row[column] = { $blob: base64Of(value) };
  }
  return row;
}

// The wasm import module "edgeway_d1" (lib/edgeway/service/cloudflare/d1.rb). Each call
// answers the byte length of its JSON result; take() copies it out.
//   query(binding, sql, binds)   -> {"rows": [...], "meta": META}
//   execute(binding, sql, binds) -> {"changes": n, "last_insert_id": id, "meta": META}
//   batch(binding, statements)   -> {"results": [{"changes": n, "last_insert_id": id}, ...], "meta": META}
//                                   (statements: [[sql, binds], ...], one atomic D1 batch)
// META is {"rows_read": n, "rows_written": n, "duration": ms, "served_by_region": "...",
// "served_by_primary": bool}; a batch's sums the statements'.
// An error is {"error": "message"} (no meta), with "unavailable": true when it is transient.
export function d1Imports(env, getInstance) {
  const mem = () => new Uint8Array(getInstance().exports.memory.buffer);
  const cstr = (p) => {
    const b = mem();
    let e = p;
    while (b[e]) e++;
    return new TextDecoder().decode(b.subarray(p, e));
  };
  let pending = new Uint8Array(0);

  // fn(db, ...pointers) answers the result object; a failure is {error}.
  const suspending = (fn) => new WebAssembly.Suspending(async (bindingPtr, ...ptrs) => {
    let res;
    try {
      const name = cstr(bindingPtr) || config.d1Binding;
      const db = env[name];
      if (!db) throw new Error(`no D1 binding ${name}`);
      res = await fn(db, ...ptrs);
    } catch (e) {
      const error = String(e?.message ?? e);
      res = isTransientD1Error(error) ? { error, unavailable: true } : { error };
    }
    pending = new TextEncoder().encode(JSON.stringify(res));
    return pending.length;
  });
  const prepare = (db, sql, binds) => db.prepare(sql).bind(...binds.map(bindOf));
  const run = (fn) => suspending((db, sqlPtr, bindsPtr) =>
    fn(prepare(db, cstr(sqlPtr), JSON.parse(cstr(bindsPtr)))));

  return {
    edgeway_d1: {
      query: run(async (statement) => {
        const result = await statement.all();
        return { rows: result.results.map(rowOf), meta: metaOf(result.meta) };
      }),
      execute: run(async (statement) => {
        const meta = (await statement.run()).meta;
        return { changes: meta.changes ?? 0, last_insert_id: meta.last_row_id ?? 0, meta: metaOf(meta) };
      }),
      // db.batch() is one transaction: a failing statement rejects it and
      // none of the statements stay applied.
      batch: suspending(async (db, statementsPtr) => {
        const statements = JSON.parse(cstr(statementsPtr));
        const results = await db.batch(statements.map(([sql, binds]) => prepare(db, sql, binds)));
        return {
          results: results.map((result) => ({ changes: result.meta.changes ?? 0, last_insert_id: result.meta.last_row_id ?? 0 })),
          meta: sumMeta(results.map((result) => result.meta)),
        };
      }),
      take(buf) {
        mem().set(pending, buf);
      },
    },
  };
}

// The settings of the framework that Edgeway.config reads in wasm. The CORS_*
// ones and JWT_SECRET are read from env in JS (cors.js, jwt.js), so they stay
// out.
const FRAMEWORK_VARS = new Set([
  "JWT_ISSUER", "JWT_AUDIENCE", "JWT_LEEWAY", "JWT_ALGORITHMS", "JWT_JWKS_URL",
]);

// The Worker's variables (strings) become CGI environment variables, which
// Edgeway.config reads. Only an allow-list goes in, so a secret that the
// Worker holds for something else is not readable by the app (or its logs):
// the framework's settings, and the names that start with APP_, for the app's
// own. JWT_SECRET never does: js/jwt.js reads it from env, so the key never
// enters wasm.
export function varsOf(env) {
  const vars = {};
  for (const [k, v] of Object.entries(env)) {
    if (typeof v !== "string" || k === "JWT_SECRET") continue;
    if (FRAMEWORK_VARS.has(k) || k.startsWith("APP_")) vars[k] = v;
  }
  return vars;
}

// appModule: the WebAssembly.Module that `import app from "...app.wasm"` gives.
export function createWorker(appModule) {
  return {
    fetch: withCors((request, env) => runCgi(appModule, request, {
      extraEnv: { EDGEWAY_ENV: config.env, ...varsOf(env) },
      // Both modules are always supplied, whether or not the app uses them:
      // the wasm instance needs every import it declares.
      imports: (getInstance) => ({ ...d1Imports(env, getInstance), ...jwtImports(env, getInstance) }),
    })),
  };
}
