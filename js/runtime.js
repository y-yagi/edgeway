// Runs a Spinel-built app.wasm once per request, CGI style: the request
// becomes CGI environment variables and STDIN, the program's stdout becomes
// the Response. Nothing here is specific to a platform; cloudflare.js
// supplies the imports a platform adds (D1, ...) and the environment.
import { WASI } from "./wasi-shim.js";
import { cgiEnv, cgiResponse, concatBytes } from "./cgi.js";

// SPINEL_GC_SLAB_MB: the size of the GC slab, read from the WASI env at start.
// The default 64 MB makes an instance 77 MiB; with 8 MB it is ~21 MiB, so
// more requests fit in the 128 MB of an isolate.
const SLAB_MB = "8";

// The largest request body accepted. The body is copied into the instance's
// STDIN (and the CGI env), so an unbounded one would exhaust the isolate.
const MAX_BODY = 1024 * 1024;

function payloadTooLarge() {
  return new Response('{"error":"payload too large"}\n', {
    status: 413,
    headers: { "Content-Type": "application/json" },
  });
}

// The request's body as bytes, or null when it is over MAX_BODY. Content-Length
// is checked first, but a client can lie or send chunked, so the stream is
// read with a cap as well.
async function readBody(request) {
  const declared = request.headers.get("content-length");
  if (declared !== null && Number(declared) > MAX_BODY) return null;
  if (!request.body) return new Uint8Array(0);
  const chunks = [];
  let total = 0;
  const reader = request.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  return concatBytes(chunks);
}

function internalError() {
  return new Response('{"error":"internal error"}\n', {
    status: 500,
    headers: { "Content-Type": "application/json" },
  });
}

// Runs appModule (a WebAssembly.Module) for one request and answers the
// Response.
//   extraEnv: more CGI environment variables (strings), such as the app's
//             settings and EDGEWAY_ENV.
//   imports:  (getInstance) => { moduleName: { name: fn } }, the wasm import
//             modules besides WASI. A function wrapped in
//             WebAssembly.Suspending may await (JSPI).
export async function runCgi(appModule, request, { extraEnv = {}, imports = () => ({}) } = {}) {
  const body = request.method === "GET" || request.method === "HEAD"
    ? new Uint8Array(0)
    : await readBody(request);
  if (body === null) return payloadTooLarge();

  const out = [];
  let err = "";
  const wasi = new WASI({
    args: ["app"],
    env: { ...extraEnv, ...cgiEnv(request, body), SPINEL_GC_SLAB_MB: SLAB_MB },
    stdin: body,
    onStdoutBytes: (b) => out.push(b),
    onStderr: (s) => (err += s),
  });
  // Whatever goes wrong inside the app (a trap, a non-zero exit) is logged
  // and answered with a fixed body: stderr and error messages never reach
  // the client.
  let status;
  try {
    // A fresh instance per request: no state leaks between requests.
    let instance;
    instance = new WebAssembly.Instance(appModule, {
      wasi_snapshot_preview1: wasi.wasiImport,
      ...imports(() => instance),
    });
    status = await wasi.startAsync(instance);
  } catch (e) {
    console.error("app trapped:", e, err);
    return internalError();
  }
  if (err) console.error(err);
  if (status !== 0) {
    console.error(`app exited with ${status}`);
    return internalError();
  }

  return cgiResponse(concatBytes(out));
}
