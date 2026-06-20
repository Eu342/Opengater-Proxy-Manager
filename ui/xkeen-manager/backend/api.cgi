#!/bin/sh
PATH="/opt/bin:/opt/sbin:/sbin:/usr/sbin:/bin:/usr/bin:$PATH"
XKEEN_LIB_DIR="${XKEEN_LIB_DIR:-/opt/share/xkeen-manager/api/lib}"
export XKEEN_LIB_DIR
: "${XKEEN_STATE_PATH:=/opt/share/xkeen-manager/xkeen-ui-state.json}"
: "${XKEEN_XRAY_CONFDIR:=/opt/etc/xray/configs}"
export XKEEN_STATE_PATH XKEEN_XRAY_CONFDIR

. "$XKEEN_LIB_DIR/http.sh"
. "$XKEEN_LIB_DIR/router.sh"
. "$XKEEN_LIB_DIR/session-cache.sh"
. "$XKEEN_LIB_DIR/state-migrate.sh"
. "$XKEEN_LIB_DIR/normalize.sh"
. "$XKEEN_LIB_DIR/validate.sh"
. "$XKEEN_LIB_DIR/gen-xray.sh"
. "$XKEEN_LIB_DIR/apply.sh"
[ -f "$XKEEN_LIB_DIR/router-actions.sh" ] && . "$XKEEN_LIB_DIR/router-actions.sh"
for _h in "$XKEEN_LIB_DIR"/handlers/*.sh; do [ -f "$_h" ] && . "$_h"; done

# Real apply side effects (off-router/tests override these env vars with `true`).
: "${XKEEN_SELFTEST_CMD:=/opt/sbin/xray run -test -confdir $XKEEN_XRAY_CONFDIR}"
command -v opm_restart_xray >/dev/null 2>&1 && : "${XKEEN_RESTART_CMD:=opm_restart_xray}"
command -v opm_apply_runtime >/dev/null 2>&1 && : "${XKEEN_RUNTIME_CMD:=opm_apply_runtime}"
export XKEEN_SELFTEST_CMD XKEEN_RESTART_CMD XKEEN_RUNTIME_CMD

METHOD="${REQUEST_METHOD:-GET}"
PINFO="${PATH_INFO:-}"
HANDLER="$(route_request "$METHOD" "$PINFO")"

case "$HANDLER" in
  not_found)          http_error 404 not_found "no such route";        exit 0 ;;
  method_not_allowed) http_error 405 method_not_allowed "method not allowed"; exit 0 ;;
esac

# Auth gate: auth/* handlers manage their own session; everything else requires one.
case "$HANDLER" in
  post_login|post_logout|get_session) : ;;
  *) api_require_auth || exit 0 ;;
esac

# Dispatch. Handlers are defined in lib/handlers/*.sh (added in later parts).
if command -v "$HANDLER" >/dev/null 2>&1; then
  "$HANDLER"
else
  http_error 501 not_implemented "handler $HANDLER not wired yet"
fi
exit 0
