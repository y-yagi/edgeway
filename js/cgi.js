// Turns a CGI program's stdout into a Response. The output is kept as bytes:
// "Name: value" header lines (LF or CRLF), a blank line, then the body,
// which goes out unchanged, so binary bodies (images, gzip...) survive.
// A "Status: 404 Not Found" line sets the status, and a Location line
// without one means 302; without a blank line the whole output is the body.
// A non-empty body without a Content-Type is sent as UTF-8 text, so binary
// output needs its own Content-Type line.
// Bad output never throws: an invalid status answers a fixed JSON 500, and a header line
// Headers refuses is skipped.

// Joins Uint8Array chunks into one.
export function concatBytes(chunks) {
  if (chunks.length === 1) return chunks[0];
  const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
  let pos = 0;
  for (const c of chunks) {
    out.set(c, pos);
    pos += c.length;
  }
  return out;
}

// Answers [end of the headers, start of the body], or null when there is no
// blank line. "\n\n", "\r\n\r\n" and a mix of the two all end the headers;
// a blank first line means no headers.
function headerEnd(out) {
  if (out[0] === 10) return [0, 1];
  if (out[0] === 13 && out[1] === 10) return [0, 2];
  for (let i = out.indexOf(10); i >= 0; i = out.indexOf(10, i + 1)) {
    if (out[i + 1] === 10) return [i, i + 2];
    if (out[i + 1] === 13 && out[i + 2] === 10) return [i, i + 3];
  }
  return null;
}

// Headers hold byte strings, so each byte becomes one char (not UTF-8, and
// not TextDecoder("latin1"), which is windows-1252): any bytes go out as is.
function byteString(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 8192) s += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return s;
}

// Statuses whose response must have no body.
const NULL_BODY = new Set([204, 205, 304]);
const TEXT = "text/plain; charset=utf-8";

export function cgiResponse(out) {
  const end = headerEnd(out);
  if (!end) return new Response(out, { headers: out.length ? { "Content-Type": TEXT } : {} });
  const headers = new Headers();
  let status = null;
  for (const line of byteString(out.subarray(0, end[0])).split(/\r?\n/)) {
    const i = line.indexOf(":");
    if (i < 0) continue;
    const name = line.slice(0, i).trim(), value = line.slice(i + 1).trim();
    if (name.toLowerCase() === "status") {
      // Only the first Status counts: a later one is a header injected into
      // the app's output.
      if (status === null) status = Number.parseInt(value, 10);
      continue;
    }
    try {
      headers.append(name, value);
    } catch {
      console.error(`cgi: skipped a bad header line: ${JSON.stringify(line)}`);
    }
  }
  status ??= headers.has("Location") ? 302 : 200;
  if (!(Number.isInteger(status) && status >= 200 && status <= 599)) {
    console.error(`cgi: bad status ${status}`);
    return new Response('{"error":"internal error"}\n', { status: 500, headers: { "Content-Type": "application/json" } });
  }
  if (NULL_BODY.has(status)) return new Response(null, { status, headers });
  const body = out.subarray(end[1]);
  if (body.length && !headers.has("Content-Type")) headers.set("Content-Type", TEXT);
  return new Response(body, { status, headers });
}

// ---- The request side: a Request as CGI meta-variables (RFC 3875) ----

// PATH_INFO is not URL-encoded in CGI, so %XX is decoded. Two escapes stay
// as they are: %2F (decoding it would make "a%2Fb" look like "a/b") and %00
// (a NUL cannot live in an environment string). A run of escapes that is not
// valid UTF-8 also stays encoded. Nothing here throws.
function decodePath(path) {
  return path.replace(/(?:%[0-9a-fA-F]{2})+/g, (run) =>
    run.split(/(%2f|%00)/i).map((piece, i) => {
      if (i % 2) return piece;
      try {
        return decodeURIComponent(piece);
      } catch {
        return piece;
      }
    }).join(""));
}

// The request.cf fields passed on, as non-standard CF_* variables.
const CF_FIELDS = {
  CF_COUNTRY: "country", CF_CONTINENT: "continent", CF_REGION: "region", CF_REGION_CODE: "regionCode",
  CF_CITY: "city", CF_TIMEZONE: "timezone", CF_COLO: "colo", CF_ASN: "asn",
};
// Precise location (latitude, longitude, postal code) is deliberately not passed;
// an app that needs it can read request.cf in the worker.

// The CGI environment for a request: an object of strings (no undefined or
// null; WASI env needs strings). `body` is the request body as a Uint8Array.
//  - REMOTE_ADDR comes from CF-Connecting-IP; it is "" when that is missing
//    (local wrangler dev may not send it), so the variable is always set.
//  - CONTENT_LENGTH is always set ("0" without a body); CONTENT_TYPE only
//    when the request has one.
//  - Header values go in as the JS strings workerd gives (a UTF-8 value from the
//    client arrives decoded; the WASI shim encodes env as UTF-8, so the app
//    sees the client's bytes). Content-Type and Content-Length are not HTTP_* (RFC 3875); every other
//    header is HTTP_<NAME> (upper case, "-" -> "_"; a name that already holds
//    "_" is dropped, as nginx and Apache do). Repeated headers come
//    joined with ", ". Cookie and Authorization are passed too: the app is
//    the one that handles the request.
//  - The Proxy header is not passed: HTTP_PROXY is read by HTTP clients as
//    proxy config (httpoxy, CVE-2016-5385).
//  - CF_* are not CGI; they come from request.cf, which is absent locally
//    in some setups, and absent fields are skipped.
export function cgiEnv(request, body) {
  const url = new URL(request.url);
  const https = url.protocol === "https:";
  const env = {
    GATEWAY_INTERFACE: "CGI/1.1",
    SERVER_SOFTWARE: "Cloudflare-Workers",
    SERVER_PROTOCOL: request.cf?.httpProtocol ? String(request.cf.httpProtocol) : "HTTP/1.1",
    SERVER_NAME: url.hostname,
    SERVER_PORT: url.port || (https ? "443" : "80"),
    REQUEST_SCHEME: https ? "https" : "http",
    REQUEST_METHOD: request.method,
    SCRIPT_NAME: "",
    PATH_INFO: decodePath(url.pathname),
    QUERY_STRING: url.search.slice(1),
    REQUEST_URI: url.pathname + url.search,
    REMOTE_ADDR: request.headers.get("cf-connecting-ip") ?? "",
    CONTENT_LENGTH: String(body.length),
  };
  if (https) env.HTTPS = "on";
  const type = request.headers.get("content-type");
  if (type != null) env.CONTENT_TYPE = type;
  request.headers.forEach((value, name) => {
    if (name === "content-type" || name === "content-length") return;
    if (name === "proxy") return; // httpoxy: HTTP_PROXY would be read as proxy config
    // "X_Foo" and "X-Foo" would both become HTTP_X_FOO, and a client could
    // pass off one as the other; like nginx and Apache, drop names with "_".
    if (name.includes("_")) return;
    env["HTTP_" + name.toUpperCase().replace(/-/g, "_")] = value;
  });
  for (const [key, field] of Object.entries(CF_FIELDS)) {
    const v = request.cf?.[field];
    if (v != null && v !== "") env[key] = String(v);
  }
  return env;
}
