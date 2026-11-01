const LOCAL_HOSTS = ["localhost", "127.0.0.1", "[::1]"];
export const DEFAULT_MAX_BYTES = 1024 * 1024;
const BASE64_CHUNK = 8192;

export function urlAllowed(url) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  if (parsed.protocol === "https:") return true;
  return parsed.protocol === "http:" && LOCAL_HOSTS.includes(parsed.hostname);
}

export function fetchWithTimeout(url, init, timeoutMs, fetch = globalThis.fetch) {
  return fetch(url, { ...init, redirect: "manual", signal: AbortSignal.timeout(timeoutMs) });
}

function checkDeclaredSize(response, maxBytes) {
  const declared = response.headers?.get("content-length");
  if (declared !== null && declared !== undefined && Number(declared) > maxBytes) throw new Error("response is too large");
}

function joinChunks(chunks, size) {
  const all = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    all.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return all;
}

// A chunked body has no Content-Length, so the size is counted again while reading.
export async function readCapped(response, maxBytes) {
  checkDeclaredSize(response, maxBytes);
  if (!response.body) return new Uint8Array(0);
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) {
      await reader.cancel().catch(() => {});
      throw new Error("response is too large");
    }
    chunks.push(value);
  }
  return joinChunks(chunks, size);
}

function base64Of(bytes) {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += BASE64_CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + BASE64_CHUNK));
  }
  return btoa(binary);
}

const INVALID_REQUEST = "request is not valid UTF-8";

export function parseRequest(bytes) {
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    return null;
  }
}

function failure(error) {
  if (error?.name === "TimeoutError") return { error: "request timed out", timeout: true };
  return { error: String(error?.message ?? error) };
}

export async function performRequest(spec, { fetch = globalThis.fetch, maxBytes = DEFAULT_MAX_BYTES } = {}) {
  if (!urlAllowed(spec.url)) return { error: "url must be https (http only for localhost)" };
  try {
    const init = { method: spec.method, headers: spec.headers };
    if (spec.body) init.body = spec.body;
    const response = await fetchWithTimeout(spec.url, init, spec.timeout_ms, fetch);
    const bytes = await readCapped(response, maxBytes);
    return { status: response.status, headers: Object.fromEntries(response.headers), body_base64: base64Of(bytes) };
  } catch (error) {
    return failure(error);
  }
}

// The wasm import module "edgeway_fetch" (lib/edgeway/service/fetch.rb):
//   request(json) -> {"status": n, "headers": {"lower-case-name": "value"}, "body_base64": "..."}
//                  | {"error": "message"}
//                  | {"error": "message", "timeout": true}
// json is {"method", "url", "headers", "body", "timeout_ms"}. A redirect is not
// followed: its response (with the location header) is the answer. A call answers the
// byte length of the result and take() copies it out; request is wrapped in
// WebAssembly.Suspending.
export function fetchImports(getInstance, { fetch = globalThis.fetch, maxBytes = DEFAULT_MAX_BYTES } = {}) {
  const memory = () => new Uint8Array(getInstance().exports.memory.buffer);
  const readCString = (pointer) => {
    const bytes = memory();
    let end = pointer;
    while (bytes[end]) end++;
    return bytes.subarray(pointer, end);
  };
  let pending = new Uint8Array(0);

  return {
    edgeway_fetch: {
      request: new WebAssembly.Suspending(async (specPointer) => {
        const spec = parseRequest(readCString(specPointer));
        const result = spec ? await performRequest(spec, { fetch, maxBytes }) : { error: INVALID_REQUEST };
        pending = new TextEncoder().encode(JSON.stringify(result));
        return pending.length;
      }),
      take(buffer) {
        memory().set(pending, buffer);
      },
    },
  };
}
