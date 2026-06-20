#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
XKEEN_LIB_DIR="$DIR/../ui/xkeen-manager/backend/lib"; export XKEEN_LIB_DIR
. "$XKEEN_LIB_DIR/state-migrate.sh"

OUT="$(migrate_state "$DIR/fixtures/state-v1.json")"

assert_eq "schemaVersion set to 2" "2" "$(printf '%s' "$OUT" | jq -r '.schemaVersion')"
assert_eq "activeCore defaults to xray" "xray" "$(printf '%s' "$OUT" | jq -r '.activeCore')"
assert_eq "xray proxyConfig lifted" "vpn.example.com" \
  "$(printf '%s' "$OUT" | jq -r '.profiles[0].cores.xray.proxyConfig.address')"
assert_eq "xray groups lifted" "AI" \
  "$(printf '%s' "$OUT" | jq -r '.profiles[0].cores.xray.groups[0].name')"
assert_eq "mihomo namespace created" "reality" \
  "$(printf '%s' "$OUT" | jq -r '.profiles[0].cores.mihomo.proxyConfig.transport')"
assert_eq "ipv6Mode default" "reject" \
  "$(printf '%s' "$OUT" | jq -r '.settings.ipv6Mode')"

# Idempotency: migrating the migrated state changes nothing.
TMP="$(mktemp)"; printf '%s' "$OUT" > "$TMP"
OUT2="$(migrate_state "$TMP")"
assert_json_eq "migration is idempotent" "$OUT" "$OUT2"
rm -f "$TMP"

# Drift guard: the committed v2 fixture must equal migrate(v1), so editing the
# migration jq can't silently leave the generator goldens testing a stale fixture.
assert_json_eq "v2 fixture equals migrate(v1)" "$DIR/fixtures/state-v2.json" "$OUT"

test_summary
