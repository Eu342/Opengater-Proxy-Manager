# Server-side subscription store. The parsed subscription (name + locations +
# raw) lived only in browser localStorage, so it was invisible from other
# devices. Persist it on the router so every device on the same panel sees it.

_OPM_SUB_FILE="${OPM_SUB_FILE:-/opt/share/xkeen-manager/subscription.json}"

# GET /v1/subscription -> stored subscription json (or {})
get_subscription() {
  if [ -f "$_OPM_SUB_FILE" ]; then
    http_ok "$(cat "$_OPM_SUB_FILE" 2>/dev/null)"
  else
    http_ok '{}'
  fi
}

# PUT /v1/subscription  <json> -> persist (validated as JSON)
put_subscription() {
  _sb="$(cat)"
  printf '%s' "$_sb" | jq -e . >/dev/null 2>&1 || { http_error 400 bad_request "invalid json body"; return; }
  # atomic write: the runtime reads this file to decide whether the VPN may be enabled, so a
  # half-written file must never be observable.
  _tmp="$_OPM_SUB_FILE.tmp.$$"
  printf '%s\n' "$_sb" > "$_tmp" 2>/dev/null && mv "$_tmp" "$_OPM_SUB_FILE" 2>/dev/null \
    || { rm -f "$_tmp" 2>/dev/null; http_error 500 write_failed "cannot write subscription"; return; }
  http_ok '{"ok":true}'
}

# Pull one response-header value, case-insensitive name, last occurrence wins (so a
# redirect chain yields the final response's header). Trailing CR and leading spaces
# are stripped. POSIX awk only (busybox-safe). $1=header dump file, $2=lowercase name.
_sub_hdr() {
  awk -v n="$2" '
    { line=$0; sub(/\r$/,"",line); low=tolower(line); p=n ":";
      if (substr(low,1,length(p))==p) { v=substr(line, index(line,":")+1); sub(/^[ \t]+/,"",v); val=v } }
    END { print val }' "$1" 2>/dev/null
}

# POST /v1/subscription/fetch  {url}  -> fetch the subscription URL server-side with a
# client User-Agent (Happ), so the provider returns the config instead of its HTML page.
# Browsers can't set User-Agent (or read cross-origin response headers), so the panel
# proxies via the router. We also surface the subscription metadata headers the panel
# uses: profile-title (the name the user sees), subscription-userinfo (traffic + expiry),
# profile-update-interval (auto-refresh hours).
fetch_subscription() {
  _u="$(cat | jq -r '.url // empty' 2>/dev/null)"
  case "$_u" in http://*|https://*) : ;; *) http_error 400 bad_request "url must be http(s)"; return ;; esac
  _hdr="$(mktemp)"; _bdy="$(mktemp)"
  /opt/bin/curl -s -L --max-time 25 -A 'Happ' -D "$_hdr" -o "$_bdy" "$_u" 2>/dev/null
  _out="$(cat "$_bdy" 2>/dev/null)"
  if [ -z "$_out" ]; then rm -f "$_hdr" "$_bdy"; http_error 502 fetch_failed "empty response from provider"; return; fi
  _title="$(_sub_hdr "$_hdr" 'profile-title')"
  # Some providers base64-encode the title (Clash convention: "base64:<...>"); decode best-effort.
  case "$_title" in
    base64:*) _t2="$(printf '%s' "${_title#base64:}" | base64 -d 2>/dev/null)"; [ -n "$_t2" ] && _title="$_t2" ;;
  esac
  _uinfo="$(_sub_hdr "$_hdr" 'subscription-userinfo')"
  _ivl="$(_sub_hdr "$_hdr" 'profile-update-interval')"
  rm -f "$_hdr" "$_bdy"
  http_ok "$(jq -n --arg c "$_out" --arg t "$_title" --arg u "$_uinfo" --arg i "$_ivl" \
    '{ok:true,content:$c,title:$t,userinfo:$u,updateInterval:$i}')"
}
