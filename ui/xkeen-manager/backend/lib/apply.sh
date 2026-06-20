# apply.sh — apply pipeline orchestration.
# The CALLER sources state-migrate.sh, normalize.sh, validate.sh, gen-xray.sh first,
# then this file, then calls run_apply. Side effects are overridable for testing:
#   XKEEN_SELFTEST_CMD  (default: xray run -test -confdir "$XKEEN_XRAY_CONFDIR")
#   XKEEN_RESTART_CMD   (default: true)   — restart xray
#   XKEEN_RUNTIME_CMD   (default: true)   — rebuild iptables/ipset runtime
# Targets:
#   XKEEN_STATE_PATH    — where the committed state.json lives
#   XKEEN_XRAY_CONFDIR  — dir holding 04_outbounds.json / 05_routing.json
# NOTE: XKEEN_XRAY_CONFDIR and XKEEN_SELFTEST_CMD are operator install-time
# constants (never contain a double-quote); they are not request-derived.
# NOTE: a failed xray restart does NOT roll back — the committed config is valid
# (self-test passed); restartOk is reported and the self-heal watchdog recovers.
: "${XKEEN_LIB_DIR:?XKEEN_LIB_DIR must be set before sourcing apply.sh}"

_apply_job_write() {
  # <job-file> <status> <detail>
  jq -n --arg s "$2" --arg d "$3" '{status:$s, detail:$d}' > "$1"
}

# run_apply <input-state-file> <job-file>: exit 0 on success, 1 on failure.
run_apply() {
  _in="$1"; _job="$2"
  : "${XKEEN_STATE_PATH:?XKEEN_STATE_PATH must be set}"
  : "${XKEEN_XRAY_CONFDIR:?XKEEN_XRAY_CONFDIR must be set}"
  _selftest="${XKEEN_SELFTEST_CMD:-xray run -test -confdir \"$XKEEN_XRAY_CONFDIR\"}"
  _restart="${XKEEN_RESTART_CMD:-true}"
  _runtime="${XKEEN_RUNTIME_CMD:-true}"

  printf '{"status":"pending","detail":"applying"}\n' > "$_job" 2>/dev/null || true

  _tmpd="$(mktemp -d)"
  _mig="$_tmpd/migrated.json"
  _norm="$_tmpd/normalized.json"

  if ! migrate_state "$_in" > "$_mig" 2>"$_tmpd/merr"; then
    _apply_job_write "$_job" failed "migrate failed: $(tr '\n' ';' < "$_tmpd/merr")"
    rm -rf "$_tmpd"; return 1
  fi
  if ! normalize_state "$_mig" > "$_norm" 2>"$_tmpd/nerr"; then
    _apply_job_write "$_job" failed "normalize failed: $(tr '\n' ';' < "$_tmpd/nerr")"
    rm -rf "$_tmpd"; return 1
  fi
  if ! validate_state "$_norm" 2>"$_tmpd/verr"; then
    _apply_job_write "$_job" failed "validation failed: $(tr '\n' ';' < "$_tmpd/verr")"
    rm -rf "$_tmpd"; return 1
  fi

  _out="$XKEEN_XRAY_CONFDIR/04_outbounds.json"
  _rt="$XKEEN_XRAY_CONFDIR/05_routing.json"
  _bout="$_tmpd/04.bak"; _brt="$_tmpd/05.bak"; _bstate="$_tmpd/state.bak"
  _had_out=0; _had_rt=0; _had_state=0
  [ -f "$_out" ] && { cp "$_out" "$_bout"; _had_out=1; }
  [ -f "$_rt" ]  && { cp "$_rt"  "$_brt"; _had_rt=1; }
  [ -f "$XKEEN_STATE_PATH" ] && { cp "$XKEEN_STATE_PATH" "$_bstate"; _had_state=1; }

  if ! gen_xray_outbounds "$_norm" > "$_out" 2>/dev/null || ! gen_xray_routing "$_norm" > "$_rt" 2>/dev/null; then
    if [ "$_had_out" = 1 ]; then cp "$_bout" "$_out"; else rm -f "$_out"; fi
    if [ "$_had_rt" = 1 ];  then cp "$_brt"  "$_rt";  else rm -f "$_rt";  fi
    _apply_job_write "$_job" failed "config generation failed"; rm -rf "$_tmpd"; return 1
  fi

  if eval "$_selftest" >/dev/null 2>&1; then
    cp "$_norm" "$XKEEN_STATE_PATH"
    _restart_ok=true
    eval "$_restart" >/dev/null 2>&1 || _restart_ok=false
    eval "$_runtime" >/dev/null 2>&1 || true
    jq -n --arg s ok --arg d applied --argjson r "$_restart_ok" '{status:$s, detail:$d, restartOk:$r}' > "$_job"
    rm -rf "$_tmpd"; return 0
  else
    if [ "$_had_out" = 1 ]; then cp "$_bout" "$_out"; else rm -f "$_out"; fi
    if [ "$_had_rt" = 1 ];  then cp "$_brt"  "$_rt";  else rm -f "$_rt";  fi
    [ "$_had_state" = 1 ] && cp "$_bstate" "$XKEEN_STATE_PATH"
    _apply_job_write "$_job" failed "xray self-test failed, rolled back"
    rm -rf "$_tmpd"; return 1
  fi
}
