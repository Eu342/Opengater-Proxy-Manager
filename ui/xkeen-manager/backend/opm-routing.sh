#!/bin/sh
# opm-routing.sh — routing rules model + xray 05_routing.json generation.
#   opm-routing.sh get         print the routing model (seeds default on first run)
#   opm-routing.sh set         read a model from stdin, validate, persist
#   opm-routing.sh generate    print the xray 05_routing.json built from model + active geo
# (Live apply — write 05_routing.json + restart xray with rollback — is wired separately
#  once the routing UI can trigger it.)
set -u
ROOT="${OPM_ROOT:-/opt/share/xkeen-manager}"
GEO="$ROOT/geo.json"
ROUTING="$ROOT/routing.json"
LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib"
GEN="$LIB/jq/routing-gen.jq"
JQ=/opt/bin/jq; [ -x "$JQ" ] || JQ="$(command -v jq)"

_seed() { [ -f "$ROUTING" ] || printf '{"mode":"rf-direct","rules":[]}\n' > "$ROUTING"; }

# gsfile|gifile|rudom|ruip  — from the active geo sources (empty fields if no geo.json)
_geoargs() {
  [ -f "$GEO" ] || { printf '|||'; return; }
  "$JQ" -r '
    . as $g
    | ([$g.sources[]|select(.id==$g.activeGeosite)][0]) as $gs
    | ([$g.sources[]|select(.id==$g.activeGeoip)][0]) as $gi
    | [ ($gs.file // ""), ($gi.file // ""), (($gs.roles."ru-domains") // ""), (($gi.roles."ru-ips") // "") ] | join("|")
  ' "$GEO" 2>/dev/null
}

cmd_get() { _seed; cat "$ROUTING"; }

cmd_set() {
  _b="$(cat)"
  printf '%s' "$_b" | "$JQ" -e '(.mode|type=="string") and ((.rules // [])|type=="array")' >/dev/null 2>&1 \
    || { printf '{"error":"invalid routing model"}\n'; return 1; }
  _m="$(printf '%s' "$_b" | "$JQ" -r .mode)"
  case "$_m" in rf-direct|selective|all-vpn|all-direct) : ;; *) printf '{"error":"bad mode"}\n'; return 1 ;; esac
  printf '%s' "$_b" | "$JQ" -c '{mode:.mode, rules:(.rules // [])}' > "$ROUTING"
  cat "$ROUTING"
}

cmd_generate() {
  _seed
  _a="$(_geoargs)"
  _gs="$(printf '%s' "$_a" | cut -d'|' -f1)"
  _gi="$(printf '%s' "$_a" | cut -d'|' -f2)"
  _rd="$(printf '%s' "$_a" | cut -d'|' -f3)"
  _ri="$(printf '%s' "$_a" | cut -d'|' -f4)"
  "$JQ" -f "$GEN" --arg gsfile "$_gs" --arg gifile "$_gi" --arg rudom "$_rd" --arg ruip "$_ri" "$ROUTING"
}

case "${1:-}" in
  get)      cmd_get ;;
  set)      cmd_set ;;
  generate) cmd_generate ;;
  *) echo "usage: opm-routing.sh {get|set|generate}" >&2; exit 2 ;;
esac
