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
XCFG="${XRAY_CFG_DIR:-/opt/etc/xray/configs}"
ASSET="${XRAY_GEO_DIR:-/opt/etc/xray/dat}"
XRAY="${XRAY_BIN:-/opt/sbin/xray}"

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

# Live apply: generate -> backup -> write 05_routing -> xray config self-test (with the
# geo asset dir so ext: refs resolve) -> restart xray -> roll back on any failure.
cmd_apply() {
  _new="$(cmd_generate 2>/dev/null)"
  printf '%s' "$_new" | "$JQ" -e '.routing.rules|type=="array"' >/dev/null 2>&1 || { printf '{"error":"generation failed"}\n'; return 1; }
  [ -x "$XRAY" ] || { printf '{"error":"xray binary not found"}\n'; return 1; }
  mkdir -p "$XCFG" 2>/dev/null
  _rt="$XCFG/05_routing.json"; _bak=""
  [ -f "$_rt" ] && { _bak="$_rt.opm-bak"; cp "$_rt" "$_bak"; }
  printf '%s\n' "$_new" > "$_rt"
  if ! XRAY_LOCATION_ASSET="$ASSET" "$XRAY" run -test -confdir "$XCFG" >/dev/null 2>&1; then
    if [ -n "$_bak" ]; then mv "$_bak" "$_rt"; else rm -f "$_rt"; fi
    printf '{"error":"xray rejected the config — routing unchanged"}\n'; return 1
  fi
  _ok=1
  if [ -f "$LIB/router-actions.sh" ]; then
    . "$LIB/router-actions.sh" 2>/dev/null
    command -v opm_restart_xray >/dev/null 2>&1 && { opm_restart_xray >/dev/null 2>&1 || _ok=0; }
  fi
  if [ "$_ok" = 1 ]; then rm -f "$_bak" 2>/dev/null; printf '{"ok":true}\n'; return 0; fi
  [ -n "$_bak" ] && mv "$_bak" "$_rt"
  command -v opm_restart_xray >/dev/null 2>&1 && opm_restart_xray >/dev/null 2>&1 || true
  printf '{"error":"xray did not come back up — routing rolled back"}\n'; return 1
}

case "${1:-}" in
  get)      cmd_get ;;
  set)      cmd_set ;;
  generate) cmd_generate ;;
  apply)    cmd_apply ;;
  *) echo "usage: opm-routing.sh {get|set|generate|apply}" >&2; exit 2 ;;
esac
