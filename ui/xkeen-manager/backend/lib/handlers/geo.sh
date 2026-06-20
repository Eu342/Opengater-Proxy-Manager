# geo.sh — geo-file (geosite/geoip) management endpoints. Delegates to api/opm-geo.sh.
#   GET  /v1/geo                         sources + active
#   GET  /v1/geo/groups                  flat picker list (active sources)
#   PUT  /v1/geo/active   {kind,id}      choose active geosite/geoip
#   POST /v1/geo/sources  {kind,name,url}  add a source (download + parse)
#   POST /v1/geo/sources/<id>/update     re-download + refresh
#   POST /v1/geo/sources/<id>/remove     remove a non-builtin source
_OPM_GEO_SH="${OPM_ROOT:-/opt/share/xkeen-manager}/api/opm-geo.sh"
_geo_run() { sh "$_OPM_GEO_SH" "$@" 2>/dev/null; }
_geo_emit() {
  case "$1" in
    *'"error"'*) http_error 400 geo_error "$(printf '%s' "$1" | jq -r '.error // "geo error"' 2>/dev/null)" ;;
    '{'*|'['*)   http_ok "$1" ;;
    *)           http_error 500 geo_failed "geo operation failed" ;;
  esac
}
_geo_path_id() { printf '%s' "${PATH_INFO:-}" | sed -n 's#^/v1/geo/sources/\([^/]*\)/.*$#\1#p'; }

get_geo()        { _geo_emit "$(_geo_run list)"; }
get_geo_groups() { _geo_emit "$(_geo_run groups)"; }
post_geo_sources() {
  _b="$(cat)"
  _k="$(printf '%s' "$_b" | jq -r '.kind // empty' 2>/dev/null)"
  _n="$(printf '%s' "$_b" | jq -r '.name // empty' 2>/dev/null)"
  _u="$(printf '%s' "$_b" | jq -r '.url // empty' 2>/dev/null)"
  case "$_k" in geosite|geoip) : ;; *) http_error 400 bad_kind "kind must be geosite or geoip"; return ;; esac
  [ -n "$_u" ] || { http_error 400 no_url "url required"; return; }
  _geo_emit "$(_geo_run add "$_k" "${_n:-$_u}" "$_u")"
}
put_geo_active() {
  _b="$(cat)"
  _k="$(printf '%s' "$_b" | jq -r '.kind // empty' 2>/dev/null)"
  _id="$(printf '%s' "$_b" | jq -r '.id // empty' 2>/dev/null)"
  { [ -n "$_k" ] && [ -n "$_id" ]; } || { http_error 400 bad_args "kind and id required"; return; }
  _geo_emit "$(_geo_run set-active "$_k" "$_id")"
}
post_geo_update() { _id="$(_geo_path_id)"; [ -n "$_id" ] || { http_error 400 no_id "id required"; return; }; _geo_emit "$(_geo_run update "$_id")"; }
post_geo_remove() { _id="$(_geo_path_id)"; [ -n "$_id" ] || { http_error 400 no_id "id required"; return; }; _geo_emit "$(_geo_run remove "$_id")"; }
