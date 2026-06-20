#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
XKEEN_LIB_DIR="$DIR/../ui/xkeen-manager/backend/lib"; export XKEEN_LIB_DIR
. "$XKEEN_LIB_DIR/state-migrate.sh"
. "$XKEEN_LIB_DIR/validate.sh"

# A valid v2 state (migrate the v1 fixture).
VALID="$(migrate_state "$DIR/fixtures/state-v1.json")"
TMP="$(mktemp)"; printf '%s' "$VALID" > "$TMP"
if validate_state "$TMP" >/dev/null 2>&1; then assert_eq "valid state passes" "0" "0"; else assert_eq "valid state passes" "0" "1"; fi
rm -f "$TMP"

# Bad activeCore.
BAD="$(printf '%s' "$VALID" | jq '.activeCore="nope"')"
T2="$(mktemp)"; printf '%s' "$BAD" > "$T2"
ERR="$(validate_state "$T2" 2>&1 || true)"
assert_contains "bad activeCore reported" "$ERR" "activeCore"
rm -f "$T2"

# Bad outboundTag.
BAD2="$(printf '%s' "$VALID" | jq '.profiles[0].cores.xray.groups[0].outboundTag="weird"')"
T3="$(mktemp)"; printf '%s' "$BAD2" > "$T3"
ERR2="$(validate_state "$T3" 2>&1 || true)"
assert_contains "bad outboundTag reported" "$ERR2" "outboundTag"
rm -f "$T3"

# Empty profiles.
BAD3="$(printf '%s' "$VALID" | jq '.profiles=[]')"
T4="$(mktemp)"; printf '%s' "$BAD3" > "$T4"
ERR3="$(validate_state "$T4" 2>&1 || true)"
assert_contains "empty profiles reported" "$ERR3" "profiles"
rm -f "$T4"

# Not valid JSON at all.
T5="$(mktemp)"; printf 'not json' > "$T5"
ERR4="$(validate_state "$T5" 2>&1 || true)"
assert_contains "non-JSON file rejected" "$ERR4" "not valid JSON"
rm -f "$T5"

test_summary
