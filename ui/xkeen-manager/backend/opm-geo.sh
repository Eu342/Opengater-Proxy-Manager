#!/bin/sh
# opm-geo.sh — geo-file (geosite / geoip) manager for routing.
#
#   opm-geo.sh seed                     create geo.json with the default roscomvpn sources
#   opm-geo.sh list                     print geo.json (seeds on first run)
#   opm-geo.sh groups                   flat group list for the picker (active sources only)
#   opm-geo.sh categories <datfile>     print categories of a .dat (one per line)
#   opm-geo.sh add <kind> <name> <url>  download + parse + register a source
#   opm-geo.sh update <id>              re-download + refresh categories
#   opm-geo.sh remove <id>              remove a (non-builtin) source
#   opm-geo.sh set-active <kind> <id>   choose the active geosite / geoip
#
# Categories are read straight from the .dat (protobuf: repeated entry, entry.field1 =
# country_code) with a streaming od+awk walk — no protoc, O(1) memory, works for any
# geosite/geoip .dat. The active .dat lives in XRAY_LOCATION_ASSET and is referenced
# from routing as ext:<file>:<category>.
set -u

ROOT="${OPM_ROOT:-/opt/share/xkeen-manager}"
ASSET="${XRAY_GEO_DIR:-/opt/etc/xray/dat}"
GEO="$ROOT/geo.json"
GS_URL="https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite@release/geosite.dat"
GI_URL="https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geoip@release/geoip.dat"

AWKBIN=/opt/bin/gawk; [ -x "$AWKBIN" ] || AWKBIN="$(command -v gawk 2>/dev/null || command -v awk)"
OD=/opt/bin/od;       [ -x "$OD" ]     || OD="$(command -v od)"
JQ=/opt/bin/jq;       [ -x "$JQ" ]     || JQ="$(command -v jq)"
CURL=/opt/bin/curl;   [ -x "$CURL" ]   || CURL="$(command -v curl)"

_now() { date +%s 2>/dev/null || echo 0; }

# --- category parser: <datfile> -> category names (lowercase, one per line) ---
# Uses `od -b` (octal bytes; supported by busybox od, BSD od and GNU od). Each output
# line is "<octal-offset> <octal-byte>...": we skip $1 and decode the rest manually
# (no strtonum, so it runs on busybox gawk AND BSD awk). protobuf walk: repeated
# entry (field 1), entry.field1 = country_code string.
_cats() {
  [ -f "$1" ] || return 1
  "$OD" -v -b "$1" 2>/dev/null | "$AWKBIN" '
    function oct(s,  n,j){ n=0; for(j=1;j<=length(s);j++) n=n*8+(substr(s,j,1)+0); return n }
    BEGIN{ st="TT"; v=0; sh=0; cc=""; need=0; skip=0; used=0; elen=0 }
    {
      for(f=2; f<=NF; f++){
        b=oct($f)
        if(st=="TT"){ if(b==10){ st="TL"; v=0; sh=0 } continue }
        if(st=="TL"){ v+=(b%128)*(2^sh); sh+=7; if(b<128){ elen=v; used=0; st="CT" } continue }
        if(st=="CT"){ used++; if(b==10){ st="CL"; v=0; sh=0 } else { skip=elen-used; st=(skip>0?"SK":"TT") } continue }
        if(st=="CL"){ used++; v+=(b%128)*(2^sh); sh+=7; if(b<128){ need=v; cc=""; st=(need>0?"CR":"TT") } continue }
        if(st=="CR"){ used++; cc=cc sprintf("%c",b); need--; if(need<=0){ print tolower(cc); skip=elen-used; st=(skip>0?"SK":"TT") } continue }
        if(st=="SK"){ skip--; if(skip<=0){ st="TT" } continue }
      }
    }'
}
_cats_json() { _cats "$1" | "$JQ" -R . | "$JQ" -s 'map(select(length>0))|unique'; }

_download() { # <url> <dest>
  "$CURL" -s -L --max-time 90 -o "$2.tmp" "$1" 2>/dev/null && [ -s "$2.tmp" ] && mv "$2.tmp" "$2" || { rm -f "$2.tmp" 2>/dev/null; return 1; }
}
_slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/--*/-/g;s/^-//;s/-$//'; }

cmd_categories() { _cats "$1"; }

cmd_seed() {
  [ -f "$GEO" ] && { cat "$GEO"; return 0; }
  mkdir -p "$ASSET" "$(dirname "$GEO")" 2>/dev/null
  _download "$GS_URL" "$ASSET/roscomvpn-geosite.dat" 2>/dev/null || true
  _download "$GI_URL" "$ASSET/roscomvpn-geoip.dat" 2>/dev/null || true
  gsc="$( [ -f "$ASSET/roscomvpn-geosite.dat" ] && _cats_json "$ASSET/roscomvpn-geosite.dat" )"
  case "$gsc" in '['*) : ;; *) gsc='["category-ru","category-geoblock-ru","youtube","telegram","steam","apple","google-play","github","microsoft","twitch","torrent","category-ads","whitelist","private"]' ;; esac
  gic="$( [ -f "$ASSET/roscomvpn-geoip.dat" ] && _cats_json "$ASSET/roscomvpn-geoip.dat" )"
  case "$gic" in '['*) : ;; *) gic='["direct","whitelist","private"]' ;; esac
  "$JQ" -n --argjson ts "$(_now)" --arg gsu "$GS_URL" --arg giu "$GI_URL" --argjson gsc "$gsc" --argjson gic "$gic" '{
    sources:[
      {id:"roscomvpn-geosite",name:"RoscomVPN · сайты",kind:"geosite",file:"roscomvpn-geosite.dat",url:$gsu,categories:$gsc,roles:{"ru-domains":"category-ru","blocked":"category-geoblock-ru"},builtin:true,updatedAt:$ts},
      {id:"roscomvpn-geoip",name:"RoscomVPN · IP",kind:"geoip",file:"roscomvpn-geoip.dat",url:$giu,categories:$gic,roles:{"ru-ips":"direct"},builtin:true,updatedAt:$ts}
    ],
    activeGeosite:"roscomvpn-geosite", activeGeoip:"roscomvpn-geoip"
  }' > "$GEO"
  cat "$GEO"
}

cmd_list() { [ -f "$GEO" ] || cmd_seed >/dev/null; cat "$GEO"; }

cmd_groups() {
  [ -f "$GEO" ] || cmd_seed >/dev/null
  "$JQ" '
    . as $g
    | ([$g.sources[]|select(.id==$g.activeGeosite)][0]) as $gs
    | ([$g.sources[]|select(.id==$g.activeGeoip)][0]) as $gi
    | ( (($gs.categories // []) | map({id:($gs.id+":"+.), source:$gs.id, file:$gs.file, category:., kind:"site"}))
      + (($gi.categories // []) | map({id:($gi.id+":"+.), source:$gi.id, file:$gi.file, category:., kind:"ip"})) )
  ' "$GEO"
}

cmd_add() {
  _k="$1"; _n="$2"; _u="$3"
  case "$_k" in geosite|geoip) : ;; *) printf '{"error":"kind must be geosite or geoip"}\n'; return 1 ;; esac
  [ -n "$_u" ] || { printf '{"error":"url required"}\n'; return 1; }
  [ -f "$GEO" ] || cmd_seed >/dev/null
  _id="$(_slug "$_n")"; [ -n "$_id" ] || _id="$(_slug "$_u")"; _id="${_id:-src}-$_k"
  _file="$_id.dat"
  mkdir -p "$ASSET" 2>/dev/null
  _download "$_u" "$ASSET/$_file" || { printf '{"error":"download failed"}\n'; return 1; }
  _cats="$(_cats_json "$ASSET/$_file")"
  case "$_cats" in '['*[a-z0-9]*) : ;; *) rm -f "$ASSET/$_file"; printf '{"error":"could not read categories (not a geosite/geoip .dat?)"}\n'; return 1 ;; esac
  _obj="$("$JQ" -n --arg id "$_id" --arg name "$_n" --arg kind "$_k" --arg file "$_file" --arg url "$_u" --argjson cats "$_cats" --argjson ts "$(_now)" \
    '{id:$id,name:$name,kind:$kind,file:$file,url:$url,categories:$cats,roles:{},builtin:false,updatedAt:$ts}')"
  _t="$(mktemp)"; "$JQ" --argjson o "$_obj" '.sources |= (map(select(.id!=$o.id)) + [$o])' "$GEO" > "$_t" && mv "$_t" "$GEO"
  cat "$GEO"
}

cmd_update() {
  _id="$1"; [ -f "$GEO" ] || cmd_seed >/dev/null
  _src="$("$JQ" -c --arg id "$_id" '.sources[]|select(.id==$id)' "$GEO")"
  [ -n "$_src" ] || { printf '{"error":"no such source"}\n'; return 1; }
  _u="$(printf '%s' "$_src" | "$JQ" -r .url)"; _file="$(printf '%s' "$_src" | "$JQ" -r .file)"
  _download "$_u" "$ASSET/$_file" || { printf '{"error":"download failed"}\n'; return 1; }
  _cats="$(_cats_json "$ASSET/$_file")"
  _t="$(mktemp)"; "$JQ" --arg id "$_id" --argjson cats "$_cats" --argjson ts "$(_now)" \
    '.sources |= map(if .id==$id then (.categories=$cats | .updatedAt=$ts) else . end)' "$GEO" > "$_t" && mv "$_t" "$GEO"
  cat "$GEO"
}

cmd_remove() {
  _id="$1"; [ -f "$GEO" ] || cmd_seed >/dev/null
  _bi="$("$JQ" --arg id "$_id" 'any(.sources[];.id==$id and .builtin)' "$GEO")"
  [ "$_bi" = "true" ] && { printf '{"error":"built-in source cannot be removed"}\n'; return 1; }
  _file="$("$JQ" -r --arg id "$_id" '.sources[]|select(.id==$id)|.file' "$GEO" 2>/dev/null)"
  _t="$(mktemp)"; "$JQ" --arg id "$_id" '
    .sources |= map(select(.id!=$id))
    | (if .activeGeosite==$id then .activeGeosite=((first(.sources[]|select(.kind=="geosite")|.id))//"") else . end)
    | (if .activeGeoip==$id   then .activeGeoip=((first(.sources[]|select(.kind=="geoip")|.id))//"")   else . end)
  ' "$GEO" > "$_t" && mv "$_t" "$GEO"
  [ -n "$_file" ] && [ "$_file" != "null" ] && rm -f "$ASSET/$_file" 2>/dev/null
  cat "$GEO"
}

cmd_set_active() {
  _k="$1"; _id="$2"; [ -f "$GEO" ] || cmd_seed >/dev/null
  _ok="$("$JQ" --arg id "$_id" --arg k "$_k" 'any(.sources[];.id==$id and .kind==$k)' "$GEO")"
  [ "$_ok" = "true" ] || { printf '{"error":"no such source for that kind"}\n'; return 1; }
  _key="$([ "$_k" = geosite ] && echo activeGeosite || echo activeGeoip)"
  _t="$(mktemp)"; "$JQ" --arg k "$_key" --arg id "$_id" '.[$k]=$id' "$GEO" > "$_t" && mv "$_t" "$GEO"
  cat "$GEO"
}

[ "${OPM_GEO_LIB:-0}" = 1 ] || case "${1:-}" in
  seed)        cmd_seed ;;
  list)        cmd_list ;;
  groups)      cmd_groups ;;
  categories)  shift; cmd_categories "${1:-}" ;;
  add)         shift; cmd_add "${1:-}" "${2:-}" "${3:-}" ;;
  update)      shift; cmd_update "${1:-}" ;;
  remove)      shift; cmd_remove "${1:-}" ;;
  set-active)  shift; cmd_set_active "${1:-}" "${2:-}" ;;
  *) echo "usage: opm-geo.sh {seed|list|groups|categories <f>|add <kind> <name> <url>|update <id>|remove <id>|set-active <kind> <id>}" >&2; exit 2 ;;
esac
