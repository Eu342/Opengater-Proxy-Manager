#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
# source just the functions (no dispatch)
OPM_UPD_LIB=1 . "$DIR/../ui/xkeen-manager/backend/opm-update.sh"

_gt() { if _ver_gt "$1" "$2"; then echo yes; else echo no; fi; }

assert_eq "1.2.0 > 1.1.9"      "yes" "$(_gt 1.2.0 1.1.9)"
assert_eq "1.0.1 > 1.0.0"      "yes" "$(_gt 1.0.1 1.0.0)"
assert_eq "2.0.0 > 1.9.9"      "yes" "$(_gt 2.0.0 1.9.9)"
assert_eq "v1.3.0 > 1.2.5"     "yes" "$(_gt v1.3.0 1.2.5)"
assert_eq "1.0.0 not > 1.0.0"  "no"  "$(_gt 1.0.0 1.0.0)"
assert_eq "1.0.0 not > 1.0.1"  "no"  "$(_gt 1.0.0 1.0.1)"
assert_eq "1.2.0 not > 1.10.0" "no"  "$(_gt 1.2.0 1.10.0)"
assert_eq "norm strips v+pre"  "1.4.2" "$(_ver_norm v1.4.2-beta1)"
assert_eq "missing VERSION->0" "0.0.0" "$(_cur_ver)"
test_summary
