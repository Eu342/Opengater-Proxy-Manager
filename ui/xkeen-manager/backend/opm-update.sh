#!/bin/sh
# Opengater Proxy Manager self-updater.
#
#   opm-update.sh check [--force]   live-check GitHub releases, write update-state.json
#   opm-update.sh apply <tag>       download+validate+atomic-swap+restart+health+rollback
#
# Scope: updates the UI (index.html) and backend (api/**) in place, preserving user
# data (subscription / state). Init scripts and packages are NOT touched here — those
# need a full install.sh run. The whole apply runs detached and survives the uhttpd
# restart; on any failure it rolls back to the previous version.
set -u

ROOT="${OPM_ROOT:-/opt/share/xkeen-manager}"
PORT="${OPM_UI_PORT:-8899}"
REPO_OWNER="${OPM_REPO_OWNER:-Eu342}"
REPO_NAME="${OPM_REPO_NAME:-Opengater-Proxy-Manager}"
API_LATEST="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"

VERSION_FILE="$ROOT/VERSION"
STATE="$ROOT/update-state.json"
STATUS="$ROOT/update-status.json"
LOCK="$ROOT/.update.lock"
CONFIG="$ROOT/update-config.json"
CURL="/opt/bin/curl"
JQ="/opt/bin/jq"

_now() { date +%s 2>/dev/null || echo 0; }
_cur_ver() { [ -f "$VERSION_FILE" ] && tr -d ' \t\r\n' < "$VERSION_FILE" || echo "0.0.0"; }
# check frequency in seconds (default 24h); 86400=daily, 604800=weekly, 2592000=monthly
_interval() {
  iv="$("$JQ" -r '.intervalSec // empty' "$CONFIG" 2>/dev/null)"
  case "$iv" in ''|*[!0-9]*) iv=86400 ;; esac
  [ "$iv" -ge 3600 ] 2>/dev/null || iv=86400
  echo "$iv"
}
_ver_norm() { printf '%s' "$1" | sed 's/^[vV]//' | sed 's/[^0-9.].*$//'; }
# _ver_gt A B -> 0 (true) if A > B, numeric major.minor.patch
_ver_gt() {
  _a="$(_ver_norm "$1")"; _b="$(_ver_norm "$2")"
  oIFS="$IFS"; IFS=.; set -- $_a; a1="${1:-0}"; a2="${2:-0}"; a3="${3:-0}"
  set -- $_b; b1="${1:-0}"; b2="${2:-0}"; b3="${3:-0}"; IFS="$oIFS"
  case "$a1$a2$a3$b1$b2$b3" in *[!0-9]*) return 1 ;; esac
  [ "$a1" -gt "$b1" ] && return 0; [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0; [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -gt "$b3" ] && return 0; return 1
}
_status() { # _status <state> <message> [version]
  "$JQ" -n --arg s "$1" --arg m "${2:-}" --arg v "${3:-}" --argjson t "$(_now)" \
    '{state:$s,message:$m,version:$v,at:$t}' > "$STATUS" 2>/dev/null || true
}

cmd_check() {
  force=0; [ "${1:-}" = "--force" ] && force=1
  # throttle: skip live call if cached state is fresh (<20h) unless forced
  if [ "$force" = 0 ] && [ -f "$STATE" ]; then
    ck="$("$JQ" -r '.checkedAt // 0' "$STATE" 2>/dev/null)"
    case "$ck" in ''|*[!0-9]*) ck=0 ;; esac
    age=$(( $(_now) - ck ))
    [ "$age" -ge 0 ] && [ "$age" -lt "$(_interval)" ] && { cat "$STATE"; return 0; }
  fi
  cur="$(_cur_ver)"
  body="$("$CURL" -s -L --max-time 20 -H 'Accept: application/vnd.github+json' \
           -H 'User-Agent: opengater-updater' "$API_LATEST" 2>/dev/null)"
  tag="$(printf '%s' "$body" | "$JQ" -r '.tag_name // empty' 2>/dev/null)"
  if [ -z "$tag" ]; then
    # no releases yet / API error -> report "up to date" without failing
    "$JQ" -n --arg c "$cur" --argjson t "$(_now)" --argjson iv "$(_interval)" \
      '{current:$c,latest:$c,updateAvailable:false,notes:"",htmlUrl:"",checkedAt:$t,intervalSec:$iv,error:"no release"}' \
      | tee "$STATE" 2>/dev/null
    return 0
  fi
  notes="$(printf '%s' "$body" | "$JQ" -r '.body // ""' 2>/dev/null)"
  url="$(printf '%s' "$body" | "$JQ" -r '.html_url // ""' 2>/dev/null)"
  pub="$(printf '%s' "$body" | "$JQ" -r '.published_at // ""' 2>/dev/null)"
  upd=false; _ver_gt "$tag" "$cur" && upd=true
  "$JQ" -n --arg c "$cur" --arg l "$(_ver_norm "$tag")" --arg tag "$tag" --argjson u "$upd" \
    --arg n "$notes" --arg url "$url" --arg pub "$pub" --argjson t "$(_now)" --argjson iv "$(_interval)" \
    '{current:$c,latest:$l,tag:$tag,updateAvailable:$u,notes:$n,htmlUrl:$url,publishedAt:$pub,checkedAt:$t,intervalSec:$iv}' \
    | tee "$STATE" 2>/dev/null
}

_health_ok() {
  i=0
  while [ "$i" -lt 12 ]; do
    sleep 1; i=$((i+1))
    code="$("$CURL" -s -o /tmp/opm-health.$$ -w '%{http_code}' --max-time 4 "http://127.0.0.1:$PORT/" 2>/dev/null)"
    if [ "$code" = "200" ] && grep -qi 'DOCTYPE\|<html' /tmp/opm-health.$$ 2>/dev/null; then
      acode="$("$CURL" -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:$PORT/api/api.cgi/v1/health" 2>/dev/null)"
      rm -f /tmp/opm-health.$$
      case "$acode" in 200|401) return 0 ;; esac   # CGI executed (401 = up, just unauthed)
    fi
  done
  rm -f /tmp/opm-health.$$ 2>/dev/null
  return 1
}

cmd_apply() {
  tag="${1:-}"
  # relocate out of $ROOT so the dir swap can't yank our own script file
  if [ "${OPM_UPD_RELOC:-0}" != 1 ]; then
    cp "$0" /tmp/opm-update-run.sh 2>/dev/null && chmod 755 /tmp/opm-update-run.sh 2>/dev/null
    OPM_UPD_RELOC=1 exec sh /tmp/opm-update-run.sh apply "$tag"
  fi
  [ -n "$tag" ] || { _status failed "no tag"; exit 1; }
  if [ -f "$LOCK" ]; then _status failed "another update is in progress"; exit 1; fi
  : > "$LOCK"
  trap 'rm -f "$LOCK"' EXIT

  W="/tmp/opm-upd.$$"; rm -rf "$W"; mkdir -p "$W" || { _status failed "tmp"; exit 1; }
  _status downloading "Downloading $tag"
  TARBALL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/tags/${tag}.tar.gz"
  if ! "$CURL" -s -L --max-time 120 -o "$W/src.tgz" "$TARBALL" 2>/dev/null || [ ! -s "$W/src.tgz" ]; then
    _status failed "download failed"; rm -rf "$W"; exit 1
  fi
  if ! /opt/bin/tar xzf "$W/src.tgz" -C "$W" 2>/dev/null; then
    _status failed "extract failed"; rm -rf "$W"; exit 1
  fi
  SRC="$(find "$W" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1)"
  [ -n "$SRC" ] || SRC="$(find "$W" -maxdepth 1 -type d ! -path "$W" | head -n1)"

  _status validating "Validating"
  B="$SRC/ui/xkeen-manager/backend"
  for need in "$SRC/ui-v2/index.html" "$B/api.cgi" "$B/lib/router.sh"; do
    [ -s "$need" ] || { _status failed "validation: missing $(basename "$need")"; rm -rf "$W"; exit 1; }
  done
  for sh in "$B/api.cgi" "$B"/lib/*.sh "$B"/lib/handlers/*.sh; do
    [ -f "$sh" ] || continue
    sh -n "$sh" 2>/dev/null || { _status failed "validation: syntax in $(basename "$sh")"; rm -rf "$W"; exit 1; }
  done

  _status installing "Installing"
  N="$ROOT.new"; rm -rf "$N"; mkdir -p "$N/api/lib/jq" "$N/api/lib/handlers" || { _status failed "stage"; rm -rf "$W"; exit 1; }
  cp "$SRC/ui-v2/index.html" "$N/index.html"
  [ -f "$SRC/ui-v2/preview/logo.png" ] && cp "$SRC/ui-v2/preview/logo.png" "$N/logo.png" 2>/dev/null
  cp "$B/api.cgi" "$B/xkeen-runtime.sh" "$B/xkeen-selfheal.sh" "$N/api/" 2>/dev/null
  [ -f "$B/opm-update.sh" ] && cp "$B/opm-update.sh" "$N/api/opm-update.sh"
  [ -f "$SRC/scripts/xkeen/opm-netfilter-hook.sh" ] && cp "$SRC/scripts/xkeen/opm-netfilter-hook.sh" "$N/api/opm-netfilter-hook.sh"
  cp "$B/lib/"*.sh "$N/api/lib/" 2>/dev/null
  cp "$B/lib/jq/"*.jq "$N/api/lib/jq/" 2>/dev/null
  cp "$B/lib/handlers/"*.sh "$N/api/lib/handlers/" 2>/dev/null
  printf '%s\n' "$(_ver_norm "$tag")" > "$N/VERSION"
  # carry user data forward (anything not shipped by the repo)
  for keep in xkeen-ui-state.json subscription.json update-state.json update-status.json logo.png httpd-auth.conf; do
    [ -f "$ROOT/$keep" ] && [ ! -f "$N/$keep" ] && cp "$ROOT/$keep" "$N/$keep" 2>/dev/null
  done
  chmod 755 "$N/api/api.cgi" "$N/api/xkeen-runtime.sh" "$N/api/xkeen-selfheal.sh" "$N/api/opm-update.sh" 2>/dev/null
  chmod 644 "$N/index.html" 2>/dev/null

  _status swapping "Applying"
  rm -rf "$ROOT.bak"
  if ! mv "$ROOT" "$ROOT.bak" || ! mv "$N" "$ROOT"; then
    # try to restore if half-swapped
    [ -d "$ROOT" ] || mv "$ROOT.bak" "$ROOT" 2>/dev/null
    _status failed "swap failed"; rm -rf "$W" "$N"; exit 1
  fi
  rm -rf "$W"

  _status restarting "Restarting"
  [ -x /opt/etc/init.d/S26opm ] && /opt/etc/init.d/S26opm restart >/dev/null 2>&1 || true

  if _health_ok; then
    _status done "Updated to $(_ver_norm "$tag")" "$(_ver_norm "$tag")"
    rm -rf "$ROOT.bak"
    exit 0
  fi

  # ---- rollback ----
  _status restarting "Update failed — rolling back"
  rm -rf "$ROOT.failed"; mv "$ROOT" "$ROOT.failed" 2>/dev/null
  mv "$ROOT.bak" "$ROOT" 2>/dev/null
  [ -x /opt/etc/init.d/S26opm ] && /opt/etc/init.d/S26opm restart >/dev/null 2>&1 || true
  if _health_ok; then
    _status failed "Update failed — previous version restored"
  else
    _status failed "Update failed and rollback unhealthy — run install.sh"
  fi
  exit 1
}

# OPM_UPD_LIB=1 sources just the functions (for tests) without dispatching.
[ "${OPM_UPD_LIB:-0}" = 1 ] || case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  apply) shift; cmd_apply "$@" ;;
  *) echo "usage: opm-update.sh {check [--force]|apply <tag>}" >&2; exit 2 ;;
esac
