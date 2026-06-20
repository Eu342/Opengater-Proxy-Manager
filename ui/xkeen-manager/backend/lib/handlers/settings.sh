# get_settings: return state.settings.
get_settings() {
  _v2="$(mktemp)"
  if migrate_state "$XKEEN_STATE_PATH" > "$_v2" 2>/dev/null; then
    http_ok "$(jq -c '.settings // {ipv6Mode:"reject"}' "$_v2")"
  else http_error 500 internal_error "state file is unreadable"; fi
  rm -f "$_v2"
}
# put_settings: persist settings.ipv6Mode (no apply; runtime applies it separately).
put_settings() {
  _body="$(mktemp)"; cat > "$_body"
  _mode="$(jq -r '.ipv6Mode // empty' "$_body" 2>/dev/null)"
  case "$_mode" in
    reject|allow) : ;;
    *) http_error 400 invalid_settings "ipv6Mode must be 'reject' or 'allow'"; rm -f "$_body"; return ;;
  esac
  _v2="$(mktemp)"
  if ! migrate_state "$XKEEN_STATE_PATH" > "$_v2" 2>/dev/null; then
    http_error 500 internal_error "cannot read current state"; rm -f "$_body" "$_v2"; return
  fi
  _new="$(mktemp)"; jq --arg m "$_mode" '.settings = ((.settings // {}) + {ipv6Mode:$m})' "$_v2" > "$_new"
  cp "$_new" "$XKEEN_STATE_PATH"
  http_ok "$(jq -c '.settings' "$_new")"
  rm -f "$_body" "$_v2" "$_new"
}
