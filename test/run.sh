#!/bin/sh
# Run every test/*_test.sh in its own subshell; aggregate exit status.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
RC=0
for t in "$DIR"/*_test.sh; do
  [ -f "$t" ] || continue
  printf '== %s ==\n' "$(basename "$t")"
  sh "$t" || RC=1
done
exit "$RC"
