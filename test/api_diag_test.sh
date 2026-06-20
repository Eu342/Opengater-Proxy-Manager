#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
CGI="$DIR/../ui/xkeen-manager/backend/api.cgi"
LIB="$DIR/../ui/xkeen-manager/backend/lib"
WORK="$(mktemp -d)"; mkdir -p "$WORK/xray"; cp "$DIR/fixtures/state-v1.json" "$WORK/state.json"

api() {
  REQUEST_METHOD="$1" PATH_INFO="$2" QUERY_STRING="${4:-}" HTTP_COOKIE="" XKEEN_AUTH_BYPASS=1 \
    XKEEN_LIB_DIR="$LIB" XKEEN_STATE_PATH="$WORK/state.json" XKEEN_XRAY_CONFDIR="$WORK/xray" \
    sh "$CGI" < "${3:-/dev/null}"
}
api_body() { api "$@" | awk 'p{print} /^\r?$/{p=1}'; }
mkbody() { _f="$(mktemp)"; printf '%s' "$1" > "$_f"; printf '%s' "$_f"; }

# health: 200 + valid JSON with ok:true (degraded zeros on the dev box are fine)
assert_contains "health -> 200" "$(api GET /v1/health)" "200 OK"
assert_eq "health ok:true" "true" "$(api_body GET /v1/health | jq -r '.ok' 2>/dev/null || echo PARSEFAIL)"
# stack: 200 + valid JSON
assert_eq "stack ok:true" "true" "$(api_body GET /v1/stack | jq -r '.ok' 2>/dev/null || echo PARSEFAIL)"
# logs: text/plain 200 (svc=xray)
assert_contains "logs -> 200" "$(api GET /v1/logs '' 'svc=xray&n=10')" "200 OK"
# logs unknown svc -> error
assert_contains "logs unknown svc" "$(api GET /v1/logs '' 'svc=bogus')" "unknown svc"
# probe bad payload -> 400/invalid
assert_contains "probe bad payload" "$(api POST /v1/probe "$(mkbody '{}')")" "invalid"
# restart unknown service -> unknown service error
assert_contains "restart unknown svc" "$(api POST /v1/services/bogus/restart)" "unknown service"

rm -rf "$WORK"
test_summary
