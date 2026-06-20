# gen_xray_outbounds <state-file> -> prints 04_outbounds.json content
# gen_xray_routing   <state-file> -> prints 05_routing.json content
# Callers MUST export XKEEN_LIB_DIR before sourcing (see state-migrate.sh rationale).
# These generators assume an ALREADY-VALIDATED state (run validate_state first);
# they fail loud (jq exit 5) on a malformed/incomplete config rather than guessing.
: "${XKEEN_LIB_DIR:?XKEEN_LIB_DIR must be set before sourcing gen-xray.sh}"
gen_xray_outbounds() { jq -f "$XKEEN_LIB_DIR/jq/xray-outbounds.jq" "$1"; }
gen_xray_routing()   { jq -f "$XKEEN_LIB_DIR/jq/xray-routing.jq" "$1"; }
