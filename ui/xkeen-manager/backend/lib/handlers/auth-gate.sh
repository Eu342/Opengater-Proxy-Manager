# api_require_auth: returns 0 if authed; else emits 401 and returns 1.
# XKEEN_AUTH_BYPASS=1 (server-side env only) bypasses for tests. Otherwise: session-cache
# fast path, then a real Keenetic /auth validation (cached on success). Empty cookie -> 401
# without any network call.
#
# The cache TTL is the panel's effective session lifetime: once a login is validated we
# trust it for XKEEN_SESSION_TTL (default 7d) instead of re-checking Keenetic every minute.
# Keenetic expires its own web session in ~5-10 min, so a short TTL logged the user out
# constantly; the panel deliberately outlives that (device/ndmc ops run as root, not via
# this cookie). Cache lives in /tmp, so a router reboot still forces a fresh login.
api_require_auth() {
  [ "${XKEEN_AUTH_BYPASS:-0}" = "1" ] && return 0
  _cookie="${HTTP_COOKIE:-}"
  if [ -n "$_cookie" ] && session_cache_get "$_cookie"; then return 0; fi
  if _api_keenetic_auth_ok "$_cookie"; then
    [ -n "$_cookie" ] && session_cache_put "$_cookie" "${XKEEN_SESSION_TTL:-604800}"
    return 0
  fi
  http_error 401 unauthorized "router session required"
  return 1
}
_api_keenetic_auth_ok() {
  _c="$1"; [ -n "$_c" ] || return 1
  # SERVER_ADDR is set by the server (the local IP the request arrived on), not by the
  # client, so it can't be spoofed via the Host header. wget sets Host from the URL host.
  _host="${SERVER_ADDR:-127.0.0.1}"
  wget -S -O - --header="Cookie: $_c" "http://$_host/auth" 2>&1 \
    | grep -q 'HTTP/1\.[01] 200'
}
