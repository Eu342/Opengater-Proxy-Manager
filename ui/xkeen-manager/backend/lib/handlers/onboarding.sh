# Server-side first-run onboarding flag. Kept on the router (not in browser localStorage)
# so the wizard shows exactly once per install — opening the panel from a second device
# does not replay it. "Done" is written only when the user finishes the final step.

_OPM_ONB_FILE="${OPM_ONB_FILE:-/opt/share/xkeen-manager/onboarding.json}"

# GET /v1/onboarding -> {"done":bool}
get_onboarding() {
  if [ -f "$_OPM_ONB_FILE" ]; then
    http_ok "$(jq -c '{done:(.done==true)}' "$_OPM_ONB_FILE" 2>/dev/null || printf '{"done":false}')"
  else
    http_ok '{"done":false}'
  fi
}

# PUT /v1/onboarding  {done:bool} -> persist the flag (atomic write)
put_onboarding() {
  _b="$(cat)"
  _done="$(printf '%s' "$_b" | jq -r 'if .done==true then "true" else "false" end' 2>/dev/null)"
  [ "$_done" = "true" ] || _done=false
  _tmp="$_OPM_ONB_FILE.tmp.$$"
  if printf '{"done":%s}\n' "$_done" > "$_tmp" 2>/dev/null && mv "$_tmp" "$_OPM_ONB_FILE" 2>/dev/null; then
    http_ok "{\"done\":$_done}"
  else
    rm -f "$_tmp" 2>/dev/null
    http_error 500 write_failed "cannot write onboarding flag"
  fi
}
