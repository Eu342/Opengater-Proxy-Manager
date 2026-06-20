# _apply_new_id: alphanumeric job id, unique per request. epoch + pid is reliable on both
# busybox and coreutils (mktemp -u is NOT — it returned the literal template on macOS and is
# missing on some busybox builds, yielding an empty id). Each CGI call is its own process,
# so $$ disambiguates within the same second.
_apply_new_id() {
  printf 'j%s%s' "$(date +%s 2>/dev/null || echo 0)" "$$"
}
# post_apply: accept a posted state, run the apply pipeline (async), return 202 + jobId.
post_apply() {
  _id="$(_apply_new_id)"
  _in="/tmp/xkeen-apply-${_id}.in.json"
  _job="/tmp/xkeen-apply-${_id}.json"
  cat > "$_in"
  printf '{"status":"pending","detail":"queued"}\n' > "$_job"
  if [ "${XKEEN_APPLY_SYNC:-0}" = "1" ]; then
    run_apply "$_in" "$_job" >/dev/null 2>&1 || true; rm -f "$_in"
  else
    ( run_apply "$_in" "$_job" >/dev/null 2>&1; rm -f "$_in" ) &
  fi
  http_accepted "$(jq -n --arg id "$_id" '{ok:true, jobId:$id}')"
}
# get_apply_status: read the job file for the id in PATH_INFO (/v1/apply/<id>).
# Strict alphanumeric charset matches the generated id space and blocks any path component.
get_apply_status() {
  _id="${PATH_INFO##*/}"
  case "$_id" in ''|*[!A-Za-z0-9]*) http_error 400 bad_request "invalid job id"; return ;; esac
  _job="/tmp/xkeen-apply-${_id}.json"
  if [ -f "$_job" ]; then http_ok "$(cat "$_job")"; else http_error 404 not_found "no such job"; fi
}
