// Tests of varsOf in js/cloudflare.js with plain node:
// node test/js/cloudflare_test.mjs
// cloudflare.js needs config.js, which `edgeway build` writes, so js/ is copied
// to a temp dir with a stub.
import assert from "node:assert/strict";
import { cpSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const dir = mkdtempSync(join(tmpdir(), "edgeway-js-"));
cpSync(join(dirname(fileURLToPath(import.meta.url)), "../../js"), dir, { recursive: true });
writeFileSync(join(dir, "config.js"), 'export default { env: "test", d1Binding: "DB" };\n');
const { varsOf, corsOptions, logFieldsOf, platformEnvOf } = await import(pathToFileURL(join(dir, "cloudflare.js")));

let count = 0;
function test(name, fn) {
  fn();
  count++;
  console.log(`ok   js cloudflare ${name}`);
}

test("framework settings and APP_ variables pass", () => {
  const env = {
    JWT_ISSUER: "i", JWT_AUDIENCE: "a", JWT_LEEWAY: "5", JWT_ALGORITHMS: "HS256",
    JWT_JWKS_URL: "https://x.example/jwks", APP_FLAG: "on",
  };
  assert.deepEqual(varsOf(env), env);
});

test("other variables and secrets stay out", () => {
  const vars = varsOf({
    JWT_SECRET: "s", STRIPE_KEY: "k", CORS_ORIGINS: "*", app_lower: "x", MY_APP_X: "y", JWT_ISSUER: "i",
  });
  assert.deepEqual(vars, { JWT_ISSUER: "i" });
});

test("bindings (non-strings) stay out even under APP_", () => {
  assert.deepEqual(varsOf({ APP_DB: { prepare() {} }, APP_N: 1, APP_S: "s" }), { APP_S: "s" });
});

test("CORS always exposes Retry-After, and exposes and allows the bookmark header only with session bindings", () => {
  assert.deepEqual(corsOptions([]), { exposeHeaders: ["Retry-After"], allowHeaders: [] });
  assert.deepEqual(corsOptions(["DB"]), { exposeHeaders: ["Retry-After", "X-D1-Bookmark"], allowHeaders: ["X-D1-Bookmark"] });
});

test("LOG_LEVEL reaches the app", () => {
  assert.deepEqual(varsOf({ LOG_LEVEL: "debug" }), { LOG_LEVEL: "debug" });
});

test("the ray id is a log field when the request has one", () => {
  assert.deepEqual(logFieldsOf({ headers: new Headers({ "cf-ray": "abc-NRT" }) }), { ray: "abc-NRT" });
  assert.deepEqual(logFieldsOf({ headers: new Headers() }), {});
});

test("platformEnvOf names the server and takes the client address from CF-Connecting-IP", () => {
  const request = { headers: new Headers({ "cf-connecting-ip": "192.0.2.1" }) };
  assert.deepEqual(platformEnvOf(request), { SERVER_SOFTWARE: "Cloudflare-Workers", REMOTE_ADDR: "192.0.2.1" });
});

test("platformEnvOf always sets REMOTE_ADDR, and skips what request.cf lacks", () => {
  const cf = { country: "JP", colo: "NRT", asn: 2516, city: "", region: undefined, httpProtocol: "HTTP/2" };
  assert.deepEqual(platformEnvOf({ headers: new Headers(), cf }), {
    SERVER_SOFTWARE: "Cloudflare-Workers", REMOTE_ADDR: "", SERVER_PROTOCOL: "HTTP/2",
    CF_COUNTRY: "JP", CF_COLO: "NRT", CF_ASN: "2516",
  });
});

test("platformEnvOf leaves SERVER_PROTOCOL out when httpProtocol is empty or missing", () => {
  for (const cf of [{ httpProtocol: "" }, { country: "JP" }]) {
    assert.equal("SERVER_PROTOCOL" in platformEnvOf({ headers: new Headers(), cf }), false);
  }
});

test("platformEnvOf does not pass precise location", () => {
  const cf = { latitude: "35.6", longitude: "139.7", postalCode: "100" };
  const names = Object.keys(platformEnvOf({ headers: new Headers(), cf }));
  assert.deepEqual(names, ["SERVER_SOFTWARE", "REMOTE_ADDR"]);
});

rmSync(dir, { recursive: true, force: true });
console.log(`${count} js cloudflare tests passed`);
