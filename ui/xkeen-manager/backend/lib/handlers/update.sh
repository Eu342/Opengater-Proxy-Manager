# update.sh — self-update endpoints (delegates to api/opm-update.sh).
#   GET  /v1/update/check[?force=1]  -> cached/live release check {current,latest,updateAvailable,notes,...}
#   POST /v1/update/apply  {tag?}     -> spawn detached updater; {started:true}
#   GET  /v1/update/status            -> {state,message,version,at}
_OPM_ROOT="${OPM_ROOT:-/opt/share/xkeen-manager}"
_OPM_UPD="$_OPM_ROOT/api/opm-update.sh"
_OPM_UPD_STATE="$_OPM_ROOT/update-state.json"
_OPM_UPD_STATUS="$_OPM_ROOT/update-status.json"

get_update_check() {
  _force=""; [ "$(parse_qs_param force)" = "1" ] && _force="--force"
  _out=""
  [ -f "$_OPM_UPD" ] && _out="$(sh "$_OPM_UPD" check $_force 2>/dev/null)"
  case "$_out" in
    '{'*) http_ok "$_out" ;;
    *) if [ -f "$_OPM_UPD_STATE" ]; then http_ok "$(cat "$_OPM_UPD_STATE")";
       else http_ok "$(jq -n '{current:"0.0.0",latest:"0.0.0",updateAvailable:false,error:"unavailable"}')"; fi ;;
  esac
}

post_update_apply() {
  _body="$(cat)"
  _tag="$(printf '%s' "$_body" | jq -r '.tag // empty' 2>/dev/null)"
  [ -n "$_tag" ] || _tag="$(jq -r '.tag // empty' "$_OPM_UPD_STATE" 2>/dev/null)"
  [ -n "$_tag" ] && [ "$_tag" != "null" ] || { http_error 400 no_tag "no target version (run check first)"; return; }
  [ -f "$_OPM_UPD" ] || { http_error 500 no_updater "updater not installed"; return; }
  jq -n --arg s starting '{state:$s,message:"Starting update",at:0}' > "$_OPM_UPD_STATUS" 2>/dev/null || true
  # Detach the updater so it survives this CGI exit AND the uhttpd restart it triggers.
  # No nohup on busybox: a subshell-backgrounded job with redirected std streams is
  # reparented to init and won't hold the CGI's stdout pipe open (uhttpd won't wait).
  ( sh "$_OPM_UPD" apply "$_tag" >/opt/var/log/opm-update.log 2>&1 </dev/null & )
  http_ok "$(jq -n --arg t "$_tag" '{ok:true,started:true,tag:$t}')"
}

get_update_status() {
  if [ -f "$_OPM_UPD_STATUS" ]; then http_ok "$(cat "$_OPM_UPD_STATUS")"; else http_ok '{"state":"idle"}'; fi
}

get_update_config() {
  if [ -f "$_OPM_ROOT/update-config.json" ]; then http_ok "$(cat "$_OPM_ROOT/update-config.json")"; else http_ok '{"intervalSec":86400}'; fi
}
# check frequency: 86400 (daily) | 604800 (weekly) | 2592000 (monthly)
put_update_config() {
  _iv="$(cat | jq -r '.intervalSec // empty' 2>/dev/null)"
  case "$_iv" in 86400|604800|2592000) : ;; *) http_error 400 bad_interval "intervalSec must be 86400, 604800 or 2592000"; return ;; esac
  jq -n --argjson iv "$_iv" '{intervalSec:$iv}' > "$_OPM_ROOT/update-config.json" 2>/dev/null
  http_ok "$(jq -n --argjson iv "$_iv" '{ok:true,intervalSec:$iv}')"
}
