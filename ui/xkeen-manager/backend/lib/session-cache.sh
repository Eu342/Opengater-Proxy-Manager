# session-cache.sh — short-TTL cache of validated router sessions so health polling
# doesn't re-hit Keenetic /auth every request. Stores sha256(token) + expiry (never the
# raw cookie). Pure helper: no XKEEN_LIB_DIR dependency.
#   XKEEN_SESSION_CACHE  cache file (default /tmp/xkeen-session-cache)
#   XKEEN_NOW            overridable clock (default: date +%s)

_sc_now()  { if [ -n "${XKEEN_NOW:-}" ]; then printf '%s' "$XKEEN_NOW"; else date +%s; fi; }
_sc_file() { printf '%s' "${XKEEN_SESSION_CACHE:-/tmp/xkeen-session-cache}"; }
_sc_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | grep -oE '[0-9a-f]{64}' | head -n1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | grep -oE '[0-9a-f]{64}' | head -n1
  else
    printf '%s' "$1" | openssl dgst -sha256 | grep -oE '[0-9a-f]{64}' | head -n1
  fi
}
_sc_drop_hash() {
  _f="$(_sc_file)"; [ -f "$_f" ] || return 0
  _tmp="$_f.tmp.$$"
  if awk -v t="$1" '$1 != t' "$_f" > "$_tmp" 2>/dev/null; then mv "$_tmp" "$_f"; else rm -f "$_tmp"; fi
}

# session_cache_put <token> <ttl-seconds>
session_cache_put() {
  _h="$(_sc_hash "$1")"; _exp=$(( $(_sc_now) + $2 ))
  _sc_drop_hash "$_h"
  printf '%s %s\n' "$_h" "$_exp" >> "$(_sc_file)"
}

# session_cache_get <token>: exit 0 if cached and unexpired, else 1.
session_cache_get() {
  _h="$(_sc_hash "$1")"; _f="$(_sc_file)"; _now="$(_sc_now)"
  [ -f "$_f" ] || return 1
  _exp="$(awk -v t="$_h" '$1 == t { print $2; exit }' "$_f")"
  [ -n "$_exp" ] || return 1
  [ "$_now" -lt "$_exp" ]
}

# session_cache_drop <token>
session_cache_drop() { _sc_drop_hash "$(_sc_hash "$1")"; }
