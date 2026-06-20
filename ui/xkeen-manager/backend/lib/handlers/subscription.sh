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
  printf '%s\n' "$_sb" > "$_OPM_SUB_FILE" 2>/dev/null || { http_error 500 write_failed "cannot write subscription"; return; }
  http_ok '{"ok":true}'
}

# POST /v1/subscription/fetch  {url}  -> fetch the subscription URL server-side
# with a client User-Agent (Happ), so the provider returns the config instead of
# its HTML page. Browsers can't set User-Agent, so the panel proxies via the router.
fetch_subscription() {
  _u="$(cat | jq -r '.url // empty' 2>/dev/null)"
  case "$_u" in http://*|https://*) : ;; *) http_error 400 bad_request "url must be http(s)"; return ;; esac
  _out="$(/opt/bin/curl -s -L --max-time 25 -A 'Happ' "$_u" 2>/dev/null)"
  [ -n "$_out" ] || { http_error 502 fetch_failed "empty response from provider"; return; }
  http_ok "$(jq -n --arg c "$_out" '{ok:true,content:$c}')"
}
