#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
GEN="$DIR/../ui/xkeen-manager/backend/lib/jq/routing-gen.jq"
gen() { jq -f "$GEN" --arg gsfile roscomvpn-geosite.dat --arg gifile roscomvpn-geoip.dat --arg rudom category-ru --arg ruip direct "$@"; }

ROUT="$(gen "$DIR/fixtures/routing-model.json")"
assert_json_eq "rf-direct routing golden" "$DIR/golden/routing-gen.json" "$ROUT"

# specificity: more specific domain comes first (ads.youtube.com before youtube.com)
ord="$(printf '%s' "$ROUT" | jq -r '[.routing.rules[].domain[0]?]|map(select(.=="domain:ads.youtube.com" or .=="domain:youtube.com"))|join(",")')"
assert_eq "specificity order" "domain:ads.youtube.com,domain:youtube.com" "$ord"

# selective: default flips to direct, no RF preset
sel="$(jq '.mode="selective"' "$DIR/fixtures/routing-model.json" | gen /dev/stdin)"
assert_eq "selective catch-all -> direct" "direct" "$(printf '%s' "$sel" | jq -r '.routing.rules[-1].outboundTag')"
assert_eq "selective: no RF preset" "0" "$(printf '%s' "$sel" | jq '[.routing.rules[]|select((.domain//[])|any(test("category-ru")))]|length')"

# all-vpn: default vless, no preset
av="$(jq '.mode="all-vpn"' "$DIR/fixtures/routing-model.json" | gen /dev/stdin)"
assert_eq "all-vpn catch-all -> vless" "vless-reality" "$(printf '%s' "$av" | jq -r '.routing.rules[-1].outboundTag')"

# empty model -> just relay + rf preset + catch-all
em="$(printf '{"mode":"rf-direct","rules":[]}' | gen /dev/stdin)"
assert_eq "empty rf-direct rule count" "4" "$(printf '%s' "$em" | jq '.routing.rules|length')"

test_summary
