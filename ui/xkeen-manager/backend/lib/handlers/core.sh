# get_core: active core + available cores.
get_core() {
  _v2="$(mktemp)"
  if ! migrate_state "$XKEEN_STATE_PATH" > "$_v2" 2>/dev/null; then
    http_error 500 internal_error "state file is unreadable"; rm -f "$_v2"; return
  fi
  _active="$(jq -r '.activeCore // "xray"' "$_v2")"
  http_ok "$(jq -n --arg a "$_active" '{ok:true, active:$a, available:["xray","mihomo"]}')"
  rm -f "$_v2"
}
# put_core: switch active core. mihomo not implemented yet -> 501.
put_core() {
  _body="$(mktemp)"; cat > "$_body"
  _core="$(jq -r '.core // empty' "$_body" 2>/dev/null)"; rm -f "$_body"
  case "$_core" in
    xray)
      _v2="$(mktemp)"
      if ! migrate_state "$XKEEN_STATE_PATH" > "$_v2" 2>/dev/null; then
        http_error 500 internal_error "cannot read current state"; rm -f "$_v2"; return
      fi
      _new="$(mktemp)"; jq '.activeCore="xray"' "$_v2" > "$_new"; cp "$_new" "$XKEEN_STATE_PATH"
      http_ok '{"ok":true,"active":"xray"}'; rm -f "$_v2" "$_new" ;;
    mihomo) http_error 501 not_implemented "mihomo core not implemented yet" ;;
    *) http_error 400 bad_request "core must be 'xray' or 'mihomo'" ;;
  esac
}
