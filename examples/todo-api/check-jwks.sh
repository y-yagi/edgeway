#!/bin/sh
# Checks the asymmetric JWT algorithms (RS256 as the baseline, PS256, ES256,
# EdDSA) against a JWKS under workerd, so it can be re-run after a workerd or
# wrangler upgrade. check.sh only covers HS256; test/js/jwt_test.mjs covers
# these algorithms with node's WebCrypto, which is not workerd's.
#
#   ./check-jwks.sh [port] (default 8788, so it can run next to `wrangler dev`
#   on 8787; the JWKS is served on port+1, the inspector on port+2)
#
# It starts check-jwks.mjs (keys, JWKS, tokens) and its own `wrangler dev`
# with JWT_ALGORITHMS and JWT_JWKS_URL overridden by --var; .dev.vars and
# wrangler.toml are not changed. Needs build/app.wasm (see
# docs/jwt-progress.md, "How to resume"), node, curl and jq. Each line is "ok"
# or "NG"; the exit status is the number of NG lines. An EdDSA key that
# importKey rejects shows as "unavailable" (500), not as a bad token (401).
cd "$(dirname "$0")" || exit 1
P=${1:-8788}
J=$((P + 1))
U=http://127.0.0.1:$P
fails=0
tmp=$(mktemp -d)
pids=""
cleanup() {
  # wrangler runs in its own process group (setsid) with its workerd child.
  for p in $pids; do kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

[ -f build/app.wasm ] || { echo "NG  build/app.wasm is missing: build first (docs/jwt-progress.md, How to resume)"; exit 1; }

# The issuer and audience the app expects.
iss=$(sed -n 's/^JWT_ISSUER *= *"\(.*\)"/\1/p' wrangler.toml | head -n 1)
aud=$(sed -n 's/^JWT_AUDIENCE *= *"\(.*\)"/\1/p' wrangler.toml | head -n 1)

setsid node check-jwks.mjs "$J" "$iss" "$aud" >"$tmp/helper.log" 2>&1 &
pids="$pids $!"
setsid npx wrangler dev --port "$P" --inspector-port $((P + 2)) \
  --var JWT_ALGORITHMS:RS256,PS256,ES256,EdDSA \
  --var "JWT_JWKS_URL:http://127.0.0.1:$J/jwks.json" >"$tmp/wrangler.log" 2>&1 &
pids="$pids $!"

i=0
until curl -s -o /dev/null "$U/health" && curl -s -o "$tmp/tokens.json" "http://127.0.0.1:$J/tokens.json"; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "NG  wrangler dev or the helper did not start"
    cat "$tmp/helper.log" "$tmp/wrangler.log"
    exit 1
  fi
  sleep 1
done

n=$(jq length "$tmp/tokens.json")
k=0
while [ "$k" -lt "$n" ]; do
  name=$(jq -r ".[$k].name" "$tmp/tokens.json")
  alg=$(jq -r ".[$k].alg" "$tmp/tokens.json")
  want=$(jq -r ".[$k].expect" "$tmp/tokens.json")
  token=$(jq -r ".[$k].token" "$tmp/tokens.json")
  k=$((k + 1))
  got=$(curl -s -o "$tmp/body" -w '%{http_code}' -H "Authorization: Bearer $token" "$U/me")
  if [ "$got" = "$want" ] && { [ "$want" != 200 ] || jq -e '.sub == "user-1" and .aud == "todo-api"' "$tmp/body" >/dev/null 2>&1; }; then
    echo "ok  $got $name"
  elif [ "$got" = 500 ]; then
    # importKey (or the JWKS fetch) failed on the server: not a verdict on the token.
    echo "NG  500 (want $want) $name: unavailable, workerd could not import or fetch the key for $alg: $(head -c 200 "$tmp/body")"
    fails=$((fails + 1))
  else
    echo "NG  $got (want $want) $name: $(head -c 200 "$tmp/body")"
    fails=$((fails + 1))
  fi
done

if [ "$fails" -gt 0 ]; then
  echo "--- wrangler log (errors) ---"
  grep -i -E 'error|unavailable|importKey|not supported' "$tmp/wrangler.log" | sort | uniq -c | head -n 10
fi
echo "$fails NG"
exit "$fails"
