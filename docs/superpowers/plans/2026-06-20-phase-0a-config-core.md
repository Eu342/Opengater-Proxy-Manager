# Phase 0a — Server-Side Config Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move xray config derivation from the browser to the router as pure `sh`+`jq`, driven by a core-namespaced (`schemaVersion: 2`) `state.json`, proven byte-equivalent to the current frontend output.

**Architecture:** Three sourced shell libraries (migrate, validate, generate) plus jq programs, with a dependency-light POSIX-sh test harness. State migration lifts the old flat profile shape into `cores.xray.*`; validation checks structural shape; the generator emits `04_outbounds.json` / `05_routing.json`. A golden-parity test guarantees the generator reproduces what `app.js` produces.

**Tech Stack:** POSIX `sh` (busybox ash on the router), `jq`. Dev-machine prerequisites: `jq` (`brew install jq`) and `sh`. No build step, no Node, no external test framework.

---

## File Structure

- Create: `ui/xkeen-manager/backend/lib/state-migrate.sh` — `migrate_state` (v1 flat → v2 core-namespaced), idempotent.
- Create: `ui/xkeen-manager/backend/lib/validate.sh` — `validate_state` (structural shape checks).
- Create: `ui/xkeen-manager/backend/lib/gen-xray.sh` — `gen_xray_outbounds`, `gen_xray_routing`.
- Create: `ui/xkeen-manager/backend/lib/jq/state-migrate.jq`
- Create: `ui/xkeen-manager/backend/lib/jq/validate-state.jq`
- Create: `ui/xkeen-manager/backend/lib/jq/xray-outbounds.jq`
- Create: `ui/xkeen-manager/backend/lib/jq/xray-routing.jq`
- Create: `test/lib.sh` — assertion helpers (`assert_json_eq`, `assert_eq`, `assert_contains`).
- Create: `test/run.sh` — runs every `test/*_test.sh`.
- Create: `test/fixtures/state-v1.json`, `test/fixtures/state-v2.json`, `test/fixtures/state-xhttp.json`
- Create: `test/golden/outbounds-v2.json`, `test/golden/routing-v2.json`, `test/golden/outbounds-xhttp.json`
- Create: `test/migrate_test.sh`, `test/validate_test.sh`, `test/gen_xray_test.sh`

Note: jq invoked by name (PATH-resolved). On the router the existing `PATH="/opt/bin:..."` makes that `/opt/bin/jq`.

---

## Task 1: Test harness

**Files:**
- Create: `test/lib.sh`
- Create: `test/run.sh`

- [ ] **Step 1: Write the assertion library**

`test/lib.sh`:

```sh
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
```

- [ ] **Step 2: Write the runner**

`test/run.sh`:

```sh
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
```

- [ ] **Step 3: Make the runner executable and run it (no tests yet)**

Run: `chmod +x test/run.sh && sh test/run.sh`
Expected: prints nothing but the loop body is skipped (no `*_test.sh` yet); exit 0.

- [ ] **Step 4: Commit**

```bash
git add test/lib.sh test/run.sh
git commit -m "test: add POSIX-sh test harness for backend libs"
```

---

## Task 2: State migration (v1 flat → v2 core-namespaced)

**Files:**
- Create: `ui/xkeen-manager/backend/lib/jq/state-migrate.jq`
- Create: `ui/xkeen-manager/backend/lib/state-migrate.sh`
- Create: `test/fixtures/state-v1.json`
- Test: `test/migrate_test.sh`

- [ ] **Step 1: Write the v1 fixture (current sample shape)**

`test/fixtures/state-v1.json`:

```json
{
  "activeProfileId": "profile-1",
  "profiles": [
    {
      "id": "profile-1",
      "name": "Profile 1",
      "domainStrategy": "IPIfNonMatch",
      "fallbackOutbound": "direct",
      "proxyConfig": {
        "address": "vpn.example.com", "port": 443,
        "uuid": "00000000-0000-0000-0000-000000000000",
        "flow": "xtls-rprx-vision", "publicKey": "PUBKEY",
        "serverName": "www.cloudflare.com", "shortId": "0123456789abcdef",
        "fingerprint": "random"
      },
      "muxConfig": { "mode": "off", "tcpConcurrency": 8, "xudpConcurrency": 8, "xudpProxyUDP443": "reject" },
      "groups": [
        { "id": "g-ai", "name": "AI", "note": "", "enabled": true, "outboundTag": "vless-reality",
          "domains": ["chatgpt.com", "claude.ai"], "cidrs": ["1.2.3.0/24"] },
        { "id": "g-bypass", "name": "Bypass", "note": "", "enabled": true, "outboundTag": "bypass",
          "domains": [], "cidrs": [] }
      ]
    }
  ]
}
```

- [ ] **Step 2: Write the failing migration test**

`test/migrate_test.sh`:

```sh
#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
XKEEN_LIB_DIR="$DIR/../ui/xkeen-manager/backend/lib"; export XKEEN_LIB_DIR
. "$XKEEN_LIB_DIR/state-migrate.sh"

OUT="$(migrate_state "$DIR/fixtures/state-v1.json")"

assert_eq "schemaVersion set to 2" "2" "$(printf '%s' "$OUT" | jq -r '.schemaVersion')"
assert_eq "activeCore defaults to xray" "xray" "$(printf '%s' "$OUT" | jq -r '.activeCore')"
assert_eq "xray proxyConfig lifted" "vpn.example.com" \
  "$(printf '%s' "$OUT" | jq -r '.profiles[0].cores.xray.proxyConfig.address')"
assert_eq "xray groups lifted" "AI" \
  "$(printf '%s' "$OUT" | jq -r '.profiles[0].cores.xray.groups[0].name')"
assert_eq "mihomo namespace created" "reality" \
  "$(printf '%s' "$OUT" | jq -r '.profiles[0].cores.mihomo.proxyConfig.transport')"
assert_eq "ipv6Mode default" "reject" \
  "$(printf '%s' "$OUT" | jq -r '.settings.ipv6Mode')"

# Idempotency: migrating the migrated state changes nothing.
TMP="$(mktemp)"; printf '%s' "$OUT" > "$TMP"
OUT2="$(migrate_state "$TMP")"
assert_json_eq "migration is idempotent" "$OUT" "$OUT2"
rm -f "$TMP"

test_summary
```

- [ ] **Step 3: Run it to verify it fails**

Run: `sh test/migrate_test.sh`
Expected: FAIL — `state-migrate.sh` not found / `migrate_state: not found`.

- [ ] **Step 4: Write the migration jq**

`ui/xkeen-manager/backend/lib/jq/state-migrate.jq`:

```jq
if (.schemaVersion // 0) >= 2 then .
else
  {
    schemaVersion: 2,
    activeCore: "xray",
    activeProfileId: .activeProfileId,
    settings: (.settings // { ipv6Mode: "reject" }),
    profiles: ( (.profiles // []) | map(
      {
        id: .id,
        name: .name,
        cores: {
          xray: {
            proxyConfig: .proxyConfig,
            muxConfig: .muxConfig,
            domainStrategy: (.domainStrategy // "IPIfNonMatch"),
            fallbackOutbound: (.fallbackOutbound // "direct"),
            groups: (.groups // [])
          },
          mihomo: { proxyConfig: { transport: "reality" }, rules: [], proxyGroups: [] }
        }
      }
    ))
  }
end
```

- [ ] **Step 5: Write the migration shell wrapper**

`ui/xkeen-manager/backend/lib/state-migrate.sh`:

`ui/xkeen-manager/backend/lib/state-migrate.sh`:

```sh
# migrate_state <state-file> -> prints migrated JSON to stdout
# Callers MUST export XKEEN_LIB_DIR (path to this lib directory) before sourcing:
# under plain POSIX sh a sourced file cannot determine its own path. The CGI and
# self-heal set it on the router; tests set it before sourcing.
: "${XKEEN_LIB_DIR:?XKEEN_LIB_DIR must be set before sourcing state-migrate.sh}"
migrate_state() {
  jq -f "$XKEEN_LIB_DIR/jq/state-migrate.jq" "$1"
}
```

The test (Step 2) exports `XKEEN_LIB_DIR` before sourcing, so the `:?` guard is satisfied. We do NOT
auto-detect the directory (`dirname --` and `$BASH_SOURCE` are unreliable under busybox `ash`); the
contract is that the caller sets `XKEEN_LIB_DIR`, and the guard fails loudly otherwise.

- [ ] **Step 6: Run the test to verify it passes**

Run: `sh test/migrate_test.sh`
Expected: all `ok:` lines, `0 failed`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add ui/xkeen-manager/backend/lib/jq/state-migrate.jq ui/xkeen-manager/backend/lib/state-migrate.sh test/fixtures/state-v1.json test/migrate_test.sh
git commit -m "feat: state schema v2 migration (flat -> core-namespaced)"
```

---

## Task 3: Structural state validation

**Files:**
- Create: `ui/xkeen-manager/backend/lib/jq/validate-state.jq`
- Create: `ui/xkeen-manager/backend/lib/validate.sh`
- Test: `test/validate_test.sh`

Validation here is **structural shape only** (used by `PUT /state`). Apply-readiness checks
(port numeric, uuid present) belong to the apply pipeline in Plan 0b.

- [ ] **Step 1: Write the failing validation test**

`test/validate_test.sh`:

```sh
#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
XKEEN_LIB_DIR="$DIR/../ui/xkeen-manager/backend/lib"; export XKEEN_LIB_DIR
. "$XKEEN_LIB_DIR/state-migrate.sh"
. "$XKEEN_LIB_DIR/validate.sh"

# A valid v2 state (migrate the v1 fixture).
VALID="$(migrate_state "$DIR/fixtures/state-v1.json")"
TMP="$(mktemp)"; printf '%s' "$VALID" > "$TMP"
if validate_state "$TMP" >/dev/null 2>&1; then assert_eq "valid state passes" "0" "0"; else assert_eq "valid state passes" "0" "1"; fi
rm -f "$TMP"

# Bad activeCore.
BAD="$(printf '%s' "$VALID" | jq '.activeCore="nope"')"
T2="$(mktemp)"; printf '%s' "$BAD" > "$T2"
ERR="$(validate_state "$T2" 2>&1 || true)"
assert_contains "bad activeCore reported" "$ERR" "activeCore"
rm -f "$T2"

# Bad outboundTag.
BAD2="$(printf '%s' "$VALID" | jq '.profiles[0].cores.xray.groups[0].outboundTag="weird"')"
T3="$(mktemp)"; printf '%s' "$BAD2" > "$T3"
ERR2="$(validate_state "$T3" 2>&1 || true)"
assert_contains "bad outboundTag reported" "$ERR2" "outboundTag"
rm -f "$T3"

# Empty profiles.
BAD3="$(printf '%s' "$VALID" | jq '.profiles=[]')"
T4="$(mktemp)"; printf '%s' "$BAD3" > "$T4"
ERR3="$(validate_state "$T4" 2>&1 || true)"
assert_contains "empty profiles reported" "$ERR3" "profiles"
rm -f "$T4"

# Not valid JSON at all.
T5="$(mktemp)"; printf 'not json' > "$T5"
ERR4="$(validate_state "$T5" 2>&1 || true)"
assert_contains "non-JSON file rejected" "$ERR4" "not valid JSON"
rm -f "$T5"

test_summary
```

This suite is run under both `sh` and `dash` (`dash test/validate_test.sh`) to catch
`set -eu` divergences that macOS bash would mask.

- [ ] **Step 2: Run it to verify it fails**

Run: `sh test/validate_test.sh`
Expected: FAIL — `validate.sh` / `validate_state` not found.

- [ ] **Step 3: Write the validation jq (emits an array of error strings)**

`ui/xkeen-manager/backend/lib/jq/validate-state.jq`:

```jq
.activeProfileId as $aid |
[
  (if (.schemaVersion // 0) == 2 then empty else "schemaVersion must be 2" end),
  ( (.activeCore // "") as $c
    | if ($c == "xray" or $c == "mihomo") then empty
      else "activeCore must be 'xray' or 'mihomo'" end ),
  ( if ((.profiles | type) == "array") and ((.profiles | length) > 0) then empty
    else "profiles must be a non-empty array" end ),
  ( if ((.profiles | type) == "array")
       and (([.profiles[].id] | index($aid)) != null) then empty
    else "activeProfileId must reference an existing profile" end ),
  # "direct" is allowed here though the routing generator treats it like bypass (no rule emitted).
  ( .profiles[]? | .id as $pid
    | (.cores.xray.groups // [])[]?
    | (.outboundTag // "") as $t
    | if (["vless-reality","direct","bypass"] | index($t)) != null then empty
      else "profile \($pid): group has invalid outboundTag '\($t)'" end )
]
```

Note: `.activeProfileId` is bound to `$aid` at the top because inside `index(...)` the filter is
evaluated against the piped array, not the root object — referencing `.activeProfileId` there would
error.

- [ ] **Step 4: Write the validation shell wrapper**

`ui/xkeen-manager/backend/lib/validate.sh`:

```sh
# validate_state <state-file>: exit 0 if valid; else print errors to stderr, exit 1.
# Callers MUST export XKEEN_LIB_DIR before sourcing (see state-migrate.sh rationale).
: "${XKEEN_LIB_DIR:?XKEEN_LIB_DIR must be set before sourcing validate.sh}"
validate_state() {
  # `|| true` so a jq parse failure (non-JSON input) doesn't abort the caller under
  # `set -eu` on dash/busybox-ash before we print the message below.
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `sh test/validate_test.sh`
Expected: all `ok:`, `0 failed`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add ui/xkeen-manager/backend/lib/jq/validate-state.jq ui/xkeen-manager/backend/lib/validate.sh test/validate_test.sh
git commit -m "feat: structural validation for v2 state"
```

---

## Task 4: xray outbounds generator (Reality) + golden parity

**Files:**
- Create: `ui/xkeen-manager/backend/lib/jq/xray-outbounds.jq`
- Create: `ui/xkeen-manager/backend/lib/gen-xray.sh`
- Create: `test/fixtures/state-v2.json`
- Create: `test/golden/outbounds-v2.json`
- Test: `test/gen_xray_test.sh`

The golden file encodes exactly what `app.js` `buildOutboundsDocument` produces for the fixture
(vless-reality outbound + freedom direct; mux `off` → `{enabled:false}`).

- [ ] **Step 1: Write the v2 fixture**

`test/fixtures/state-v2.json` — produce it from the v1 fixture so it stays in sync:

Run: `XKEEN_LIB_DIR=ui/xkeen-manager/backend/lib sh -c '. "$XKEEN_LIB_DIR/state-migrate.sh"; migrate_state test/fixtures/state-v1.json' > test/fixtures/state-v2.json`

Expected: a v2 state file. Inspect with `jq .schemaVersion test/fixtures/state-v2.json` → `2`.

- [ ] **Step 2: Write the outbounds golden**

`test/golden/outbounds-v2.json`:

```json
{
  "outbounds": [
    {
      "tag": "vless-reality",
      "protocol": "vless",
      "settings": {
        "vnext": [
          { "address": "vpn.example.com", "port": 443,
            "users": [ { "id": "00000000-0000-0000-0000-000000000000", "encryption": "none", "flow": "xtls-rprx-vision", "level": 0 } ] }
        ]
      },
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": { "publicKey": "PUBKEY", "fingerprint": "random", "serverName": "www.cloudflare.com", "shortId": "0123456789abcdef", "spiderX": "/" }
      },
      "mux": { "enabled": false }
    },
    { "protocol": "freedom", "tag": "direct" }
  ]
}
```

- [ ] **Step 3: Write the failing generator test**

`test/gen_xray_test.sh`:

```sh
#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
XKEEN_LIB_DIR="$DIR/../ui/xkeen-manager/backend/lib"; export XKEEN_LIB_DIR
. "$XKEEN_LIB_DIR/gen-xray.sh"

OUT="$(gen_xray_outbounds "$DIR/fixtures/state-v2.json")"
assert_json_eq "outbounds match frontend (reality)" "$DIR/golden/outbounds-v2.json" "$OUT"

test_summary
```

- [ ] **Step 4: Run it to verify it fails**

Run: `sh test/gen_xray_test.sh`
Expected: FAIL — `gen-xray.sh` / `gen_xray_outbounds` not found.

- [ ] **Step 5: Write the outbounds jq (Reality only)**

`ui/xkeen-manager/backend/lib/jq/xray-outbounds.jq`:

```jq
(.activeProfileId) as $id
| (.profiles[] | select(.id == $id) | .cores.xray) as $x
| ($x.proxyConfig) as $p
| ($x.muxConfig // {mode:"off"}) as $m
| {
    outbounds: [
      {
        tag: "vless-reality",
        protocol: "vless",
        settings: { vnext: [ {
          address: $p.address,
          port: ($p.port | tonumber),
          users: [ { id: $p.uuid, encryption: "none", flow: ($p.flow // "xtls-rprx-vision"), level: 0 } ]
        } ] },
        streamSettings: {
          network: "tcp", security: "reality",
          realitySettings: {
            publicKey: $p.publicKey,
            fingerprint: ($p.fingerprint // "random"),
            serverName: $p.serverName,
            shortId: $p.shortId,
            spiderX: "/"
          }
        },
        mux: ( if $m.mode == "xudp"
               then { enabled: true, concurrency: -1, xudpConcurrency: $m.xudpConcurrency, xudpProxyUDP443: $m.xudpProxyUDP443 }
               else { enabled: false } end )
      },
      { protocol: "freedom", tag: "direct" }
    ]
  }
```

- [ ] **Step 6: Write the generator shell wrapper**

`ui/xkeen-manager/backend/lib/gen-xray.sh`:

```sh
# gen_xray_outbounds <state-file> -> prints 04_outbounds.json content
# gen_xray_routing   <state-file> -> prints 05_routing.json content
# Callers MUST export XKEEN_LIB_DIR before sourcing (see state-migrate.sh rationale).
: "${XKEEN_LIB_DIR:?XKEEN_LIB_DIR must be set before sourcing gen-xray.sh}"
gen_xray_outbounds() { jq -f "$XKEEN_LIB_DIR/jq/xray-outbounds.jq" "$1"; }
gen_xray_routing()   { jq -f "$XKEEN_LIB_DIR/jq/xray-routing.jq" "$1"; }
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `sh test/gen_xray_test.sh`
Expected: `ok: outbounds match frontend (reality)`, `0 failed`.

- [ ] **Step 8: Commit**

```bash
git add ui/xkeen-manager/backend/lib/jq/xray-outbounds.jq ui/xkeen-manager/backend/lib/gen-xray.sh test/fixtures/state-v2.json test/golden/outbounds-v2.json test/gen_xray_test.sh
git commit -m "feat: server-side xray outbounds generator (reality) with golden parity"
```

---

## Task 5: xray routing generator + golden parity

**Files:**
- Create: `ui/xkeen-manager/backend/lib/jq/xray-routing.jq`
- Create: `test/golden/routing-v2.json`
- Modify: `test/gen_xray_test.sh` (add routing assertion)

The golden encodes `buildRoutingDocument` output: a fixed relay rule → `vless-reality`, then one
domain rule and one ip rule per enabled non-direct/non-bypass group, then the fallback rule. The
fixture's `bypass` group contributes no routing rule.

- [ ] **Step 1: Write the routing golden**

`test/golden/routing-v2.json`:

```json
{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["proxy-relay-ss"], "outboundTag": "vless-reality" },
      { "type": "field", "inboundTag": ["redirect"], "domain": ["chatgpt.com", "claude.ai"], "outboundTag": "vless-reality" },
      { "type": "field", "inboundTag": ["redirect"], "ip": ["1.2.3.0/24"], "outboundTag": "vless-reality" },
      { "type": "field", "inboundTag": ["redirect"], "outboundTag": "direct" }
    ]
  }
}
```

- [ ] **Step 2: Add the failing routing assertion**

Append to `test/gen_xray_test.sh` before `test_summary`:

```sh
ROUT="$(gen_xray_routing "$DIR/fixtures/state-v2.json")"
assert_json_eq "routing matches frontend" "$DIR/golden/routing-v2.json" "$ROUT"
```

- [ ] **Step 3: Run it to verify it fails**

Run: `sh test/gen_xray_test.sh`
Expected: FAIL — `gen_xray_routing` produces nothing / jq file missing.

- [ ] **Step 4: Write the routing jq**

`ui/xkeen-manager/backend/lib/jq/xray-routing.jq`:

```jq
(.activeProfileId) as $id
| (.profiles[] | select(.id == $id) | .cores.xray) as $x
| {
    routing: {
      domainStrategy: ($x.domainStrategy // "IPIfNonMatch"),
      rules: (
        [ { type: "field", inboundTag: ["proxy-relay-ss"], outboundTag: "vless-reality" } ]
        + ( [ $x.groups[]
              | select((.enabled != false) and (.outboundTag != "direct") and (.outboundTag != "bypass")) ]
            | map(
                ( if (.domains | length) > 0
                  then [ { type: "field", inboundTag: ["redirect"], domain: .domains, outboundTag: .outboundTag } ]
                  else [] end )
                + ( if (.cidrs | length) > 0
                    then [ { type: "field", inboundTag: ["redirect"], ip: .cidrs, outboundTag: .outboundTag } ]
                    else [] end )
              )
            | add // [] )
        + [ { type: "field", inboundTag: ["redirect"], outboundTag: ($x.fallbackOutbound // "direct") } ]
      )
    }
  }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `sh test/gen_xray_test.sh`
Expected: both assertions `ok:`, `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add ui/xkeen-manager/backend/lib/jq/xray-routing.jq test/golden/routing-v2.json test/gen_xray_test.sh
git commit -m "feat: server-side xray routing generator with golden parity"
```

---

## Task 6: XHTTP transport support in outbounds

**Files:**
- Modify: `ui/xkeen-manager/backend/lib/jq/xray-outbounds.jq`
- Create: `test/fixtures/state-xhttp.json`
- Create: `test/golden/outbounds-xhttp.json`
- Modify: `test/gen_xray_test.sh`

`proxyConfig.transport` defaults to `reality`; when `xhttp`, emit `streamSettings.network="xhttp"`
with `xhttpSettings` (host/path/mode) alongside `realitySettings`. Reality output is unchanged.

- [ ] **Step 1: Write the xhttp fixture**

`test/fixtures/state-xhttp.json`:

```json
{
  "schemaVersion": 2, "activeCore": "xray", "activeProfileId": "p1",
  "settings": { "ipv6Mode": "reject" },
  "profiles": [ { "id": "p1", "name": "P1", "cores": {
    "xray": {
      "proxyConfig": { "transport": "xhttp", "address": "cdn.example.com", "port": "443",
        "uuid": "11111111-1111-1111-1111-111111111111", "flow": "", "publicKey": "PK",
        "serverName": "example.com", "shortId": "abcd", "fingerprint": "chrome",
        "xhttpPath": "/stream", "xhttpMode": "auto" },
      "muxConfig": { "mode": "off", "tcpConcurrency": 8, "xudpConcurrency": 8, "xudpProxyUDP443": "reject" },
      "domainStrategy": "IPIfNonMatch", "fallbackOutbound": "direct", "groups": []
    },
    "mihomo": { "proxyConfig": { "transport": "reality" }, "rules": [], "proxyGroups": [] }
  } } ]
}
```

- [ ] **Step 2: Write the xhttp golden**

`test/golden/outbounds-xhttp.json`:

```json
{
  "outbounds": [
    {
      "tag": "vless-reality", "protocol": "vless",
      "settings": { "vnext": [ { "address": "cdn.example.com", "port": 443,
        "users": [ { "id": "11111111-1111-1111-1111-111111111111", "encryption": "none", "flow": "", "level": 0 } ] } ] },
      "streamSettings": {
        "network": "xhttp", "security": "reality",
        "xhttpSettings": { "host": "example.com", "path": "/stream", "mode": "auto" },
        "realitySettings": { "publicKey": "PK", "fingerprint": "chrome", "serverName": "example.com", "shortId": "abcd", "spiderX": "/" }
      },
      "mux": { "enabled": false }
    },
    { "protocol": "freedom", "tag": "direct" }
  ]
}
```

Note: for the `xhttp` transport the user `flow` MUST be empty — xray-core's `xtls-rprx-vision` flow is
only valid on raw TCP and `xray -test` rejects it on xhttp. So the generator forces `flow: ""` when
transport is `xhttp`, and the golden reflects that. (For reality/tcp, an empty flow still defaults to
`xtls-rprx-vision`.)

- [ ] **Step 3: Add the failing xhttp assertion**

Append to `test/gen_xray_test.sh` before `test_summary`:

```sh
OUTX="$(gen_xray_outbounds "$DIR/fixtures/state-xhttp.json")"
assert_json_eq "outbounds match (xhttp transport)" "$DIR/golden/outbounds-xhttp.json" "$OUTX"
```

- [ ] **Step 4: Run it to verify it fails**

Run: `sh test/gen_xray_test.sh`
Expected: the new assertion FAILS (current jq always emits `network:"tcp"`).

- [ ] **Step 5: Update the outbounds jq to branch on transport**

Rewrite `ui/xkeen-manager/backend/lib/jq/xray-outbounds.jq` to bind `$transport`, a transport-aware
`$flow`, and a single `$reality` object (no duplication), then branch `streamSettings` on transport:

```jq
(.activeProfileId) as $id
| (.profiles[] | select(.id == $id) | .cores.xray) as $x
| ($x.proxyConfig) as $p
| ($x.muxConfig // {mode:"off"}) as $m
| ($p.transport // "reality") as $transport
| ( if $transport == "xhttp" then ""
    elif ($p.flow // "") == "" then "xtls-rprx-vision"
    else $p.flow end ) as $flow
| ( { publicKey: $p.publicKey,
      fingerprint: ($p.fingerprint // "random"),
      serverName: $p.serverName,
      shortId: $p.shortId,
      spiderX: "/" } ) as $reality
| {
    outbounds: [
      {
        tag: "vless-reality",
        protocol: "vless",
        settings: { vnext: [ {
          address: $p.address,
          port: ($p.port | tonumber),
          users: [ { id: $p.uuid, encryption: "none", flow: $flow, level: 0 } ]
        } ] },
        streamSettings: (
          if $transport == "xhttp" then
            {
              network: "xhttp", security: "reality",
              xhttpSettings: { host: ($p.serverName // ""), path: ($p.xhttpPath // "/"), mode: ($p.xhttpMode // "auto") },
              realitySettings: $reality
            }
          else
            { network: "tcp", security: "reality", realitySettings: $reality }
          end
        ),
        mux: ( if $m.mode == "xudp"
               then { enabled: true, concurrency: -1, xudpConcurrency: $m.xudpConcurrency, xudpProxyUDP443: $m.xudpProxyUDP443 }
               else { enabled: false } end )
      },
      { protocol: "freedom", tag: "direct" }
    ]
  }
```

Two points baked in here: the user `flow` is transport-aware (empty for `xhttp`, defaulted to
`xtls-rprx-vision` for reality/tcp), and `realitySettings` is built once as `$reality` to avoid
duplicating it across both branches.

- [ ] **Step 6: Run the test to verify all pass**

Run: `sh test/gen_xray_test.sh`
Expected: three assertions `ok:` (reality outbounds, routing, xhttp outbounds), `0 failed`.

- [ ] **Step 6b: Add mux=xudp coverage (closes the gap flagged in Task 4)**

The `mux.mode == "xudp"` branch of the generator is otherwise untested. Add a fixture, golden, and
assertion exercising it.

`test/fixtures/state-mux-xudp.json`:

```json
{
  "schemaVersion": 2, "activeCore": "xray", "activeProfileId": "p1",
  "settings": { "ipv6Mode": "reject" },
  "profiles": [ { "id": "p1", "name": "P1", "cores": {
    "xray": {
      "proxyConfig": { "transport": "reality", "address": "vpn.example.com", "port": 443,
        "uuid": "00000000-0000-0000-0000-000000000000", "flow": "xtls-rprx-vision", "publicKey": "PK",
        "serverName": "sni.example.com", "shortId": "abcd", "fingerprint": "random" },
      "muxConfig": { "mode": "xudp", "tcpConcurrency": 8, "xudpConcurrency": 8, "xudpProxyUDP443": "reject" },
      "domainStrategy": "IPIfNonMatch", "fallbackOutbound": "direct", "groups": []
    },
    "mihomo": { "proxyConfig": { "transport": "reality" }, "rules": [], "proxyGroups": [] }
  } } ]
}
```

`test/golden/outbounds-mux-xudp.json`:

```json
{
  "outbounds": [
    {
      "tag": "vless-reality", "protocol": "vless",
      "settings": { "vnext": [ { "address": "vpn.example.com", "port": 443,
        "users": [ { "id": "00000000-0000-0000-0000-000000000000", "encryption": "none", "flow": "xtls-rprx-vision", "level": 0 } ] } ] },
      "streamSettings": { "network": "tcp", "security": "reality",
        "realitySettings": { "publicKey": "PK", "fingerprint": "random", "serverName": "sni.example.com", "shortId": "abcd", "spiderX": "/" } },
      "mux": { "enabled": true, "concurrency": -1, "xudpConcurrency": 8, "xudpProxyUDP443": "reject" }
    },
    { "protocol": "freedom", "tag": "direct" }
  ]
}
```

Append to `test/gen_xray_test.sh` before `test_summary`:

```sh
OUTM="$(gen_xray_outbounds "$DIR/fixtures/state-mux-xudp.json")"
assert_json_eq "outbounds match (mux xudp)" "$DIR/golden/outbounds-mux-xudp.json" "$OUTM"
```

Run `sh test/gen_xray_test.sh` and `dash test/gen_xray_test.sh`; expect this assertion `ok:`.

- [ ] **Step 7: Run the full suite**

Run: `sh test/run.sh`
Expected: migrate, validate, gen_xray all green; exit 0.

- [ ] **Step 8: Commit**

```bash
git add ui/xkeen-manager/backend/lib/jq/xray-outbounds.jq \
  test/fixtures/state-xhttp.json test/golden/outbounds-xhttp.json \
  test/fixtures/state-mux-xudp.json test/golden/outbounds-mux-xudp.json \
  test/gen_xray_test.sh
git commit -m "feat: XHTTP transport + mux=xudp coverage in xray outbounds generator"
```

---

## Task 7: Sourcing contract doc for Plan 0b

**Files:**
- Create: `ui/xkeen-manager/backend/lib/README.md`

This records the interface Plan 0b (the apply pipeline) will consume, so the API layer can call these
functions without re-reading the implementations.

- [ ] **Step 1: Write the interface doc**

`ui/xkeen-manager/backend/lib/README.md`:

```markdown
# backend/lib — server-side state & config core

Sourced by the CGI apply path and self-heal. Set `XKEEN_LIB_DIR` to this directory before sourcing
under plain POSIX sh (no `$BASH_SOURCE`).

- `state-migrate.sh` → `migrate_state <state-file>`: prints migrated v2 JSON. Idempotent.
- `validate.sh` → `validate_state <state-file>`: exit 0 if valid; else errors to stderr, exit 1.
- `gen-xray.sh` → `gen_xray_outbounds <state-file>`, `gen_xray_routing <state-file>`: print the xray
  `04_outbounds.json` / `05_routing.json` content for the active profile's xray core.

Apply pipeline (Plan 0b) order: migrate → validate → write state → gen_xray_* → `xray -test` →
restart + runtime rebuild, with rollback on failure.

Tests: `sh test/run.sh` from the repo root (requires `jq`).
```

- [ ] **Step 2: Commit**

```bash
git add ui/xkeen-manager/backend/lib/README.md
git commit -m "docs: backend/lib sourcing contract for the apply pipeline"
```

---

## Self-review notes

- **Spec coverage (Plan 0a slice):** server-side xray config derivation (Tasks 4–6), state schema v2
  + migration (Task 2), validation (Task 3), XHTTP transport (Task 6), golden parity test
  (Tasks 4–5). Deferred to Plan 0b: `/api/v1` routing, session cache, async apply, core-switch,
  LAN-bind, install.sh netcat, compat shims. Deferred to the TUN spike: mihomo runtime mode.
- **Apply-readiness vs structural validation:** intentionally split — Task 3 validates shape only;
  port/uuid completeness is checked at apply time in Plan 0b.
- **Parity basis:** golden files were hand-derived from `app.js` `buildOutboundsDocument` /
  `buildRoutingDocument` / `buildMuxObject`. On-router `xray -test` in Plan 0b is the second safety net.
```
