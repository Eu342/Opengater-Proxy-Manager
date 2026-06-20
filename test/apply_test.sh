#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
XKEEN_LIB_DIR="$DIR/../ui/xkeen-manager/backend/lib"; export XKEEN_LIB_DIR
. "$XKEEN_LIB_DIR/state-migrate.sh"; . "$XKEEN_LIB_DIR/normalize.sh"
. "$XKEEN_LIB_DIR/validate.sh"; . "$XKEEN_LIB_DIR/gen-xray.sh"
. "$XKEEN_LIB_DIR/apply.sh"

WORK="$(mktemp -d)"
export XKEEN_STATE_PATH="$WORK/state.json"
export XKEEN_XRAY_CONFDIR="$WORK/xray"
mkdir -p "$XKEEN_XRAY_CONFDIR"
export XKEEN_SELFTEST_CMD="true"
export XKEEN_RESTART_CMD="true"
export XKEEN_RUNTIME_CMD="true"

JOB="$WORK/job.json"
run_apply "$DIR/fixtures/state-v1.json" "$JOB"
assert_eq "apply ok status" "ok" "$(jq -r .status "$JOB")"
assert_eq "restartOk true" "true" "$(jq -r .restartOk "$JOB")"
assert_eq "state written" "2" "$(jq -r .schemaVersion "$XKEEN_STATE_PATH")"
assert_eq "outbounds written" "vless-reality" "$(jq -r '.outbounds[0].tag' "$XKEEN_XRAY_CONFDIR/04_outbounds.json")"
assert_eq "routing written" "IPIfNonMatch" "$(jq -r '.routing.domainStrategy' "$XKEEN_XRAY_CONFDIR/05_routing.json")"

# Restart failure: config valid (self-test passed) so apply is still ok, restartOk=false.
# Deliberate: no rollback on restart failure; the self-heal watchdog recovers.
export XKEEN_RESTART_CMD="false"
run_apply "$DIR/fixtures/state-v1.json" "$JOB"
assert_eq "apply ok despite restart fail" "ok" "$(jq -r .status "$JOB")"
assert_eq "restartOk false" "false" "$(jq -r .restartOk "$JOB")"
export XKEEN_RESTART_CMD="true"

# Self-test failure: status failed, ALL artifacts rolled back.
cp "$XKEEN_XRAY_CONFDIR/05_routing.json"   "$WORK/prev_routing.json"
cp "$XKEEN_XRAY_CONFDIR/04_outbounds.json" "$WORK/prev_outbounds.json"
export XKEEN_SELFTEST_CMD="false"
run_apply "$DIR/fixtures/state-v1.json" "$JOB" || true
assert_eq "apply failed status" "failed" "$(jq -r .status "$JOB")"
assert_json_eq "routing rolled back"   "$WORK/prev_routing.json"   "$(cat "$XKEEN_XRAY_CONFDIR/05_routing.json")"
assert_json_eq "outbounds rolled back" "$WORK/prev_outbounds.json" "$(cat "$XKEEN_XRAY_CONFDIR/04_outbounds.json")"
assert_eq "state intact after rollback" "2" "$(jq -r .schemaVersion "$XKEEN_STATE_PATH")"

# Routing model in control: when routing.json exists AND a 05_routing.json is already
# present (owned by routing-apply / POST /v1/routing/apply), state-apply must NOT
# regenerate routing — only outbounds. Verified with a sentinel that gen_xray_routing
# would never produce.
export XKEEN_SELFTEST_CMD="true"
printf '{"mode":"rf-direct","rules":[]}\n' > "$WORK/routing.json"
export XKEEN_ROUTING_MODEL="$WORK/routing.json"
printf '{"routing":{"domainStrategy":"AsIs","_owner":"routing-apply"}}\n' > "$XKEEN_XRAY_CONFDIR/05_routing.json"
run_apply "$DIR/fixtures/state-v1.json" "$JOB"
assert_eq "apply ok with routing model" "ok" "$(jq -r .status "$JOB")"
assert_eq "routing preserved (not regenerated)" "routing-apply" "$(jq -r '.routing._owner' "$XKEEN_XRAY_CONFDIR/05_routing.json")"
assert_eq "outbounds still regenerated" "vless-reality" "$(jq -r '.outbounds[0].tag' "$XKEEN_XRAY_CONFDIR/04_outbounds.json")"
# Bootstrap: model present but routing file missing -> generate from STATE so xray
# always has a valid routing config.
rm -f "$XKEEN_XRAY_CONFDIR/05_routing.json"
run_apply "$DIR/fixtures/state-v1.json" "$JOB"
assert_eq "routing bootstrapped when missing" "IPIfNonMatch" "$(jq -r '.routing.domainStrategy' "$XKEEN_XRAY_CONFDIR/05_routing.json")"
unset XKEEN_ROUTING_MODEL

# Validation failure: state that won't validate -> failed, no crash.
BAD="$WORK/bad.json"; printf '{"profiles":[]}' > "$BAD"
export XKEEN_SELFTEST_CMD="true"
run_apply "$BAD" "$JOB" || true
assert_eq "invalid state -> failed" "failed" "$(jq -r .status "$JOB")"

rm -rf "$WORK"
test_summary
