// JWT signature verification with WebCrypto, for tokens an external IdP
// issued (Auth0, Firebase, Cognito, ...; Cloudflare Access is not supported yet). Nothing here is
// specific to a platform: cloudflare.js hands jwtImports the Worker's env.
// This checks the signature and the algorithm only; the claims (exp, iss,
// aud, ...) are checked in Ruby (lib/edgeway/http/auth/jwt.rb).
//
// Settings (strings in the env):
//   JWT_ALGORITHMS  comma-separated allow-list, default "RS256". The token's
//                   alg must be in it, whatever the token says ("none" never is)
//   JWT_JWKS_URL    where the public keys are, for RS*/PS*/ES*/EdDSA; https,
//                   except http://localhost, 127.0.0.1 and [::1]
//   JWT_SECRET      the shared secret, for HS*; at least as long as the hash
//                   (RFC 7518 3.2): 32 bytes for HS256, 48 for HS384, 64 for HS512
// A key never serves the other family: an HS* token is checked only with
// JWT_SECRET, and any other only with a key of the JWKS (so a public key
// can't be passed off as an HMAC secret).
//
// Hardened as jose does (and a little more): a JWKS is never used past its TTL
// (no stale fallback), is fetched with a timeout, no redirect, only on status
// 200 and at most MAX_JWKS bytes; a token with a `crit` header is refused
// (RFC 7515 4.1.11: no extension is understood), and a JWKS key needs a `kid`
// on the token and, if it has key_ops, "verify" in them.

const MAX_TOKEN = 8192;
// A JWKS is kept this long, and re-fetched early (for an unknown kid) at
// most this often.
const JWKS_TTL_MS = 10 * 60 * 1000;
const JWKS_MIN_REFETCH_MS = 30 * 1000;
const JWKS_TIMEOUT_MS = 5000;
const MAX_JWKS = 64 * 1024;

// alg => how WebCrypto imports the key and verifies. The hash size is
// the RSA-PSS salt length.
const HASHES = { 256: "SHA-256", 384: "SHA-384", 512: "SHA-512" };
function algorithm(alg) {
  const m = /^(HS|RS|PS|ES)(256|384|512)$/.exec(alg);
  if (m) {
    const [, family, bits] = m;
    const hash = HASHES[bits];
    switch (family) {
      case "HS": return { family: "HS", import: { name: "HMAC", hash }, verify: { name: "HMAC" } };
      case "RS": return { family: "RS", kty: "RSA", import: { name: "RSASSA-PKCS1-v1_5", hash }, verify: { name: "RSASSA-PKCS1-v1_5" } };
      case "PS": return {
        family: "PS", kty: "RSA", import: { name: "RSA-PSS", hash },
        verify: { name: "RSA-PSS", saltLength: Number(bits) / 8 },
      };
      case "ES": {
        const crv = { 256: "P-256", 384: "P-384" }[bits];   // ES512 (P-521) is left out
        if (!crv) return null;
        return { family: "ES", kty: "EC", crv, import: { name: "ECDSA", namedCurve: crv }, verify: { name: "ECDSA", hash } };
      }
    }
  }
  if (alg === "EdDSA") return { family: "EdDSA", kty: "OKP", crv: "Ed25519", import: { name: "Ed25519" }, verify: { name: "Ed25519" } };
  return null;
}

// "invalid": the token is bad (401). "unavailable": it could not be checked
// (a missing setting, the JWKS can't be fetched), which is the server's
// problem (500).
class JwtError extends Error {
  constructor(message, unavailable = false) {
    super(message);
    this.unavailable = unavailable;
  }
}

function b64urlDecode(s) {
  // A length of 1 mod 4 is never valid base64 (and makes atob throw a plain
  // Error, which would be reported as "unavailable" instead of a bad token).
  if (!/^[A-Za-z0-9_-]*$/.test(s) || s.length % 4 === 1) throw new JwtError("bad base64url");
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

function parseJsonPart(s, what) {
  let v;
  try {
    v = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(b64urlDecode(s)));
  } catch {
    throw new JwtError(`${what} is not valid`);
  }
  if (v === null || typeof v !== "object" || Array.isArray(v)) throw new JwtError(`${what} is not an object`);
  return v;
}

// JWKS cache: url => { keys, at, imported: Map }. It lives at module scope:
// a wasm instance is made per request, but the isolate (and so this module)
// is reused. Only data is kept, never a Promise, because a Worker can't
// await I/O that another request started.
const sharedCache = new Map();

// Only https, so a JWKS can't be swapped on the way; a local server (tests,
// `wrangler dev`) may use http.
function jwksUrlAllowed(url) {
  let u;
  try {
    u = new URL(url);
  } catch {
    return false;
  }
  if (u.protocol === "https:") return true;
  return u.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(u.hostname);
}

// The body of res as text, at most MAX_JWKS bytes (checked on Content-Length
// when there is one, and again while reading, because a chunked body has none).
async function limitedText(res) {
  const declared = res.headers?.get("content-length");
  if (declared !== null && declared !== undefined && Number(declared) > MAX_JWKS) throw new Error("response is too large");
  if (!res.body) throw new Error("no body");
  const reader = res.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_JWKS) {
      await reader.cancel().catch(() => {});
      throw new Error("response is too large");
    }
    chunks.push(value);
  }
  const all = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    all.set(c, at);
    at += c.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(all);
}

export function jwtVerifier(env, { fetch = globalThis.fetch, now = Date.now, cache = sharedCache, timeoutMs = JWKS_TIMEOUT_MS } = {}) {
  const allowed = String(env.JWT_ALGORITHMS || "RS256").split(",").map((s) => s.trim()).filter(Boolean);

  async function loadKeys(url, force) {
    const entry = cache.get(url);
    const t = now();
    if (entry && (force ? t - entry.at < JWKS_MIN_REFETCH_MS : t - entry.at < JWKS_TTL_MS)) return entry;
    // No stale JWKS: past its TTL (or when a forced refetch fails) a failed
    // fetch is "unavailable", never an old key.
    try {
      const res = await fetch(url, { redirect: "manual", signal: AbortSignal.timeout(timeoutMs) });
      if (res.status !== 200) throw new Error(`status ${res.status}`);
      const keys = JSON.parse(await limitedText(res)).keys;
      if (!Array.isArray(keys)) throw new Error("no keys");
      const fresh = { keys, at: t, imported: new Map() };
      cache.set(url, fresh);
      return fresh;
    } catch (e) {
      throw new JwtError(`cannot fetch the JWKS: ${e?.message ?? e}`, true);
    }
  }

  // A key of the JWKS that can verify alg, selected by kid.
  function pick(entry, alg, algo, kid) {
    const fits = (k) => k && k.kty === algo.kty && (k.use === undefined || k.use === "sig")
      && (k.key_ops === undefined || (Array.isArray(k.key_ops) && k.key_ops.includes("verify")))
      && (k.alg === undefined || k.alg === alg || (alg === "EdDSA" && k.alg === "Ed25519")) && (algo.crv === undefined || k.crv === algo.crv);
    return entry.keys.find((k) => k.kid === kid && fits(k));
  }

  async function importJwk(entry, jwk, algo) {
    // imported: jwk => Map(alg name => CryptoKey). A JWK without `alg` can be
    // used for several (RS256, RS384...), and each needs its own hash.
    let keys = entry.imported.get(jwk);
    if (!keys) entry.imported.set(jwk, (keys = new Map()));
    const id = algo.import.name + (algo.import.hash ?? algo.import.namedCurve ?? "");
    let key = keys.get(id);
    if (!key) {
      // pick() accepted "Ed25519" as the alg of an EdDSA key, but workerd's
      // importKey refuses a JWK whose alg is not "EdDSA" (node accepts it).
      const usable = jwk.alg === "Ed25519" ? { ...jwk, alg: "EdDSA" } : jwk;
      key = await crypto.subtle.importKey("jwk", usable, algo.import, false, ["verify"]);
      keys.set(id, key);
    }
    return key;
  }

  async function keyFor(alg, algo, kid) {
    if (algo.family === "HS") {
      if (!env.JWT_SECRET) throw new JwtError("JWT_SECRET is not set", true);
      const secret = new TextEncoder().encode(env.JWT_SECRET);
      // RFC 7518 3.2: a key at least as long as the hash output.
      const need = Number(alg.slice(2)) / 8;
      if (secret.length < need) throw new JwtError(`JWT_SECRET is too short for ${alg} (${need} bytes at least)`, true);
      return crypto.subtle.importKey("raw", secret, algo.import, false, ["verify"]);
    }
    const url = env.JWT_JWKS_URL;
    if (!url) throw new JwtError("JWT_JWKS_URL is not set", true);
    if (!jwksUrlAllowed(url)) throw new JwtError("JWT_JWKS_URL must be https (http only for localhost)", true);
    if (kid === undefined) throw new JwtError("kid is required");
    let entry = await loadKeys(url, false);
    let jwk = pick(entry, alg, algo, kid);
    if (!jwk) {
      // A key rotated in: look again, but not for every bad token.
      entry = await loadKeys(url, true);
      jwk = pick(entry, alg, algo, kid);
    }
    if (!jwk) throw new JwtError("unknown kid");
    return importJwk(entry, jwk, algo);
  }

  // => { header, payload }; throws JwtError.
  async function verify(token) {
    if (token.length > MAX_TOKEN) throw new JwtError("token is too long");
    const parts = token.split(".");
    if (parts.length !== 3) throw new JwtError("token is not a JWT");
    const header = parseJsonPart(parts[0], "header");
    // Edgeway understands no extension, so a token that insists on one
    // ("crit", RFC 7515 4.1.11) is refused.
    if ("crit" in header) throw new JwtError("crit header is not supported");
    const alg = header.alg;
    if (typeof alg !== "string" || !allowed.includes(alg)) throw new JwtError("algorithm is not allowed");
    const algo = algorithm(alg);
    if (!algo) throw new JwtError("algorithm is not supported");
    if (header.kid !== undefined && typeof header.kid !== "string") throw new JwtError("kid is not a string");
    // Decoded before keyFor, so a malformed token costs no JWKS fetch.
    const signature = b64urlDecode(parts[2]);
    const key = await keyFor(alg, algo, header.kid);
    const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
    let ok = false;
    try {
      ok = await crypto.subtle.verify(algo.verify, key, signature, signed);
    } catch {
      // A malformed signature (the wrong length...) is just not valid.
    }
    if (!ok) throw new JwtError("signature is not valid");
    return { header, payload: parseJsonPart(parts[1], "payload") };
  }

  // The JSON the wasm side reads.
  return async (token) => {
    try {
      return await verify(token);
    } catch (e) {
      if (!(e instanceof JwtError)) throw e;
      return e.unavailable ? { error: e.message, unavailable: true } : { error: e.message };
    }
  };
}

// The wasm import module "edgeway_jwt" (lib/edgeway/service/cloudflare/jwt.rb):
//   verify(token) -> {"header": {...}, "payload": {...}}
//                  | {"error": "message"}                      the token is bad
//                  | {"error": "message", "unavailable": true}  it can't be checked
// Like the other imports, a call answers the byte length of the result and take() copies it
// out; verify is wrapped in WebAssembly.Suspending (the WebCrypto and fetch
// Promises are awaited with the wasm stack suspended).
export function jwtImports(env, getInstance, options = {}) {
  const mem = () => new Uint8Array(getInstance().exports.memory.buffer);
  const cstr = (p) => {
    const b = mem();
    let e = p;
    while (b[e]) e++;
    return new TextDecoder().decode(b.subarray(p, e));
  };
  const verifier = jwtVerifier(env, options);
  let pending = new Uint8Array(0);

  return {
    edgeway_jwt: {
      verify: new WebAssembly.Suspending(async (tokenPtr) => {
        let res;
        try {
          res = await verifier(cstr(tokenPtr));
        } catch (e) {
          res = { error: String(e?.message ?? e), unavailable: true };
        }
        pending = new TextEncoder().encode(JSON.stringify(res));
        return pending.length;
      }),
      take(buf) {
        mem().set(pending, buf);
      },
    },
  };
}
