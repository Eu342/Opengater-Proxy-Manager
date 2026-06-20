#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
XKEEN_LIB_DIR="$DIR/../ui/xkeen-manager/backend/lib"; export XKEEN_LIB_DIR
. "$XKEEN_LIB_DIR/gen-xray.sh"

OUT="$(gen_xray_outbounds "$DIR/fixtures/state-v2.json")"
assert_json_eq "outbounds match frontend (reality)" "$DIR/golden/outbounds-v2.json" "$OUT"

ROUT="$(gen_xray_routing "$DIR/fixtures/state-v2.json")"
assert_json_eq "routing matches frontend" "$DIR/golden/routing-v2.json" "$ROUT"

OUTX="$(gen_xray_outbounds "$DIR/fixtures/state-xhttp.json")"
assert_json_eq "outbounds match (xhttp transport)" "$DIR/golden/outbounds-xhttp.json" "$OUTX"

OUTM="$(gen_xray_outbounds "$DIR/fixtures/state-mux-xudp.json")"
assert_json_eq "outbounds match (mux xudp)" "$DIR/golden/outbounds-mux-xudp.json" "$OUTM"

test_summary
