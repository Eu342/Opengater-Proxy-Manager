#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
CGI="$DIR/../ui/xkeen-manager/backend/api.cgi"
LIB="$DIR/../ui/xkeen-manager/backend/lib"

run_cgi() {
  REQUEST_METHOD="$1" PATH_INFO="$2" HTTP_COOKIE="${3:-}" \
    XKEEN_LIB_DIR="$LIB" XKEEN_STATE_PATH="$DIR/fixtures/state-v1.json" XKEEN_XRAY_CONFDIR="/tmp" \
    sh "$CGI"
}
run_cgi_bypass() {
  REQUEST_METHOD="$1" PATH_INFO="$2" HTTP_COOKIE="" XKEEN_AUTH_BYPASS=1 \
    XKEEN_LIB_DIR="$LIB" XKEEN_STATE_PATH="$DIR/fixtures/state-v1.json" XKEEN_XRAY_CONFDIR="/tmp" \
    sh "$CGI"
}

OUT="$(run_cgi GET /v1/nope)";              assert_contains "unknown route -> 404 (pre-auth)" "$OUT" "404 Not Found"
OUT="$(run_cgi DELETE /v1/state)";          assert_contains "bad method -> 405 (pre-auth)"     "$OUT" "405 Method Not Allowed"
OUT="$(run_cgi GET /v1/health)";            assert_contains "no session -> 401"                "$OUT" "401 Unauthorized"
OUT="$(run_cgi POST /v1/subscription/import)"; assert_contains "stub now behind auth -> 401"   "$OUT" "401 Unauthorized"
OUT="$(run_cgi GET /v1/nope)";              assert_contains "json error envelope"              "$OUT" '"ok":false'
OUT="$(run_cgi_bypass POST /v1/subscription/import)"; assert_contains "stub with auth -> 501"  "$OUT" "501 Not Implemented"
OUT="$(run_cgi_bypass GET /v1/health)";     assert_contains "bypass reaches get_health -> 200" "$OUT" "200 OK"

# Host-header spoofing must NOT bypass auth: a spoofed Host with a (fake) cookie still fails,
# because validation targets SERVER_ADDR, not HTTP_HOST. With no SERVER_ADDR and a junk cookie,
# the wget to 127.0.0.1/auth fails on the dev machine -> 401 (no bypass).
OUT="$(REQUEST_METHOD=GET PATH_INFO=/v1/health HTTP_COOKIE='session=junk' HTTP_HOST='attacker.example' \
  XKEEN_LIB_DIR="$LIB" XKEEN_STATE_PATH="$DIR/fixtures/state-v1.json" XKEEN_XRAY_CONFDIR=/tmp sh "$CGI")"
assert_contains "spoofed Host does not bypass auth" "$OUT" "401 Unauthorized"

test_summary
