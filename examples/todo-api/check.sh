#!/bin/sh
# Checks a running todo-api: ./check.sh [base URL] (default: wrangler dev's).
# Each line is "ok" or "NG" with the request and the status; the exit status
# is the number of NG lines. Needs curl and jq. It creates and deletes its
# own todos, so it can run against a table that already has rows.
U=${1:-http://localhost:8787}
J='Content-Type: application/json'
fails=0
body=$(mktemp)
trap 'rm -f "$body"' EXIT

# The JWT secret of the running app: $JWT_SECRET, or .dev.vars (what wrangler
# dev uses). The tokens below are made here with openssl.
secret=${JWT_SECRET:-$(sed -n 's/^JWT_SECRET=//p' "$(dirname "$0")/.dev.vars" 2>/dev/null)}

# req EXPECTED_STATUS [curl args...]: the body is left in $body.
req() {
  want=$1
  shift
  got=$(curl -s -o "$body" -w '%{http_code}' "$@")
  if [ "$got" = "$want" ]; then
    echo "ok  $got $*"
  else
    echo "NG  $got (want $want) $*: $(head -c 200 "$body")"
    fails=$((fails + 1))
  fi
}

# expect DESCRIPTION JQ_FILTER: checks $body with jq -e.
expect() {
  if jq -e "$2" "$body" >/dev/null 2>&1; then
    echo "ok  $1"
  else
    echo "NG  $1: $(head -c 200 "$body")"
    fails=$((fails + 1))
  fi
}

req 200 "$U/health"
expect "health is ok" '.status == "ok"'

req 201 -X POST -H "$J" -d '{"todo":{"title":"check a"}}' "$U/todos"
expect "a new todo is not done" '.title == "check a" and .done == false'
expect "a new todo has the default priority" '.priority == "normal"'
expect "created_at is an ISO 8601 time" '.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")'
expect "updated_at starts as created_at" '.updated_at == .created_at'
a=$(jq -r .id "$body")
created=$(jq -r .created_at "$body")
req 201 -X POST -H "$J" -d '{"todo":{"title":"check b","done":true}}' "$U/todos"
expect "done: true is kept" '.done == true'
b=$(jq -r .id "$body")

req 422 -X POST -H "$J" -d '{"todo":{"title":"  "}}' "$U/todos"
expect "a blank title is an error" '.errors == ["title can'"'"'t be blank"]'
long=$(printf '%201s' '' | tr ' ' x)
req 422 -X POST -H "$J" -d "{\"todo\":{\"title\":\"$long\"}}" "$U/todos"
expect "a 201-character title is an error" '.errors == ["title is too long (maximum is 200 characters)"]'
req 422 -X POST -H "$J" -d '{"todo":{"title":"p","priority":"urgent"}}' "$U/todos"
expect "an unknown priority is an error" '.errors == ["priority is not included in the list"]'
req 400 -X POST -H "$J" -d '{bad' "$U/todos"

req 200 "$U/todos"
expect "the list has both" "[.[].id] | contains([$a, $b])"
req 200 "$U/todos/$a"
expect "show answers the todo" ".id == $a"
sleep 1   # for updated_at to move on
req 200 -X PATCH -H "$J" -d '{"todo":{"done":true,"priority":"high","id":999999}}' "$U/todos/$a"
expect "update sets done and keeps the id" ".id == $a and .done == true and .priority == \"high\""
expect "update moves updated_at only" ".created_at == \"$created\" and .updated_at > .created_at"
req 422 -X PATCH -H "$J" -d '{"todo":{"title":""}}' "$U/todos/$a"
req 200 "$U/todos?done=true"
expect "?done=true has only done todos" 'all(.[]; .done == true)'
req 200 "$U/todos?done=false"
expect "?done=false has only open todos" 'all(.[]; .done == false)'
total=$(curl -s -o /dev/null -D - "$U/todos?done=false" | tr -d '\r' | awk -F': ' 'tolower($1) == "x-total-count" { print $2 }')
expect "X-Total-Count counts them ($total)" "length as \$n | ${total:-null} as \$t | (\$t | type) == \"number\" and (if \$n < 50 then \$t == \$n else \$t >= \$n end)"
req 200 "$U/todos?order=id&dir=desc"
expect "?dir=desc orders by id, descending" '[.[].id] == ([.[].id] | sort | reverse)'

# Injection: the title is stored as text; a bad order is refused.
req 201 -X POST -H "$J" -d "{\"todo\":{\"title\":\"x'); DROP TABLE todos; --\"}}" "$U/todos"
expect "an SQL-looking title is just text" ".title == \"x'); DROP TABLE todos; --\""
c=$(jq -r .id "$body")
req 400 "$U/todos?order=title;DROP%20TABLE%20todos"
req 400 "$U/todos?order=title&dir=sideways"
req 200 "$U/todos/$c"

# Comments: has_many and belongs_to.
req 201 -X POST -H "$J" -d '{"comment":{"body":"first","todo_id":999999}}' "$U/todos/$a/comments"
expect "a comment belongs to the todo in the path" ".todo_id == $a and .body == \"first\" and (.created_at | type) == \"string\""
m=$(jq -r .id "$body")
req 201 -X POST -H "$J" -d '{"body":"second"}' "$U/todos/$a/comments"
req 422 -X POST -H "$J" -d '{"comment":{"body":""}}' "$U/todos/$a/comments"
expect "a blank comment is an error" '.errors == ["body can'"'"'t be blank"]'
req 404 -X POST -H "$J" -d '{"comment":{"body":"x"}}' "$U/todos/999999/comments"
req 200 "$U/todos/$a/comments"
expect "the todo has its two comments" "length == 2 and all(.[]; .todo_id == $a)"
req 200 "$U/todos/$b/comments"
expect "another todo has none" 'length == 0'
req 404 -X DELETE "$U/todos/$b/comments/$m"
req 204 -X DELETE "$U/todos/$a/comments/$m"
req 200 "$U/todos/$a/comments"
expect "one comment is left" 'length == 1'

# dependent: :destroy: deleting a todo destroys its comments first (a SELECT and
# a DELETE per comment, then the todo), and answers 204 as before.
req 201 -X POST -H "$J" -d '{"todo":{"title":"with comments"}}' "$U/todos"
d=$(jq -r .id "$body")
req 201 -X POST -H "$J" -d '{"body":"one"}' "$U/todos/$d/comments"
req 201 -X POST -H "$J" -d '{"body":"two"}' "$U/todos/$d/comments"
req 204 -X DELETE "$U/todos/$d"
req 404 "$U/todos/$d"
req 404 "$U/todos/$d/comments"

# Tags: UNIQUE (name) in the table. A second create is refused by D1 itself
# (409, a fixed body: the table and column stay in the log); find_or_create is
# find_or_create_by!, so it answers the same tag again.
req 201 -X POST -H "$J" -d '{"tag":{"name":"check-tag"}}' "$U/tags"
t=$(jq -r .id "$body")
req 409 -X POST -H "$J" -d '{"tag":{"name":"check-tag"}}' "$U/tags"
expect "a duplicate is a 409 with a fixed body" '. == {"error": "record not unique"}'
req 200 -X PUT -H "$J" -d '{"tag":{"name":"check-tag"}}' "$U/tags/find_or_create"
expect "find_or_create finds the existing tag" ".id == $t"
req 200 -X PUT -H "$J" -d '{"tag":{"name":"check-tag-2"}}' "$U/tags/find_or_create"
t2=$(jq -r .id "$body")
expect "find_or_create makes a new one" ".name == \"check-tag-2\" and .id != $t"
req 200 -X PUT -H "$J" -d '{"tag":{"name":"check-tag-2"}}' "$U/tags/find_or_create"
expect "find_or_create again finds it" ".id == $t2"

# Model.batch is one D1 batch(): both renames apply, or neither. Giving both
# tags the same name fails the second UPDATE (409), and the first, which ran
# before it in the batch, is rolled back.
req 200 -X PATCH -H "$J" -d "{\"rename\":{\"first_id\":$t,\"first_name\":\"check-tag-a\",\"second_id\":$t2,\"second_name\":\"check-tag-b\"}}" "$U/tags/rename_pair"
expect "a batch of two renames answers both" '.[0].name == "check-tag-a" and .[1].name == "check-tag-b"'
req 200 "$U/tags/$t"
expect "the first rename was applied" '.name == "check-tag-a"'
req 409 -X PATCH -H "$J" -d "{\"rename\":{\"first_id\":$t,\"first_name\":\"check-tag-c\",\"second_id\":$t2,\"second_name\":\"check-tag-c\"}}" "$U/tags/rename_pair"
req 200 "$U/tags/$t"
expect "a failed batch rolled back the first rename" '.name == "check-tag-a"'
req 200 "$U/tags/$t2"
expect "and the second tag is unchanged" '.name == "check-tag-b"'
for id in $t $t2; do req 204 -X DELETE "$U/tags/$id"; done

req 404 "$U/todos/abc"
req 404 "$U/nope"
req 404 -X DELETE "$U/health"
req 500 "$U/boom"
expect "a 500 has no details" '. == {"error": "internal error"}'
req 404 "$U/todos/4294967297"
req 400 "$U/todos?order=%ff"
req 200 -I "$U/health"
req 200 -H 'X_Foo: 1' "$U/health"

for id in $a $b $c; do req 204 -X DELETE "$U/todos/$id"; done
req 404 "$U/todos/$a"

# JWT authentication: GET /me needs a Bearer token (HS256, the secret in
# .dev.vars; iss and aud as wrangler.toml says).
b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
# jwt PAYLOAD_JSON [SECRET] [HEADER_JSON]: a signed HS256 token.
jwt() {
  hdr=${3:-'{"alg":"HS256","typ":"JWT"}'}
  h=$(printf '%s' "$hdr" | b64u)
  p=$(printf '%s' "$1" | b64u)
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -binary -sha256 -hmac "${2:-$secret}" | b64u)
  printf '%s.%s.%s' "$h" "$p" "$s"
}
now=$(date +%s)
iss='https://idp.example/'
good=$(jwt "{\"sub\":\"user-1\",\"iss\":\"$iss\",\"aud\":\"todo-api\",\"exp\":$((now + 600))}")
bearer() { echo "Authorization: Bearer $1"; }
# challenge [curl args...]: the WWW-Authenticate header of a /me request.
challenge() { curl -s -o /dev/null -D - "$@" "$U/me" | tr -d '\r' | awk -F': ' 'tolower($1) == "www-authenticate" { print $2 }'; }
# invalid TOKEN DESCRIPTION: 401, the fixed body and the fixed challenge (the
# reason is only in the server's log).
invalid() {
  req 401 -H "$(bearer "$1")" "$U/me"
  expect "$2: the body is fixed" '. == {"error": "invalid token"}'
  c=$(challenge -H "$(bearer "$1")")
  [ "$c" = 'Bearer error="invalid_token"' ] && echo "ok  $2: WWW-Authenticate has invalid_token only" || { echo "NG  $2: WWW-Authenticate is '$c'"; fails=$((fails + 1)); }
}

if [ -z "$secret" ]; then
  echo "NG  no JWT_SECRET (set it, or create .dev.vars from .dev.vars.example)"
  fails=$((fails + 1))
else
  req 401 "$U/me"
  expect "no token: the error says so" '. == {"error": "authentication required"}'
  c=$(challenge)
  [ "$c" = "Bearer" ] && echo "ok  no token: WWW-Authenticate is Bearer" || { echo "NG  WWW-Authenticate is '$c'"; fails=$((fails + 1)); }
  req 401 -H "Authorization: Basic Zm9vOmJhcg==" "$U/me"
  req 200 -H "$(bearer "$good")" "$U/me"
  expect "a valid token: the claims" '.sub == "user-1" and .aud == "todo-api"'
  req 200 -H "authorization: bearer $good" "$U/me"
  invalid "$(jwt "{\"sub\":\"user-1\",\"iss\":\"$iss\",\"aud\":\"todo-api\",\"exp\":$((now + 600))}" wrong-secret-wrong-secret-wrong-secret)" "a bad signature"
  invalid "$good"x "a changed signature"
  # The payload is replaced and the signature kept.
  forged="$(printf %s "$good" | cut -d. -f1).$(printf '{"sub":"admin","exp":%s}' $((now + 600)) | b64u).$(printf %s "$good" | cut -d. -f3)"
  invalid "$forged" "a forged payload"
  invalid "$(jwt "{\"sub\":\"user-1\",\"iss\":\"$iss\",\"aud\":\"todo-api\",\"exp\":$((now - 600))}")" "an expired token"
  req 200 -H "$(bearer "$(jwt "{\"sub\":\"skew\",\"iss\":\"$iss\",\"aud\":\"todo-api\",\"exp\":$((now - 2))}")")" "$U/me"
  expect "JWT_LEEWAY (5 seconds) forgives a little clock skew" '.sub == "skew"'
  invalid "$(jwt "{\"sub\":\"user-1\",\"iss\":\"$iss\",\"aud\":\"todo-api\",\"exp\":$((now + 600)),\"nbf\":$((now + 300))}")" "nbf in the future"
  invalid "$(jwt "{\"sub\":\"user-1\",\"iss\":\"https://evil.example/\",\"aud\":\"todo-api\",\"exp\":$((now + 600))}")" "another issuer"
  invalid "$(jwt "{\"sub\":\"user-1\",\"iss\":\"$iss\",\"aud\":\"other\",\"exp\":$((now + 600))}")" "another audience"
  invalid "$(jwt "{\"sub\":\"user-1\",\"aud\":\"todo-api\",\"exp\":$((now + 600))}")" "no iss"
  invalid "$(jwt "{\"sub\":\"user-1\",\"iss\":\"$iss\",\"exp\":$((now + 600))}")" "no aud"
  invalid "$(jwt "{\"sub\":\"user-1\",\"iss\":\"$iss\",\"aud\":\"todo-api\"}")" "no exp"
  # sub is the user's identity (apps scope data by it), so it is required.
  invalid "$(jwt "{\"iss\":\"$iss\",\"aud\":\"todo-api\",\"exp\":$((now + 600))}")" "no sub"
  invalid "$(jwt "{\"sub\":\"\",\"iss\":\"$iss\",\"aud\":\"todo-api\",\"exp\":$((now + 600))}")" "an empty sub"
  invalid "$(jwt "{\"sub\":\"user-1\",\"iss\":\"$iss\",\"aud\":\"todo-api\",\"exp\":$((now + 600)),\"auth_time\":$((now + 300))}")" "auth_time in the future"
  req 200 -H "$(bearer "$(jwt "{\"sub\":\"user-1\",\"iss\":\"$iss\",\"aud\":\"todo-api\",\"exp\":$((now + 600)),\"auth_time\":$((now - 300))}")")" "$U/me"
  expect "auth_time in the past is fine" '.sub == "user-1"'
  invalid "$(jwt "{\"sub\":\"user-1\",\"iss\":\"$iss\",\"aud\":\"todo-api\",\"exp\":$((now + 600))}" "$secret" '{"alg":"HS256","typ":"JWT","crit":["exp"]}')" "a crit header"
  none="$(printf '{"alg":"none","typ":"JWT"}' | b64u).$(printf '{"sub":"admin","exp":%s}' $((now + 600)) | b64u)."
  invalid "$none" "alg none"
  invalid "not-a-jwt" "not a JWT"
  req 200 "$U/health"
fi

# CORS: CORS_ORIGINS in wrangler.toml is http://localhost:3000.
# header_of NAME [curl args...]: a response header's value, empty if absent.
header_of() {
  n=$1
  shift
  curl -s -o /dev/null -D - "$@" | tr -d '\r' | awk -F': ' -v n="$n" 'tolower($1) == tolower(n) { print $2 }'
}
# same DESCRIPTION WANT GOT: ok if equal.
same() {
  if [ "$2" = "$3" ]; then
    echo "ok  $1"
  else
    echo "NG  $1: '$3' (want '$2')"
    fails=$((fails + 1))
  fi
}
site=http://localhost:3000
req 204 -X OPTIONS -H "Origin: $site" -H 'Access-Control-Request-Method: GET' "$U/todos"
same "preflight: Allow-Origin" "$site" "$(header_of access-control-allow-origin -X OPTIONS -H "Origin: $site" -H 'Access-Control-Request-Method: GET' "$U/todos")"
same "preflight: Allow-Methods" "GET, HEAD, POST, PUT, PATCH, DELETE" "$(header_of access-control-allow-methods -X OPTIONS -H "Origin: $site" -H 'Access-Control-Request-Method: GET' "$U/todos")"
same "preflight: Allow-Headers" "Authorization, Content-Type" "$(header_of access-control-allow-headers -X OPTIONS -H "Origin: $site" -H 'Access-Control-Request-Method: GET' "$U/todos")"
same "preflight: Max-Age" "600" "$(header_of access-control-max-age -X OPTIONS -H "Origin: $site" -H 'Access-Control-Request-Method: GET' "$U/todos")"
req 403 -X OPTIONS -H 'Origin: https://evil.example' -H 'Access-Control-Request-Method: GET' "$U/todos"
expect "a refused preflight says so" '. == {"error": "origin not allowed"}'
same "a refused preflight has no Allow-Origin" "" "$(header_of access-control-allow-origin -X OPTIONS -H 'Origin: https://evil.example' -H 'Access-Control-Request-Method: GET' "$U/todos")"
req 200 -H "Origin: $site" "$U/health"
same "GET from the allowed origin: Allow-Origin" "$site" "$(header_of access-control-allow-origin -H "Origin: $site" "$U/health")"
same "GET from the allowed origin: Vary" "Origin" "$(header_of vary -H "Origin: $site" "$U/health")"
req 200 -H 'Origin: https://evil.example' "$U/health"
same "GET from another origin has no Allow-Origin" "" "$(header_of access-control-allow-origin -H 'Origin: https://evil.example' "$U/health")"
same "an error response has Allow-Origin too" "$site" "$(header_of access-control-allow-origin -H "Origin: $site" "$U/boom")"

echo "$fails NG"
exit "$fails"
