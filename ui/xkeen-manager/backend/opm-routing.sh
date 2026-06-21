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

# Default "always direct" rules — common local / P2P traffic shown as ordinary,
# user-DELETABLE rules in the Always-direct list. (whitelist is NOT here: it belongs to the
# rf-direct mode preset, see _directcats.) Only categories that actually exist in the active
# geo sources are emitted, so a custom geo-file never yields a broken ext: ref. The
# defaultsSeeded flag stops deleted ones from coming back.
_default_rules() {
  [ -f "$GEO" ] || { printf '[]'; return; }
  "$JQ" -c '
    . as $g
    | ([$g.sources[]|select(.id==$g.activeGeosite)][0].categories // []) as $gs
    | ([$g.sources[]|select(.id==$g.activeGeoip)][0].categories // []) as $gi
    | ( (["private","torrent"] | map(select(. as $c | $gs|index($c)) | {kind:"geosite",category:.,action:"direct"}))
      + (["private"]           | map(select(. as $c | $gi|index($c)) | {kind:"geoip",  category:.,action:"direct"})) )
  ' "$GEO" 2>/dev/null
}

_seed() {
  [ -f "$ROUTING" ] && return
  _d="$(_default_rules)"; case "$_d" in '['*) : ;; *) _d='[]' ;; esac
  "$JQ" -n --argjson d "$_d" '{mode:"rf-direct",rules:$d,defaultsSeeded:true}' > "$ROUTING"
}

# One-time migration: a routing.json created before defaults existed gets them injected
# (deduped by kind+category), then the flag is set so the user's later deletions stick.
_migrate_defaults() {
  [ -f "$ROUTING" ] || return
  "$JQ" -e '.defaultsSeeded==true' "$ROUTING" >/dev/null 2>&1 && return
  _d="$(_default_rules)"; case "$_d" in '['*) : ;; *) _d='[]' ;; esac
  _t="$(mktemp)"
  "$JQ" --argjson d "$_d" '
    (.rules // []) as $ex
    | .rules = ($ex + [ $d[] | select(. as $n | ($ex|any(.kind==$n.kind and .category==$n.category))|not) ])
    | .defaultsSeeded = true
  ' "$ROUTING" > "$_t" 2>/dev/null && mv "$_t" "$ROUTING" || rm -f "$_t"
}

# {gsfile,gifile,gsdirect[],gidirect[]} for the rf-direct mode preset. gsdirect/gidirect are
# the categories that the "Russia direct, world via VPN" mode sends DIRECT: the role-tagged
# RF list (ru-domains / ru-ips) PLUS the maintainer whitelist, where each exists. Emitted as
# JSON arrays so the generator builds one combined direct rule per .dat.
_geocfg() {
  [ -f "$GEO" ] || { printf '{"gsfile":"","gifile":"","gsdirect":[],"gidirect":[]}'; return; }
  "$JQ" -c '
    . as $g
    | ([$g.sources[]|select(.id==$g.activeGeosite)][0]) as $gs
    | ([$g.sources[]|select(.id==$g.activeGeoip)][0]) as $gi
    | {
        gsfile: ($gs.file // ""),
        gifile: ($gi.file // ""),
        gsdirect: ( [ ($gs.roles."ru-domains" // empty) ]
                    + ( ["whitelist"] | map(select(. as $c | ($gs.categories // [])|index($c))) ) | unique ),
        gidirect: ( [ ($gi.roles."ru-ips" // empty) ]
                    + ( ["whitelist"] | map(select(. as $c | ($gi.categories // [])|index($c))) ) | unique )
      }
  ' "$GEO" 2>/dev/null
}

cmd_get() { _seed; _migrate_defaults; cat "$ROUTING"; }

cmd_set() {
  _b="$(cat)"
  printf '%s' "$_b" | "$JQ" -e '(.mode|type=="string") and ((.rules // [])|type=="array")' >/dev/null 2>&1 \
    || { printf '{"error":"invalid routing model"}\n'; return 1; }
  _m="$(printf '%s' "$_b" | "$JQ" -r .mode)"
  case "$_m" in rf-direct|selective|all-vpn|all-direct) : ;; *) printf '{"error":"bad mode"}\n'; return 1 ;; esac
  # Persist mode+rules, and keep defaultsSeeded sticky so the one-time default injection
  # never re-runs (otherwise a user-deleted default would reappear on the next GET).
  printf '%s' "$_b" | "$JQ" -c '{mode:.mode, rules:(.rules // []), defaultsSeeded:true}' > "$ROUTING"
  cat "$ROUTING"
}

cmd_generate() {
  _seed
  _c="$(_geocfg)"; case "$_c" in '{'*) : ;; *) _c='{"gsfile":"","gifile":"","gsdirect":[],"gidirect":[]}' ;; esac
  _gs="$(printf '%s' "$_c" | "$JQ" -r .gsfile)"
  _gi="$(printf '%s' "$_c" | "$JQ" -r .gifile)"
  _gsd="$(printf '%s' "$_c" | "$JQ" -c .gsdirect)"
  _gid="$(printf '%s' "$_c" | "$JQ" -c .gidirect)"
  "$JQ" -f "$GEN" --arg gsfile "$_gs" --arg gifile "$_gi" --argjson gsdirect "$_gsd" --argjson gidirect "$_gid" "$ROUTING"
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
