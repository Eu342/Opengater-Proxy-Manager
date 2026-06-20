# normalize_state <state-file> -> prints normalized JSON (dedup/trim group lists, clamp mux).
# Mirrors the frontend's uniq()/normalizeMuxConfig so state-at-rest is clean for any client.
# Callers MUST export XKEEN_LIB_DIR before sourcing (see state-migrate.sh rationale).
: "${XKEEN_LIB_DIR:?XKEEN_LIB_DIR must be set before sourcing normalize.sh}"
normalize_state() {
  jq -f "$XKEEN_LIB_DIR/jq/normalize-state.jq" "$1"
}
