# routing.sh — routing rules model endpoints. Delegates to api/opm-routing.sh.
#   GET /v1/routing   -> {mode, rules}
#   PUT /v1/routing   -> persist a new model (validated); returns the stored model.
# (Generation into 05_routing.json + xray restart is applied separately.)
_OPM_ROUTING_SH="${OPM_ROOT:-/opt/share/xkeen-manager}/api/opm-routing.sh"

get_routing() { http_ok "$(sh "$_OPM_ROUTING_SH" get 2>/dev/null)"; }
put_routing() {
  _r="$(cat | sh "$_OPM_ROUTING_SH" set 2>/dev/null)"
  case "$_r" in
    *'"error"'*) http_error 400 routing_error "$(printf '%s' "$_r" | jq -r '.error // "routing error"' 2>/dev/null)" ;;
    '{'*) http_ok "$_r" ;;
    *) http_error 500 routing_failed "routing save failed" ;;
  esac
}
# POST /v1/routing/apply — regenerate 05_routing from the saved model + restart xray (rollback on failure)
post_routing_apply() {
  _r="$(sh "$_OPM_ROUTING_SH" apply 2>/dev/null)"
  case "$_r" in
    *'"error"'*) http_error 400 routing_apply_error "$(printf '%s' "$_r" | jq -r '.error // "apply failed"' 2>/dev/null)" ;;
    '{'*) http_ok "$_r" ;;
    *) http_error 500 routing_apply_failed "routing apply failed" ;;
  esac
}
