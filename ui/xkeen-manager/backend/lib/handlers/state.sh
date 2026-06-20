# get_state: return current state as v2 JSON (migrated on read).
get_state() {
  [ -f "$XKEEN_STATE_PATH" ] || { http_error 404 not_found "no state file"; return; }
  _v2="$(mktemp)"
  if migrate_state "$XKEEN_STATE_PATH" > "$_v2" 2>/dev/null; then http_ok "$(cat "$_v2")"
  else http_error 500 internal_error "state file is unreadable"; fi
  rm -f "$_v2"
}
# put_state: validate + persist a posted state (no apply).
put_state() {
  _body="$(mktemp)"; cat > "$_body"
  _v2="$(mktemp)"
  if ! migrate_state "$_body" > "$_v2" 2>/dev/null; then
    http_error 400 invalid_json "body is not valid JSON"; rm -f "$_body" "$_v2"; return
  fi
  _norm="$(mktemp)"; normalize_state "$_v2" > "$_norm" 2>/dev/null || true
  if validate_state "$_norm" 2>/dev/null; then
    cp "$_norm" "$XKEEN_STATE_PATH"; http_ok '{"ok":true}'
  else
    http_error 400 invalid_state "state failed validation"
  fi
  rm -f "$_body" "$_v2" "$_norm"
}
