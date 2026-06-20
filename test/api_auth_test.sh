#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
CGI="$DIR/../ui/xkeen-manager/backend/api.cgi"
LIB="$DIR/../ui/xkeen-manager/backend/lib"

api() {
  REQUEST_METHOD="$1" PATH_INFO="$2" HTTP_COOKIE="${4:-}" \
    XKEEN_LIB_DIR="$LIB" XKEEN_STATE_PATH="$DIR/fixtures/state-v1.json" XKEEN_XRAY_CONFDIR="/tmp" \
    sh "$CGI" < "${3:-/dev/null}"
}
mkbody() { _f="$(mktemp)"; printf '%s' "$1" > "$_f"; printf '%s' "$_f"; }

# login with empty body -> 400 (no router call)
assert_contains "login missing creds -> 400" "$(api POST /v1/auth/login "$(mkbody '{}')")" "400 Bad Request"
# session with no cookie -> authenticated:false (no router call)
assert_contains "session no cookie -> false" "$(api GET /v1/auth/session)" '"authenticated":false'
# logout always 200
assert_contains "logout -> 200" "$(api POST /v1/auth/logout)" "200 OK"
assert_contains "logout ok body" "$(api POST /v1/auth/logout)" '"ok":true'

# A cached cookie -> authenticated:true with NO network call (cache hit fast path).
# Pre-populate a shared cache file with a far-future expiry (real now + large ttl), then
# call get_session with that cookie and the same XKEEN_SESSION_CACHE.
SCACHE="$(mktemp)"
( export XKEEN_SESSION_CACHE="$SCACHE"; . "$LIB/session-cache.sh"; session_cache_put "session=valid" 99999999 )
OUT="$(REQUEST_METHOD=GET PATH_INFO=/v1/auth/session HTTP_COOKIE='session=valid' \
  XKEEN_SESSION_CACHE="$SCACHE" XKEEN_LIB_DIR="$LIB" XKEEN_STATE_PATH="$DIR/fixtures/state-v1.json" \
  XKEEN_XRAY_CONFDIR=/tmp sh "$CGI")"
assert_contains "cached cookie -> authenticated true" "$OUT" '"authenticated":true'
rm -f "$SCACHE"

test_summary
