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

# precedence (regression): an explicit USER rule must precede the rf-direct preset, so an
# explicit per-site choice overrides the mode (e.g. a .ru site forced via VPN beats the
# category-ru -> direct preset). xray is first-match-wins.
uidx="$(printf '%s' "$ROUT" | jq '[.routing.rules[].domain[0]?]|index("domain:gosuslugi.ru")')"
pidx="$(printf '%s' "$ROUT" | jq '[.routing.rules[].domain[0]?]|index("ext:roscomvpn-geosite.dat:category-ru")')"
assert_eq "user rule precedes rf preset" "true" "$([ "$uidx" -lt "$pidx" ] && echo true || echo false)"

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

# --- default "always direct" rules (opm-routing.sh seed/migrate) ---
RSH="$DIR/../ui/xkeen-manager/backend/opm-routing.sh"
W="$(mktemp -d)"; export OPM_ROOT="$W"
cat > "$W/geo.json" <<'JSON'
{"activeGeosite":"gs","activeGeoip":"gi","sources":[
  {"id":"gs","kind":"geosite","categories":["category-ru","whitelist","private","torrent"]},
  {"id":"gi","kind":"geoip","categories":["direct","whitelist","private"]}]}
JSON
# fresh seed: whitelist/private/torrent (geosite) + whitelist/private (geoip), all direct
seed="$(sh "$RSH" get)"
assert_eq "seed defaults count" "5" "$(printf '%s' "$seed" | jq '.rules|length')"
assert_eq "seed all direct" "true" "$(printf '%s' "$seed" | jq '[.rules[].action]|all(.=="direct")')"
assert_eq "seed flagged" "true" "$(printf '%s' "$seed" | jq '.defaultsSeeded')"
# migrate an existing pre-defaults model: keep its rule, add defaults once
rm -f "$W/routing.json"
printf '{"mode":"rf-direct","rules":[{"kind":"domain","value":"2ip.ru","action":"vpn"}]}' > "$W/routing.json"
mig="$(sh "$RSH" get)"
assert_eq "migrate keeps user rule" "true" "$(printf '%s' "$mig" | jq '[.rules[]|select(.value=="2ip.ru")]|length==1')"
assert_eq "migrate adds defaults" "6" "$(printf '%s' "$mig" | jq '.rules|length')"
assert_eq "migrate idempotent" "6" "$(sh "$RSH" get | jq '.rules|length')"
# a deleted default must NOT come back (flag preserved through set)
sh "$RSH" get | jq 'del(.rules[]|select(.category=="torrent"))|{mode,rules}' | sh "$RSH" set >/dev/null
assert_eq "deleted default stays gone" "false" "$(sh "$RSH" get | jq '[.rules[]|select(.category=="torrent")]|length>0')"
# only-existing categories are emitted (geofile lacking a category -> no broken rule)
rm -f "$W/routing.json"; printf '{"activeGeosite":"gs","activeGeoip":"gi","sources":[{"id":"gs","kind":"geosite","categories":["category-ru"]},{"id":"gi","kind":"geoip","categories":["direct"]}]}' > "$W/geo.json"
assert_eq "no defaults when categories absent" "0" "$(sh "$RSH" get | jq '.rules|length')"
unset OPM_ROOT; rm -rf "$W"

test_summary
