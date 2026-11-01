// Runs the wasm build of an app's tests, on a local in-memory D1:
//
//   node cloudflare-test-runner.js TEST.wasm [ARGS...]
//
// `edgeway test` starts it (with --experimental-wasm-jspi and --experimental-wasm-exnref on Node.js 24); ARGS
// go to the program (-n NAME). The environment is wrangler's getPlatformProxy
// with persist: false, so the state in .wrangler/state is never touched. The
// wasm calls edgeway_test.reset before each test, and the exit status is its own.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import config from "./config.js";
import { WASI } from "./wasi-shim.js";
import { d1Imports, varsOf } from "./cloudflare.js";
import { jwtImports } from "./jwt.js";
import { D1Sessions } from "./cloudflare-d1-sessions.js";
import { loadMigrations, resetDatabases } from "./cloudflare-test-database.js";

function requireJspi() {
  if (typeof WebAssembly.Suspending === "function") return;
  throw new Error("this Node.js has no WebAssembly JSPI; Node.js 24 needs --experimental-wasm-jspi (`edgeway test` passes it)");
}

async function runTests(wasmPath, args, env) {
  const migrations = loadMigrations(config.databases);
  const wasi = new WASI({
    args: ["test", ...args],
    env: { ...varsOf(env), EDGEWAY_ENV: config.env },
    onStdout: (text) => process.stdout.write(text),
    onStderr: (text) => process.stderr.write(text),
  });
  const reset = new WebAssembly.Suspending(() => resetDatabases(env, migrations));
  let instance;
  instance = new WebAssembly.Instance(await WebAssembly.compile(readFileSync(wasmPath)), {
    wasi_snapshot_preview1: wasi.wasiImport,
    ...d1Imports(env, () => instance, new D1Sessions(env, undefined, config.sessions)),
    ...jwtImports(env, () => instance),
    edgeway_test: { reset },
  });
  return wasi.startAsync(instance);
}

async function main() {
  const [wasmPath, ...args] = process.argv.slice(2);
  requireJspi();
  const { getPlatformProxy } = await import("wrangler");
  const proxy = await getPlatformProxy({ configPath: join(config.appRoot, "wrangler.toml"), persist: false });
  try {
    process.exitCode = await runTests(wasmPath, args, proxy.env);
  } finally {
    await proxy.dispose();
  }
}

main().catch((error) => {
  console.error(`edgeway test: ${error instanceof WebAssembly.RuntimeError ? error.stack : error?.message ?? error}`);
  process.exitCode = 1;
});
