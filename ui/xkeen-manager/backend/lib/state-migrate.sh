# migrate_state <state-file> -> prints migrated JSON to stdout
# Callers MUST export XKEEN_LIB_DIR (path to this lib directory) before sourcing:
# under plain POSIX sh a sourced file cannot determine its own path. The CGI and
# self-heal set it on the router; tests set it before sourcing.
: "${XKEEN_LIB_DIR:?XKEEN_LIB_DIR must be set before sourcing state-migrate.sh}"
migrate_state() {
  jq -f "$XKEEN_LIB_DIR/jq/state-migrate.jq" "$1"
}
