# http.sh — CGI response helpers. Pure (no XKEEN_LIB_DIR dependency); uses jq for JSON escaping.
http_headers() {
  # <status-line> [content-type]
  printf 'Status: %s\r\n' "$1"
  printf 'Content-Type: %s\r\n' "${2:-application/json; charset=utf-8}"
  printf 'Cache-Control: no-store\r\n'
  printf '\r\n'
}
http_json()     { http_headers "$1"; printf '%s\n' "$2"; }       # <status-line> <json>
http_ok()       { http_json '200 OK' "$1"; }
http_accepted() { http_json '202 Accepted' "$1"; }
http_error() {
  # <code> <error-token> <detail>
  case "$1" in
    400) _s='400 Bad Request' ;; 401) _s='401 Unauthorized' ;;
    403) _s='403 Forbidden' ;;
    404) _s='404 Not Found' ;;   405) _s='405 Method Not Allowed' ;;
    500) _s='500 Internal Server Error' ;; 501) _s='501 Not Implemented' ;;
    502) _s='502 Bad Gateway' ;;
    *)   _s="$1" ;;
  esac
  http_headers "$_s"
  jq -cn --arg e "$2" --arg d "$3" '{ok:false, error:$e, detail:$d}'
}
