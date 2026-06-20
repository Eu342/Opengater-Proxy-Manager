# post_login: validate router credentials via Keenetic digest auth; on success set + cache the session cookie.
# Targets SERVER_ADDR (server-set) not HTTP_HOST, so a spoofed Host can't redirect validation.
post_login() {
  _body="$(mktemp)"; cat > "$_body"
  _l64="$(jq -r '.loginB64 // empty' "$_body" 2>/dev/null)"
  _p64="$(jq -r '.passwordB64 // empty' "$_body" 2>/dev/null)"
  rm -f "$_body"
  if [ -z "$_l64" ] || [ -z "$_p64" ]; then http_error 400 invalid_login "loginB64 and passwordB64 required"; return; fi
  _login="$(printf '%s' "$_l64" | base64 -d 2>/dev/null)"
  _pass="$(printf '%s' "$_p64" | base64 -d 2>/dev/null)"
  if [ -z "$_login" ] || [ -z "$_pass" ]; then http_error 400 invalid_login "could not decode credentials"; return; fi
  _host="${SERVER_ADDR:-127.0.0.1}"
  _ch="$(wget -S -O - "http://$_host/auth" 2>&1)"
  _realm="$(printf '%s' "$_ch" | sed -n 's/.*realm="\([^"]*\)".*/\1/p' | head -n1)"
  _chal="$(printf '%s' "$_ch" | sed -n 's/.*challenge="\([^"]*\)".*/\1/p' | head -n1)"
  _sid="$(printf '%s' "$_ch" | sed -n 's/.*session_id="\([^"]*\)".*/\1/p' | head -n1)"
  _sck="$(printf '%s' "$_ch" | sed -n 's/.*session_cookie="\([^"]*\)".*/\1/p' | head -n1)"
  if [ -z "$_realm" ] || [ -z "$_chal" ] || [ -z "$_sid" ] || [ -z "$_sck" ]; then
    http_error 502 auth_upstream "could not read router auth challenge"; return
  fi
  _md5="$(printf '%s' "${_login}:${_realm}:${_pass}" | md5sum | awk '{print $1}')"
  _sha="$(printf '%s' "${_chal}${_md5}" | sha256sum | awk '{print $1}')"
  _payload="$(jq -nc --arg l "$_login" --arg p "$_sha" '{login:$l, password:$p}')"
  _res="$(wget -S -O - --header="Cookie: ${_sck}=${_sid}" --header="Content-Type: application/json; charset=utf-8" --post-data="$_payload" "http://$_host/auth" 2>&1)"
  if ! printf '%s' "$_res" | grep -q 'HTTP/1\.[01] 200'; then http_error 401 invalid_credentials "invalid router credentials"; return; fi
  _cookie="${_sck}=${_sid}"
  session_cache_put "$_cookie" 45
  printf 'Status: 200 OK\r\n'
  printf 'Content-Type: application/json; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n'
  printf 'Set-Cookie: %s; Path=/; SameSite=Strict; Max-Age=604800\r\n' "$_cookie"
  printf '\r\n'
  jq -nc --arg l "$_login" '{ok:true, login:$l}'
}
# post_logout: clear + drop the session.
post_logout() {
  _cookie="${HTTP_COOKIE:-}"
  [ -n "$_cookie" ] && session_cache_drop "$_cookie"
  _name="$(printf '%s' "$_cookie" | sed -n 's/^\([^=;[:space:]]*\)=.*/\1/p' | head -n1)"
  printf 'Status: 200 OK\r\n'
  printf 'Content-Type: application/json; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n'
  [ -n "$_name" ] && printf 'Set-Cookie: %s=; Path=/; SameSite=Strict; Max-Age=0\r\n' "$_name"
  printf '\r\n'
  printf '{"ok":true}\n'
}
# get_session: report whether the caller currently has a valid router session.
# On a cache miss it live-validates and then caches (45s), so repeated status polls
# don't hit the router. (45s is a re-validation cadence, not the session lifetime.)
get_session() {
  _cookie="${HTTP_COOKIE:-}"
  if [ -n "$_cookie" ] && { session_cache_get "$_cookie" || { _api_keenetic_auth_ok "$_cookie" && session_cache_put "$_cookie" 45; }; }; then
    http_ok '{"ok":true,"authenticated":true}'
  else
    http_ok '{"ok":true,"authenticated":false}'
  fi
}
