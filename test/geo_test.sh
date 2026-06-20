#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
G="$DIR/../ui/xkeen-manager/backend/opm-geo.sh"

# Minimal geosite/geoip .dat = protobuf: repeated entry (field 1), entry.field1 = country_code.
# entry "ru":  0a 04 [0a 02 72 75]            (entryLen 4)
# entry "ads": 0a 05 [0a 03 61 64 73]         (entryLen 5)
F="$(mktemp)"
printf '\012\004\012\002\162\165\012\005\012\003\141\144\163' > "$F"
out="$(sh "$G" categories "$F" | tr '\n' ',')"
rm -f "$F"
assert_eq "parse categories" "ru,ads," "$out"

# multi-byte varint entry length: entryLen 130 (varint 82 01), cc "xy" + 126 filler bytes
B="$(mktemp)"
printf '\012\202\001\012\002\170\171' > "$B"
i=0; while [ "$i" -lt 126 ]; do printf '\000' >> "$B"; i=$((i+1)); done
out2="$(sh "$G" categories "$B" | tr '\n' ',')"
rm -f "$B"
assert_eq "multi-byte varint length" "xy," "$out2"

test_summary
