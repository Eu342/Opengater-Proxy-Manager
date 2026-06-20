# route_request <METHOD> <PATH_INFO> -> prints a handler token.
# Pure function: no XKEEN_LIB_DIR / filesystem dependency.
route_request() {
  _m="$1"; _p="$2"
  case "$_p" in
    /v1/state)
      case "$_m" in GET) echo get_state ;; PUT) echo put_state ;; *) echo method_not_allowed ;; esac ;;
    /v1/apply)
      case "$_m" in POST) echo post_apply ;; *) echo method_not_allowed ;; esac ;;
    /v1/apply/*)
      case "$_m" in GET) echo get_apply_status ;; *) echo method_not_allowed ;; esac ;;
    /v1/config/outbounds|/v1/config/routing)
      case "$_m" in GET) echo get_config ;; *) echo method_not_allowed ;; esac ;;
    /v1/auth/login)   case "$_m" in POST) echo post_login ;;  *) echo method_not_allowed ;; esac ;;
    /v1/auth/logout)  case "$_m" in POST) echo post_logout ;; *) echo method_not_allowed ;; esac ;;
    /v1/auth/session) case "$_m" in GET)  echo get_session ;; *) echo method_not_allowed ;; esac ;;
    /v1/core)
      case "$_m" in GET) echo get_core ;; PUT) echo put_core ;; *) echo method_not_allowed ;; esac ;;
    /v1/health)  case "$_m" in GET) echo get_health ;; *) echo method_not_allowed ;; esac ;;
    /v1/stack)   case "$_m" in GET) echo get_stack ;;  *) echo method_not_allowed ;; esac ;;
    /v1/logs)    case "$_m" in GET) echo get_logs ;;   *) echo method_not_allowed ;; esac ;;
    /v1/probe)   case "$_m" in POST) echo post_probe ;; *) echo method_not_allowed ;; esac ;;
    /v1/probe/batch) case "$_m" in POST) echo post_probe_batch ;; *) echo method_not_allowed ;; esac ;;
    /v1/runtime/repair) case "$_m" in POST) echo post_repair ;; *) echo method_not_allowed ;; esac ;;
    /v1/vpn)
      case "$_m" in GET) echo get_vpn ;; PUT) echo put_vpn ;; *) echo method_not_allowed ;; esac ;;
    /v1/services/xray/loglevel)
      case "$_m" in GET) echo get_loglevel ;; PUT) echo put_loglevel ;; *) echo method_not_allowed ;; esac ;;
    /v1/services/*/restart) case "$_m" in POST) echo post_restart ;; *) echo method_not_allowed ;; esac ;;
    /v1/settings)
      case "$_m" in GET) echo get_settings ;; PUT) echo put_settings ;; *) echo method_not_allowed ;; esac ;;
    /v1/devices)
      case "$_m" in GET) echo get_devices ;; *) echo method_not_allowed ;; esac ;;
    /v1/devices/*/vpn)
      case "$_m" in POST) echo post_device_vpn ;; *) echo method_not_allowed ;; esac ;;
    /v1/subscription)
      case "$_m" in GET) echo get_subscription ;; PUT) echo put_subscription ;; *) echo method_not_allowed ;; esac ;;
    /v1/subscription/fetch)
      case "$_m" in POST) echo fetch_subscription ;; *) echo method_not_allowed ;; esac ;;
    /v1/update/check)
      case "$_m" in GET) echo get_update_check ;; *) echo method_not_allowed ;; esac ;;
    /v1/update/apply)
      case "$_m" in POST) echo post_update_apply ;; *) echo method_not_allowed ;; esac ;;
    /v1/update/status)
      case "$_m" in GET) echo get_update_status ;; *) echo method_not_allowed ;; esac ;;
    /v1/update/config)
      case "$_m" in GET) echo get_update_config ;; PUT) echo put_update_config ;; *) echo method_not_allowed ;; esac ;;
    /v1/subscription/*|/v1/cores/mihomo/*)
      echo stub_501 ;;
    *) echo not_found ;;
  esac
}
