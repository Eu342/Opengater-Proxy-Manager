# Minimal POSIX-sh test helpers. Source this from *_test.sh files.
TESTS_RUN=0
TESTS_FAILED=0

_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

assert_eq() {
  # assert_eq <name> <expected> <actual>
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$2" = "$3" ]; then
    printf 'ok: %s\n' "$1"
  else
    _fail "$1"
    printf '  expected: %s\n  actual:   %s\n' "$2" "$3" >&2
  fi
}

assert_contains() {
  # assert_contains <name> <haystack> <needle>
  TESTS_RUN=$((TESTS_RUN + 1))
  case "$2" in
    *"$3"*) printf 'ok: %s\n' "$1" ;;
    *) _fail "$1"; printf '  string %s did not contain %s\n' "$2" "$3" >&2 ;;
  esac
}

assert_json_eq() {
  # assert_json_eq <name> <expected-file-or-string> <actual-string>
  # Compares JSON canonicalized with `jq -S` (key order ignored, array order kept).
  TESTS_RUN=$((TESTS_RUN + 1))
  _exp="$(mktemp)"; _act="$(mktemp)"
  if [ -f "$2" ]; then jq -S . "$2" > "$_exp"; else printf '%s' "$2" | jq -S . > "$_exp"; fi
  printf '%s' "$3" | jq -S . > "$_act"
  if diff -u "$_exp" "$_act" >/dev/null; then
    printf 'ok: %s\n' "$1"
  else
    _fail "$1"
    diff -u "$_exp" "$_act" >&2 || true
  fi
  rm -f "$_exp" "$_act"
}

test_summary() {
  printf '\n%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
