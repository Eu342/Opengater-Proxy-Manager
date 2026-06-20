#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
CGI="$DIR/../ui/xkeen-manager/backend/api.cgi"
LIB="$DIR/../ui/xkeen-manager/backend/lib"
WORK="$(mktemp -d)"
cp "$DIR/fixtures/state-v1.json" "$WORK/state.json"
mkdir -p "$WORK/xray"

# api <method> <path> [bodyfile] -> raw CGI output (status line + headers + body)
api() {
  REQUEST_METHOD="$1" PATH_INFO="$2" HTTP_COOKIE="" XKEEN_AUTH_BYPASS=1 XKEEN_APPLY_SYNC=1 \
    XKEEN_LIB_DIR="$LIB" XKEEN_STATE_PATH="$WORK/state.json" XKEEN_XRAY_CONFDIR="$WORK/xray" \
    XKEEN_SELFTEST_CMD=true XKEEN_RESTART_CMD=true XKEEN_RUNTIME_CMD=true \
    sh "$CGI" < "${3:-/dev/null}"
}
# api_body: just the response body (drops headers up to and including the blank line)
api_body() { api "$@" | awk 'p{print} /^\r?$/{p=1}'; }
mkbody() { _f="$(mktemp)"; printf '%s' "$1" > "$_f"; printf '%s' "$_f"; }

# get_state -> v2
assert_eq "get_state is v2" "2" "$(api_body GET /v1/state | jq -r .schemaVersion)"

# put_state valid (the v1 fixture) -> 200, persists; invalid -> 400; non-JSON -> 400
BF="$(mkbody "$(cat "$DIR/fixtures/state-v1.json")")"
assert_contains "put_state valid -> 200" "$(api PUT /v1/state "$BF")" "200 OK"
BF2="$(mkbody '{"profiles":[]}')"
assert_contains "put_state invalid -> 400" "$(api PUT /v1/state "$BF2")" "400 Bad Request"
BF3="$(mkbody 'not json')"
assert_contains "put_state non-JSON -> 400" "$(api PUT /v1/state "$BF3")" "400 Bad Request"

# post_apply (sync) -> 202 + jobId; status ok; configs written
APB="$(mkbody "$(cat "$DIR/fixtures/state-v1.json")")"
AP="$(api_body POST /v1/apply "$APB")"
JOBID="$(printf '%s' "$AP" | jq -r .jobId)"
assert_eq "apply returns a jobId" "ok-nonempty" "$(j="$JOBID"; if [ -z "$j" ] || [ "$j" = "null" ]; then echo empty; else echo ok-nonempty; fi)"
assert_eq "apply job status ok" "ok" "$(api_body GET "/v1/apply/$JOBID" | jq -r .status)"
rm -f "/tmp/xkeen-apply-${JOBID}.json"

# get_config outbounds (apply wrote it) -> vless-reality
assert_eq "get_config outbounds" "vless-reality" "$(api_body GET /v1/config/outbounds | jq -r '.outbounds[0].tag')"

# get_apply_status: traversal/edge ids handled safely (no path escape from /tmp/xkeen-apply-*.json)
assert_contains "apply id percent-encoded -> 400" "$(api GET '/v1/apply/..%2fetc')" "400 Bad Request"
assert_contains "apply id dotdot -> 400"          "$(api GET '/v1/apply/..')"        "400 Bad Request"
assert_contains "apply id decoded-slash last seg -> 404" "$(api GET '/v1/apply/../etc')" "404 Not Found"

# settings
assert_eq "get_settings default" "reject" "$(api_body GET /v1/settings | jq -r .ipv6Mode)"
SB="$(mkbody '{"ipv6Mode":"allow"}')"
assert_contains "put_settings allow -> 200" "$(api PUT /v1/settings "$SB")" "200 OK"
assert_eq "settings persisted" "allow" "$(api_body GET /v1/settings | jq -r .ipv6Mode)"
SB2="$(mkbody '{"ipv6Mode":"bogus"}')"
assert_contains "put_settings bad -> 400" "$(api PUT /v1/settings "$SB2")" "400 Bad Request"

# core
assert_eq "get_core active" "xray" "$(api_body GET /v1/core | jq -r .active)"
assert_eq "get_core lists mihomo" "mihomo" "$(api_body GET /v1/core | jq -r '.available[1]')"
CB="$(mkbody '{"core":"mihomo"}')"
assert_contains "put_core mihomo -> 501" "$(api PUT /v1/core "$CB")" "501 Not Implemented"
CB2="$(mkbody '{"core":"xray"}')"
assert_contains "put_core xray -> 200" "$(api PUT /v1/core "$CB2")" "200 OK"

rm -rf "$WORK"
test_summary
