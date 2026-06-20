# validate_state <state-file>: exit 0 if valid; else print errors to stderr, exit 1.
# Callers MUST export XKEEN_LIB_DIR before sourcing (see state-migrate.sh rationale).
: "${XKEEN_LIB_DIR:?XKEEN_LIB_DIR must be set before sourcing validate.sh}"
validate_state() {
  _errs="$(jq -c -f "$XKEEN_LIB_DIR/jq/validate-state.jq" "$1" 2>/dev/null)" || true
  if [ -z "$_errs" ]; then
    printf 'validation error: state is not valid JSON\n' >&2
    return 1
  fi
  _n="$(printf '%s' "$_errs" | jq 'length')"
  if [ "$_n" -eq 0 ]; then
    return 0
  fi
  printf '%s' "$_errs" | jq -r '.[]' >&2
  return 1
}
