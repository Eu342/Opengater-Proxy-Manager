#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
XKEEN_LIB_DIR="$DIR/../ui/xkeen-manager/backend/lib"; export XKEEN_LIB_DIR
. "$XKEEN_LIB_DIR/normalize.sh"

OUT="$(normalize_state "$DIR/fixtures/state-messy.json")"
assert_json_eq "messy state normalizes to golden" "$DIR/golden/state-normalized.json" "$OUT"

# Idempotency: normalizing the golden changes nothing.
TMP="$(mktemp)"; printf '%s' "$OUT" > "$TMP"
OUT2="$(normalize_state "$TMP")"
assert_json_eq "normalize is idempotent" "$OUT" "$OUT2"
rm -f "$TMP"

# Edge: missing mode defaults to "off" (frontend behavior), even with xudpConcurrency>0.
MISS="$(jq 'del(.profiles[0].cores.xray.muxConfig.mode) | .profiles[0].cores.xray.muxConfig.xudpConcurrency=8' "$DIR/fixtures/state-messy.json")"
TMM="$(mktemp)"; printf '%s' "$MISS" > "$TMM"
assert_eq "missing mode -> off" "off" "$(normalize_state "$TMM" | jq -r '.profiles[0].cores.xray.muxConfig.mode')"
rm -f "$TMM"

# Edge: present-but-invalid mode derives from xudpConcurrency (here >0 -> xudp).
BADM="$(jq '.profiles[0].cores.xray.muxConfig.mode="garbage" | .profiles[0].cores.xray.muxConfig.xudpConcurrency=8' "$DIR/fixtures/state-messy.json")"
TBM="$(mktemp)"; printf '%s' "$BADM" > "$TBM"
assert_eq "invalid mode -> derived xudp" "xudp" "$(normalize_state "$TBM" | jq -r '.profiles[0].cores.xray.muxConfig.mode')"
rm -f "$TBM"

test_summary
