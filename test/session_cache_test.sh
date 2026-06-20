#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
. "$DIR/../ui/xkeen-manager/backend/lib/session-cache.sh"

WORK="$(mktemp -d)"
export XKEEN_SESSION_CACHE="$WORK/cache"
TOKEN="cookie=abc123xyz"

export XKEEN_NOW=1000
session_cache_put "$TOKEN" 60          # expiry 1060

export XKEEN_NOW=1030
if session_cache_get "$TOKEN"; then assert_eq "hit before expiry" 0 0; else assert_eq "hit before expiry" 0 1; fi

export XKEEN_NOW=1100
if session_cache_get "$TOKEN"; then assert_eq "miss after expiry" 1 0; else assert_eq "miss after expiry" 1 1; fi

export XKEEN_NOW=1030
if session_cache_get "other-token"; then assert_eq "unknown token miss" 1 0; else assert_eq "unknown token miss" 1 1; fi

session_cache_put "$TOKEN" 60
session_cache_drop "$TOKEN"
if session_cache_get "$TOKEN"; then assert_eq "miss after drop" 1 0; else assert_eq "miss after drop" 1 1; fi

session_cache_put "$TOKEN" 60
if grep -q "abc123xyz" "$XKEEN_SESSION_CACHE"; then assert_eq "raw token not stored" absent present; else assert_eq "raw token not stored" absent absent; fi

# put replaces (no duplicate lines for the same token)
session_cache_put "$TOKEN" 60
session_cache_put "$TOKEN" 60
assert_eq "single entry per token" 1 "$(wc -l < "$XKEEN_SESSION_CACHE" | tr -d ' ')"

rm -rf "$WORK"
test_summary
