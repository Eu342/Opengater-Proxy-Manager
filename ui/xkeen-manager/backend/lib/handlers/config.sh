# get_config: emit the derived xray config named in PATH_INFO.
get_config() {
  case "$PATH_INFO" in
    */outbounds) _f="$XKEEN_XRAY_CONFDIR/04_outbounds.json" ;;
    */routing)   _f="$XKEEN_XRAY_CONFDIR/05_routing.json" ;;
    *) http_error 404 not_found "unknown config"; return ;;
  esac
  if [ -f "$_f" ]; then http_ok "$(cat "$_f")"; else http_error 404 not_found "config not generated yet"; fi
}
