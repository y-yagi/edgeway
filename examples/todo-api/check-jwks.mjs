// Helper of check-jwks.sh: a local JWKS server and the tokens to try. No
// dependencies; the keys are made with node's WebCrypto. Usage:
//   node check-jwks.mjs PORT ISSUER AUDIENCE
// Serves GET /jwks.json (every key below, public parts) and GET /tokens.json
// (a list of {name, alg, variant, token}). Prints "ready" when it listens.
import { createServer } from "node:http";
import { webcrypto as crypto } from "node:crypto";

const [port, iss, aud] = process.argv.slice(2);
if (!port || !iss || !aud) {
  console.error("usage: node check-jwks.mjs PORT ISSUER AUDIENCE");
  process.exit(2);
}

const ALGS = {
  RS256: { gen: { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, sign: { name: "RSASSA-PKCS1-v1_5" } },
  PS256: { gen: { name: "RSA-PSS", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, sign: { name: "RSA-PSS", saltLength: 32 } },
  ES256: { gen: { name: "ECDSA", namedCurve: "P-256" }, sign: { name: "ECDSA", hash: "SHA-256" } },
  EdDSA: { gen: { name: "Ed25519" }, sign: { name: "Ed25519" } },
};

// How the public JWK is published: with alg, without alg, with use and
// extra members (what IdPs do). EdDSA also gets "alg": "Ed25519", which some
// older tools write.
const VARIANTS = {
  alg: (jwk, alg) => ({ ...jwk, alg }),
  noalg: (jwk) => jwk,
  use: (jwk, alg) => ({ ...jwk, use: "sig", alg, key_ops: ["verify"], x5t: "abc", "x-extra": { a: 1 } }),
  ...{ ed25519: (jwk) => ({ ...jwk, alg: "Ed25519" }) },
  // key_ops without "verify": the key must not be used (a 401 for its own token).
  signonly: (jwk, alg) => ({ ...jwk, alg, key_ops: ["sign"] }),
};

const b64u = (b) => Buffer.from(b).toString("base64url");
const enc = new TextEncoder();
const now = Math.floor(Date.now() / 1000);
const claims = { sub: "user-1", iss, aud, exp: now + 3600 };

async function sign(alg, privateKey, kid, extra = {}) {
  const h = b64u(JSON.stringify({ alg, typ: "JWT", kid, ...extra }));
  const p = b64u(JSON.stringify(claims));
  const s = await crypto.subtle.sign(ALGS[alg].sign, privateKey, enc.encode(`${h}.${p}`));
  return `${h}.${p}.${b64u(s)}`;
}

const keys = [];
const tokens = [];
for (const alg of Object.keys(ALGS)) {
  const good = await crypto.subtle.generateKey(ALGS[alg].gen, true, ["sign", "verify"]);
  const other = await crypto.subtle.generateKey(ALGS[alg].gen, true, ["sign", "verify"]);
  const pub = await crypto.subtle.exportKey("jwk", good.publicKey);
  delete pub.key_ops; delete pub.ext; delete pub.alg;
  for (const [variant, f] of Object.entries(VARIANTS)) {
    if (variant === "ed25519" && alg !== "EdDSA") continue;
    const kid = `${alg}-${variant}`;
    keys.push({ ...f({ ...pub }, alg), kid });
    tokens.push({ name: `${alg} ${variant}`, alg, variant, expect: variant === "signonly" ? 401 : 200, token: await sign(alg, good.privateKey, kid) });
    if (variant === "alg") {
      // A valid signature, but no kid, or a crit header: both are refused.
      tokens.push({ name: `${alg} no kid`, alg, variant, expect: 401, token: await sign(alg, good.privateKey, undefined) });
      tokens.push({ name: `${alg} crit header`, alg, variant, expect: 401, token: await sign(alg, good.privateKey, kid, { crit: ["exp"] }) });
    }
    // The same kid, signed by another key.
    tokens.push({ name: `${alg} ${variant} other key`, alg, variant, expect: 401, token: await sign(alg, other.privateKey, kid) });
  }
}

createServer((req, res) => {
  const body = req.url === "/jwks.json" ? { keys } : req.url === "/tokens.json" ? tokens : null;
  res.writeHead(body ? 200 : 404, { "content-type": "application/json" });
  res.end(JSON.stringify(body ?? { error: "not found" }));
}).listen(Number(port), "127.0.0.1", () => console.log("ready"));
