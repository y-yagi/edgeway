// Tests of js/jwt.js with plain node: node test/js/jwt_test.mjs
import assert from "node:assert/strict";
import { jwtVerifier } from "../../js/jwt.js";

const enc = new TextEncoder();
let count = 0;
async function test(name, fn) {
  await fn();
  count++;
  console.log(`ok   js jwt ${name}`);
}

const b64u = (bytes) => Buffer.from(bytes).toString("base64url");
const json = (o) => b64u(enc.encode(JSON.stringify(o)));

// A signed token: sign(signingInput) -> signature bytes.
async function token(header, payload, sign) {
  const input = `${json(header)}.${json(payload)}`;
  return `${input}.${b64u(await sign(enc.encode(input)))}`;
}

const PAYLOAD = { sub: "u1", exp: 4102444800 };
const fresh = () => new Map();   // a cache per test
const verifierFor = (env, opts = {}) => jwtVerifier(env, { cache: fresh(), ...opts });

// ---- HS256 ----
const secret = "s3cret-s3cret-s3cret-s3cret-s3cret";   // 35 bytes
const hmacKey = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
const hs256 = (header = {}, payload = PAYLOAD) =>
  token({ alg: "HS256", typ: "JWT", ...header }, payload, (d) => crypto.subtle.sign("HMAC", hmacKey, d).then((b) => new Uint8Array(b)));

await test("HS256: a valid token gives header and payload", async () => {
  const v = verifierFor({ JWT_ALGORITHMS: "HS256", JWT_SECRET: secret });
  const r = await v(await hs256());
  assert.equal(r.header.alg, "HS256");
  assert.deepEqual(r.payload, PAYLOAD);
});

await test("HS256: a wrong secret or a changed payload is rejected", async () => {
  const t = await hs256();
  assert.equal((await verifierFor({ JWT_ALGORITHMS: "HS256", JWT_SECRET: "other-other-other-other-other-other" })(t)).error, "signature is not valid");
  const [h, , s] = t.split(".");
  const forged = `${h}.${json({ sub: "admin" })}.${s}`;
  assert.equal((await verifierFor({ JWT_ALGORITHMS: "HS256", JWT_SECRET: secret })(forged)).error, "signature is not valid");
});

await test("HS256: no JWT_SECRET is unavailable, not a bad token", async () => {
  const r = await verifierFor({ JWT_ALGORITHMS: "HS256" })(await hs256());
  assert.equal(r.unavailable, true);
});

// ---- RS256 / PS256 / ES256 / EdDSA, with a JWKS ----
async function keyPair(alg, kid) {
  const spec = {
    RS256: { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    PS256: { name: "RSA-PSS", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    ES256: { name: "ECDSA", namedCurve: "P-256" },
    EdDSA: { name: "Ed25519" },
  }[alg];
  const pair = await crypto.subtle.generateKey(spec, true, ["sign", "verify"]);
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  jwk.kid = kid;
  const signAlg = { RS256: "RSASSA-PKCS1-v1_5", PS256: { name: "RSA-PSS", saltLength: 32 }, ES256: { name: "ECDSA", hash: "SHA-256" }, EdDSA: "Ed25519" }[alg];
  return {
    jwk,
    sign: (header, payload = PAYLOAD) =>
      token({ alg, typ: "JWT", kid, ...header }, payload, (d) => crypto.subtle.sign(signAlg, pair.privateKey, d).then((b) => new Uint8Array(b))),
  };
}

// A stub fetch that serves a JWKS and counts the calls.
function jwks(keys) {
  const f = async (url) => {
    f.calls.push(url);
    return new Response(JSON.stringify({ keys: f.keys }), { status: 200 });
  };
  f.calls = [];
  f.keys = keys;
  return f;
}
const URL_ = "https://idp.example/.well-known/jwks.json";

for (const alg of ["RS256", "PS256", "ES256", "EdDSA"]) {
  await test(`${alg}: valid, and rejected when signed by another key`, async () => {
    const k = await keyPair(alg, "k1");
    const other = await keyPair(alg, "k1");
    const v = verifierFor({ JWT_ALGORITHMS: alg, JWT_JWKS_URL: URL_ }, { fetch: jwks([k.jwk]) });
    assert.deepEqual((await v(await k.sign({}))).payload, PAYLOAD);
    assert.equal((await v(await other.sign({}))).error, "signature is not valid");
  });
}

await test("the default algorithm is RS256 only", async () => {
  const k = await keyPair("ES256", "k1");
  const r = await verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: jwks([k.jwk]) })(await k.sign({}));
  assert.equal(r.error, "algorithm is not allowed");
});

await test("alg none is rejected, even if listed", async () => {
  const t = `${json({ alg: "none", typ: "JWT" })}.${json(PAYLOAD)}.`;
  for (const algs of ["RS256", "none", "none,HS256"]) {
    const r = await verifierFor({ JWT_ALGORITHMS: algs, JWT_SECRET: secret, JWT_JWKS_URL: URL_ }, { fetch: jwks([]) })(t);
    assert.ok(r.error, algs);
  }
});

await test("alg confusion: an RS256 public key is not an HMAC secret", async () => {
  const k = await keyPair("RS256", "k1");
  // The attacker signs HS256 with the public key's text as the secret.
  const pub = JSON.stringify(k.jwk);
  const key = await crypto.subtle.importKey("raw", enc.encode(pub), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const t = await token({ alg: "HS256", kid: "k1" }, PAYLOAD, (d) => crypto.subtle.sign("HMAC", key, d).then((b) => new Uint8Array(b)));
  // Both allowed: HS256 is checked with JWT_SECRET only, never a JWKS key.
  const r = await verifierFor({ JWT_ALGORITHMS: "RS256,HS256", JWT_SECRET: secret, JWT_JWKS_URL: URL_ }, { fetch: jwks([k.jwk]) })(t);
  assert.equal(r.error, "signature is not valid");
  // HS256 not allowed.
  assert.equal((await verifierFor({ JWT_ALGORITHMS: "RS256", JWT_JWKS_URL: URL_ }, { fetch: jwks([k.jwk]) })(t)).error, "algorithm is not allowed");
});

await test("a JWKS key of another type or alg is not used", async () => {
  const rsa = await keyPair("RS256", "k1");
  const es = await keyPair("ES256", "k1");
  const f = jwks([es.jwk]);
  // RS256 token, but the key named k1 is an EC key.
  assert.equal((await verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: f })(await rsa.sign({}))).error, "unknown kid");
  const pinned = { ...rsa.jwk, alg: "PS256" };
  assert.equal((await verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: jwks([pinned]) })(await rsa.sign({}))).error, "unknown kid");
  const enc_ = { ...rsa.jwk, use: "enc" };
  assert.equal((await verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: jwks([enc_]) })(await rsa.sign({}))).error, "unknown kid");
});

await test("no kid is rejected with a JWKS, even if one key fits; HS256 needs none", async () => {
  const a = await keyPair("RS256", undefined);
  const t = await a.sign({ kid: undefined });
  const f = jwks([a.jwk]);
  assert.equal((await verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: f })(t)).error, "kid is required");
  assert.equal(f.calls.length, 0);
  const v = verifierFor({ JWT_ALGORITHMS: "HS256", JWT_SECRET: secret });
  assert.deepEqual((await v(await hs256())).payload, PAYLOAD);
});

await test("a crit header is rejected, whatever it lists", async () => {
  const k = await keyPair("RS256", "k1");
  const v = verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: jwks([k.jwk]) });
  for (const crit of [["exp"], [], ["b64"], null, "x"]) {
    const r = await v(await k.sign({ crit, b64: false }));
    assert.equal(r.error, "crit header is not supported", JSON.stringify(crit));
    assert.equal(r.unavailable, undefined);
  }
  const hs = verifierFor({ JWT_ALGORITHMS: "HS256", JWT_SECRET: secret });
  assert.equal((await hs(await hs256({ crit: ["exp"] }))).error, "crit header is not supported");
});

await test("key_ops, when present, must include verify", async () => {
  const k = await keyPair("RS256", "k1");
  const t = await k.sign({});
  for (const ops of [["verify"], ["sign", "verify"]]) {
    assert.deepEqual((await verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: jwks([{ ...k.jwk, key_ops: ops }]) })(t)).payload, PAYLOAD);
  }
  for (const ops of [["sign"], [], "verify"]) {
    assert.equal((await verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: jwks([{ ...k.jwk, key_ops: ops }]) })(t)).error, "unknown kid");
  }
});

await test("HMAC secrets are at least as long as the hash (RFC 7518 3.2)", async () => {
  for (const [alg, bytes] of [["HS256", 32], ["HS384", 48], ["HS512", 64]]) {
    const hash = `SHA-${alg.slice(2)}`;
    const sign = async (sec) => {
      const key = await crypto.subtle.importKey("raw", enc.encode(sec), { name: "HMAC", hash }, false, ["sign"]);
      return token({ alg }, PAYLOAD, (d) => crypto.subtle.sign("HMAC", key, d).then((b) => new Uint8Array(b)));
    };
    const ok = "x".repeat(bytes);
    assert.deepEqual((await verifierFor({ JWT_ALGORITHMS: alg, JWT_SECRET: ok })(await sign(ok))).payload, PAYLOAD, alg);
    const short = "x".repeat(bytes - 1);
    const r = await verifierFor({ JWT_ALGORITHMS: alg, JWT_SECRET: short })(await sign(short));
    assert.equal(r.unavailable, true, alg);
    assert.match(r.error, /too short/);
  }
  // The length is in UTF-8 bytes: 11 three-byte characters are 33 bytes, 10 are 30.
  const wide = "あ".repeat(11);
  const key = await crypto.subtle.importKey("raw", enc.encode(wide), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const t = await token({ alg: "HS256" }, PAYLOAD, (d) => crypto.subtle.sign("HMAC", key, d).then((b) => new Uint8Array(b)));
  assert.deepEqual((await verifierFor({ JWT_ALGORITHMS: "HS256", JWT_SECRET: wide })(t)).payload, PAYLOAD);
  assert.equal((await verifierFor({ JWT_ALGORITHMS: "HS256", JWT_SECRET: "あ".repeat(10) })(t)).unavailable, true);
});

await test("JWT_JWKS_URL must be https, except for localhost", async () => {
  const k = await keyPair("RS256", "k1");
  const t = await k.sign({});
  for (const url of ["http://idp.example/jwks.json", "ftp://idp.example/jwks.json", "idp.example/jwks.json", "http://localhost.evil.example/j", "http://127.0.0.1.evil.example/j"]) {
    const f = jwks([k.jwk]);
    const r = await verifierFor({ JWT_JWKS_URL: url }, { fetch: f })(t);
    assert.equal(r.unavailable, true, url);
    assert.equal(f.calls.length, 0, url);
  }
  for (const url of ["https://idp.example/jwks.json", "http://localhost:8788/jwks.json", "http://127.0.0.1:8788/jwks.json", "http://[::1]:8788/jwks.json"]) {
    assert.deepEqual((await verifierFor({ JWT_JWKS_URL: url }, { fetch: jwks([k.jwk]) })(t)).payload, PAYLOAD, url);
  }
});

await test("the JWKS fetch has a 5 second timeout, no redirects", async () => {
  const k = await keyPair("RS256", "k1");
  let seen;
  const hang = async (url, init) => {
    seen = init;
    return new Promise((_, reject) => init.signal.addEventListener("abort", () => reject(init.signal.reason)));
  };
  // A short timeout so the test does not wait; the real default is checked below.
  const keepAlive = setTimeout(() => {}, 5000);   // node does not keep the process for AbortSignal.timeout
  const r = await verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: hang, timeoutMs: 20 })(await k.sign({}));
  clearTimeout(keepAlive);
  assert.equal(r.unavailable, true);
  assert.equal(seen.redirect, "manual");
  assert.ok(seen.signal instanceof AbortSignal);
  const f = jwks([k.jwk]);
  const original = f;
  let init2;
  const spy = async (url, init) => { init2 = init; return original(url, init); };
  const realTimeout = AbortSignal.timeout;
  const asked = [];
  AbortSignal.timeout = (ms) => { asked.push(ms); return realTimeout.call(AbortSignal, ms); };
  try {
    await verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: spy })(await k.sign({}));
  } finally {
    AbortSignal.timeout = realTimeout;
  }
  assert.deepEqual(asked, [5000]);
  assert.equal(init2.redirect, "manual");
  assert.equal(init2.signal.aborted, false);
});

// A response with a body of this size, as one chunk or as a stream of chunks
// without a Content-Length.
const padded = (size) => JSON.stringify({ keys: [], pad: "x".repeat(size) });
const streamed = (text, headers = {}) => new Response(new ReadableStream({
  start(c) {
    const bytes = enc.encode(text);
    for (let i = 0; i < bytes.length; i += 4096) c.enqueue(bytes.slice(i, i + 4096));
    c.close();
  },
}), { status: 200, headers });

await test("a JWKS over 64 KB is refused, with or without Content-Length", async () => {
  const k = await keyPair("RS256", "k1");
  const t = await k.sign({});
  const v = (res) => verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: async () => res() })(t);
  const big = padded(70_000);
  // Content-Length says it.
  const withLength = await v(() => new Response(big, { status: 200, headers: { "content-length": String(big.length) } }));
  assert.equal(withLength.unavailable, true);
  assert.match(withLength.error, /too large/);
  // A lying Content-Length, and a chunked body without one: the stream is counted.
  const lying = await v(() => streamed(big, { "content-length": "10" }));
  assert.match(lying.error, /too large/);
  const chunked = await v(() => streamed(big));
  assert.match(chunked.error, /too large/);
  // Under the limit it is read (the key is then simply unknown).
  const fine = await v(() => streamed(padded(60_000)));
  assert.equal(fine.error, "unknown kid");
});

await test("a JWKS answer must be status 200 exactly; redirects are not followed", async () => {
  const k = await keyPair("RS256", "k1");
  const t = await k.sign({});
  const body = JSON.stringify({ keys: [k.jwk] });
  for (const status of [301, 302, 204, 206, 404, 500]) {
    const f = async () => new Response(status === 204 ? null : body, { status, headers: { location: "https://evil.example/jwks.json" } });
    const r = await verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: f })(t);
    assert.equal(r.unavailable, true, String(status));
  }
  // An opaque redirect (what fetch gives for redirect: "manual" in a browser) has status 0.
  const opaque = async () => ({ status: 0, type: "opaqueredirect", headers: new Headers(), body: null });
  assert.equal((await verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: opaque })(t)).unavailable, true);
});

await test("the JWKS is cached, and re-fetched on an unknown kid (rotation)", async () => {
  const old = await keyPair("RS256", "old");
  const next = await keyPair("RS256", "new");
  let t = 1_000_000;
  const f = jwks([old.jwk]);
  const v = verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: f, now: () => t });
  await v(await old.sign({}));
  await v(await old.sign({}));
  assert.equal(f.calls.length, 1);
  // The IdP rotates; the new key is found after one more fetch.
  f.keys = [old.jwk, next.jwk];
  t += 60_000;
  assert.deepEqual((await v(await next.sign({}))).payload, PAYLOAD);
  assert.equal(f.calls.length, 2);
  // Unknown kids don't make a fetch for each token: at most one in 30 seconds.
  const stranger = await keyPair("RS256", "stranger");
  t += 1000;
  assert.equal((await v(await stranger.sign({}))).error, "unknown kid");
  assert.equal(f.calls.length, 2);
  t += 31_000;
  assert.equal((await v(await stranger.sign({}))).error, "unknown kid");
  assert.equal(f.calls.length, 3);
  assert.equal((await v(await stranger.sign({}))).error, "unknown kid");
  assert.equal(f.calls.length, 3);
});

await test("the JWKS expires after its TTL, and an expired one is never used", async () => {
  const k = await keyPair("RS256", "k1");
  let t = 0;
  const f = jwks([k.jwk]);
  const cache = fresh();
  const env = { JWT_JWKS_URL: URL_ };
  const v = jwtVerifier(env, { fetch: f, now: () => t, cache });
  await v(await k.sign({}));
  t += 9 * 60_000;
  await v(await k.sign({}));
  assert.equal(f.calls.length, 1);   // within the TTL: the cache
  t += 2 * 60_000;
  await v(await k.sign({}));
  assert.equal(f.calls.length, 2);   // past it: fetched again
  t += 11 * 60_000;
  const down = async () => { throw new Error("down"); };
  const r = await jwtVerifier(env, { fetch: down, now: () => t, cache })(await k.sign({}));
  assert.equal(r.unavailable, true);
  assert.equal(r.payload, undefined);
});

await test("a failed refetch for an unknown kid is unavailable, a known kid in the TTL still works", async () => {
  const k = await keyPair("RS256", "k1");
  const stranger = await keyPair("RS256", "stranger");
  let t = 0;
  const f = jwks([k.jwk]);
  const cache = fresh();
  const env = { JWT_JWKS_URL: URL_ };
  await jwtVerifier(env, { fetch: f, now: () => t, cache })(await k.sign({}));
  t += 60_000;
  const down = async () => { throw new Error("down"); };
  const v = jwtVerifier(env, { fetch: down, now: () => t, cache });
  assert.equal((await v(await stranger.sign({}))).unavailable, true);
  assert.deepEqual((await v(await k.sign({}))).payload, PAYLOAD);
});

await test("a JWKS that can't be fetched is unavailable", async () => {
  const k = await keyPair("RS256", "k1");
  const down = async () => { throw new Error("down"); };
  const r = await verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: down })(await k.sign({}));
  assert.equal(r.unavailable, true);
  const bad = async () => new Response("", { status: 502 });
  assert.equal((await verifierFor({ JWT_JWKS_URL: URL_ }, { fetch: bad })(await k.sign({}))).unavailable, true);
  assert.equal((await verifierFor({}, { fetch: down })(await k.sign({}))).unavailable, true);
});

await test("malformed tokens are errors, not exceptions", async () => {
  const v = verifierFor({ JWT_ALGORITHMS: "HS256", JWT_SECRET: secret });
  const good = await hs256();
  const [h, p, s] = good.split(".");
  for (const bad of ["", "a.b", "a.b.c.d", `${h}.${p}`, "!!.!!.!!", `${json([1])}.${p}.${s}`, `${b64u(enc.encode("{bad"))}.${p}.${s}`,
                     `${h}.${p}.${s.slice(0, 10)}`, `${h}.${p}.`, "x".repeat(9000)]) {
    const r = await v(bad);
    assert.ok(r.error, JSON.stringify(bad.slice(0, 30)));
    assert.equal(r.unavailable, undefined);
  }
  // alg that is not a string, kid that is not a string
  assert.ok((await v(`${json({ alg: 1 })}.${p}.${s}`)).error);
  assert.equal((await v(await hs256({ kid: 5 }))).error, "kid is not a string");
});

await test("an RSA key without alg is imported per algorithm (RS256, then RS384 and RS512)", async () => {
  const gen = { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" };
  const pair = await crypto.subtle.generateKey(gen, true, ["sign", "verify"]);
  const jwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k1" };
  delete jwk.alg;
  const priv = await crypto.subtle.exportKey("jwk", pair.privateKey);
  delete priv.alg;
  const signer = async (alg, hash) => {
    const key = await crypto.subtle.importKey("jwk", priv, { name: gen.name, hash }, false, ["sign"]);
    return () => token({ alg, typ: "JWT", kid: "k1" }, PAYLOAD, (d) => crypto.subtle.sign(gen.name, key, d).then((b) => new Uint8Array(b)));
  };
  const sign = { RS256: await signer("RS256", "SHA-256"), RS384: await signer("RS384", "SHA-384"), RS512: await signer("RS512", "SHA-512") };
  // One verifier, so one cache: the key imported for RS256 must not serve RS384.
  const v = verifierFor({ JWT_ALGORITHMS: "RS256,RS384,RS512", JWT_JWKS_URL: URL_ }, { fetch: jwks([jwk]) });
  for (const alg of ["RS256", "RS384", "RS512", "RS384"]) {
    assert.deepEqual((await v(await sign[alg]())).payload, PAYLOAD, alg);
  }
});

await test("a base64url segment of length 1 mod 4 is an invalid token, not unavailable", async () => {
  const v = verifierFor({ JWT_ALGORITHMS: "HS256", JWT_SECRET: secret });
  const [h, p, s] = (await hs256()).split(".");
  for (const bad of [`${h}A.${p}.${s}`, `${h}.${p}A.${s}`, `${h}.${p}.${s}A`, `${h}.${p}.A`]) {
    const r = await v(bad);
    assert.ok(r.error, bad.slice(0, 30));
    assert.equal(r.unavailable, undefined);
  }
  assert.equal((await v(`${h}.${p}.A`)).error, "bad base64url");
});

await test("a payload that is not an object is rejected after the signature", async () => {
  const v = verifierFor({ JWT_ALGORITHMS: "HS256", JWT_SECRET: secret });
  const t = await token({ alg: "HS256" }, [1], (d) => crypto.subtle.sign("HMAC", hmacKey, d).then((b) => new Uint8Array(b)));
  assert.equal((await v(t)).error, "payload is not an object");
});

console.log(`${count} js jwt tests passed`);
