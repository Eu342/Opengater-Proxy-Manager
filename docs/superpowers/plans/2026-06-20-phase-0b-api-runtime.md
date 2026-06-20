# Phase 0b — API Surface & Runtime Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Wire the Phase 0a config core into a running router: a `PATH_INFO`-routed `/api/v1` front controller, an async apply pipeline (migrate → normalize → validate → write → generate → `xray -test` → restart + runtime, with rollback), a session cache, LAN-bind hardening, install wiring, and backward-compat shims — culminating in a comprehensive on-Giga integration test.

**Architecture:** A single front-controller CGI (`api.cgi`) dispatches on `REQUEST_METHOD` + `PATH_INFO` into sourced handler modules. It reuses the Phase 0a libs (`migrate_state`, `validate_state`, `gen_xray_*`) plus a new `normalize_state`. The apply pipeline runs detached and reports status via a job file. The old `routing.cgi` stays as a thin shim mapping `?kind=` to v1 handlers so the shipping UI keeps working.

**Tech Stack:** POSIX `sh` (busybox ash), `jq`, `uhttpd_kn`, `xray`, `ndmc`, `iptables`. Dev-machine prerequisites: `jq`, `sh`, `dash`. The Phase 0a test harness (`test/lib.sh`, `test/run.sh`) is reused.

**Split note:** Tasks 1–4 are dev-machine testable (pure `sh`+`jq`, TDD with goldens/stubs). Tasks 5–9 are router-coupled and verified on the Keenetic Giga 1010; their "code" is exact deploy + verification procedures because the precise uhttpd/ndmc behavior must be confirmed on hardware (the design spec flags these unknowns). Task 9 is the comprehensive integration test the owner asked for.

---

## Grounding facts (from recon)

Current UI server launch (`scripts/xkeen/opengater.initd.sh`):
```
uhttpd -f -p 0.0.0.0:8899 -h /opt/share/xkeen-manager -I index.html -x /api -i .cgi=/bin/sh -r Opengater
```
- `-x /api` + `-i .cgi=/bin/sh`: requests under `/api` are CGI run via busybox `/bin/sh`; `PATH_INFO` after the script path is exposed. So `/api/api.cgi/v1/state` → `SCRIPT_NAME=/api/api.cgi`, `PATH_INFO=/v1/state`. A truly clean `/api/v1/*` mapping is verified on hardware in Task 7 (fallback: the `api.cgi/v1` form, zero uhttpd risk).
- `-p 0.0.0.0:8899` binds **all** interfaces incl. WAN → LAN-bind hardening target (Task 7); `install.sh` already detects the Bridge0 IP via `ndmc`.
- CGI auth today (`routing.cgi`): the CGI re-validates the Keenetic web session by `wget`-ing `http://<host>/auth` with the caller's cookie on every request → Task 4 caches this.

---

## File Structure

- Create: `ui/xkeen-manager/backend/lib/jq/normalize-state.jq`, `ui/xkeen-manager/backend/lib/normalize.sh` — `normalize_state`.
- Create: `ui/xkeen-manager/backend/lib/router.sh` — `route_request` (METHOD+PATH_INFO → handler name).
- Create: `ui/xkeen-manager/backend/lib/apply.sh` — `run_apply` (orchestration, injectable side-effects) + job helpers.
- Create: `ui/xkeen-manager/backend/lib/session-cache.sh` — `session_cache_get`/`session_cache_put`/`session_cache_drop`.
- Create: `ui/xkeen-manager/backend/api.cgi` — front controller (sources lib + handler modules).
- Create: `ui/xkeen-manager/backend/lib/handlers/*.sh` — `auth.sh`, `state.sh`, `apply.sh`-handlers, `health.sh`, `settings.sh`, `stub.sh`.
- Modify: `scripts/xkeen/opengater.initd.sh` — LAN-bind.
- Modify: `install.sh` — deploy lib/ + api.cgi, add a netcat package, keep `routing.cgi` shim.
- Modify: `ui/xkeen-manager/backend/routing.cgi` — reduce to a `?kind=` → v1 shim.
- Tests: `test/normalize_test.sh`, `test/router_test.sh`, `test/apply_test.sh`, `test/session_cache_test.sh`.

---

## Task 1: `normalize_state` (closes design item I1)

**Files:**
- Create: `ui/xkeen-manager/backend/lib/jq/normalize-state.jq`
- Create: `ui/xkeen-manager/backend/lib/normalize.sh`
- Create: `test/fixtures/state-messy.json`, `test/golden/state-normalized.json`
- Test: `test/normalize_test.sh`

`normalize_state` mirrors the frontend's input sanitization so state-at-rest is always clean regardless
of client. From `app.js`: `uniq()` = trim + drop-empty + order-preserving dedup on each group's
`domains`/`cidrs`; `normalizeMuxConfig` = `mode ∈ {off,xudp}` (else derived: `xudpConcurrency>0?xudp:off`),
`tcpConcurrency` fixed `8`, `xudpConcurrency` = `clampInt(v,8,1,1024)`, `xudpProxyUDP443 ∈ {reject,skip,allow}`
(else `"reject"`). Applies to every profile's `cores.xray`.

- [ ] **Step 1: Write the messy fixture**

`test/fixtures/state-messy.json`:

```json
{
  "schemaVersion": 2, "activeCore": "xray", "activeProfileId": "p1",
  "settings": { "ipv6Mode": "reject" },
  "profiles": [ { "id": "p1", "name": "P1", "cores": {
    "xray": {
      "proxyConfig": { "transport": "reality", "address": "vpn.example.com", "port": 443,
        "uuid": "00000000-0000-0000-0000-000000000000", "flow": "xtls-rprx-vision", "publicKey": "PK",
        "serverName": "sni.example.com", "shortId": "abcd", "fingerprint": "random" },
      "muxConfig": { "mode": "xudp", "tcpConcurrency": 4, "xudpConcurrency": 99999, "xudpProxyUDP443": "garbage" },
      "domainStrategy": "IPIfNonMatch", "fallbackOutbound": "direct",
      "groups": [
        { "id": "g1", "name": "G", "note": "", "enabled": true, "outboundTag": "vless-reality",
          "domains": ["dup.com", "dup.com", "  spaced.com  ", "", "keep.com"],
          "cidrs": ["1.2.3.0/24", "1.2.3.0/24", "  4.4.4.0/24 "] }
      ]
    },
    "mihomo": { "proxyConfig": { "transport": "reality" }, "rules": [], "proxyGroups": [] }
  } } ]
}
```

- [ ] **Step 2: Write the normalized golden**

`test/golden/state-normalized.json` — same as the fixture but with the xray core's groups deduped/trimmed
and mux clamped/coerced:

```json
{
  "schemaVersion": 2, "activeCore": "xray", "activeProfileId": "p1",
  "settings": { "ipv6Mode": "reject" },
  "profiles": [ { "id": "p1", "name": "P1", "cores": {
    "xray": {
      "proxyConfig": { "transport": "reality", "address": "vpn.example.com", "port": 443,
        "uuid": "00000000-0000-0000-0000-000000000000", "flow": "xtls-rprx-vision", "publicKey": "PK",
        "serverName": "sni.example.com", "shortId": "abcd", "fingerprint": "random" },
      "muxConfig": { "mode": "xudp", "tcpConcurrency": 8, "xudpConcurrency": 1024, "xudpProxyUDP443": "reject" },
      "domainStrategy": "IPIfNonMatch", "fallbackOutbound": "direct",
      "groups": [
        { "id": "g1", "name": "G", "note": "", "enabled": true, "outboundTag": "vless-reality",
          "domains": ["dup.com", "spaced.com", "keep.com"],
          "cidrs": ["1.2.3.0/24", "4.4.4.0/24"] }
      ]
    },
    "mihomo": { "proxyConfig": { "transport": "reality" }, "rules": [], "proxyGroups": [] }
  } } ]
}
```

- [ ] **Step 3: Write the failing test**

`test/normalize_test.sh`:

```sh
#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
XKEEN_LIB_DIR="$DIR/../ui/xkeen-manager/backend/lib"; export XKEEN_LIB_DIR
. "$XKEEN_LIB_DIR/normalize.sh"

OUT="$(normalize_state "$DIR/fixtures/state-messy.json")"
assert_json_eq "messy state normalizes to golden" "$DIR/golden/state-normalized.json" "$OUT"

# Idempotency: normalizing the golden changes nothing.
TMP="$(mktemp)"; printf '%s' "$OUT" > "$TMP"
OUT2="$(normalize_state "$TMP")"
assert_json_eq "normalize is idempotent" "$OUT" "$OUT2"
rm -f "$TMP"

test_summary
```

- [ ] **Step 4: Run to verify it fails**

Run: `sh test/normalize_test.sh` — FAIL (`normalize.sh` not found).

- [ ] **Step 5: Write the normalize jq**

`ui/xkeen-manager/backend/lib/jq/normalize-state.jq`:

```jq
def clean_list:
  [ .[]? | tostring | gsub("^[[:space:]]+|[[:space:]]+$"; "") | select(. != "") ]
  | reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);

def clamp_concurrency:
  ( ( . | tostring | tonumber? ) // 8 | floor ) as $n
  | if $n < 1 then 1 elif $n > 1024 then 1024 else $n end;

def norm_mux:
  ( . // {} ) as $m
  | ( $m.mode // "" ) as $mode
  | ( if ($mode == "off" or $mode == "xudp") then $mode
      elif ($mode == "") then "off"
      elif ( ( $m.xudpConcurrency // 0 | tostring | tonumber? ) // 0 ) > 0 then "xudp"
      else "off" end ) as $finalmode
  | { mode: $finalmode,
      tcpConcurrency: 8,
      xudpConcurrency: ( $m.xudpConcurrency | clamp_concurrency ),
      xudpProxyUDP443: ( if ( ["reject","skip","allow"] | index($m.xudpProxyUDP443) ) != null
                         then $m.xudpProxyUDP443 else "reject" end ) };

.profiles |= map(
  .cores.xray |= (
    .groups = ( ( .groups // [] ) | map(
        .domains = ( ( .domains // [] ) | clean_list )
      | .cidrs   = ( ( .cidrs   // [] ) | clean_list )
    ) )
    | .muxConfig = ( .muxConfig | norm_mux )
  )
)
```

- [ ] **Step 6: Write the wrapper**

`ui/xkeen-manager/backend/lib/normalize.sh`:

```sh
# normalize_state <state-file> -> prints normalized JSON (dedup/trim group lists, clamp mux).
# Mirrors the frontend's uniq()/normalizeMuxConfig so state-at-rest is clean for any client.
# Callers MUST export XKEEN_LIB_DIR before sourcing (see state-migrate.sh rationale).
: "${XKEEN_LIB_DIR:?XKEEN_LIB_DIR must be set before sourcing normalize.sh}"
normalize_state() {
  jq -f "$XKEEN_LIB_DIR/jq/normalize-state.jq" "$1"
}
```

- [ ] **Step 7: Run under sh and dash**

Run: `sh test/normalize_test.sh` and `dash test/normalize_test.sh` — both `0 failed`.
Run full suite: `sh test/run.sh` — all green.

- [ ] **Step 8: Commit**

```bash
git add ui/xkeen-manager/backend/lib/jq/normalize-state.jq ui/xkeen-manager/backend/lib/normalize.sh \
  test/fixtures/state-messy.json test/golden/state-normalized.json test/normalize_test.sh
git commit -m "feat: normalize_state (dedup/trim group lists, clamp mux) for PUT /state"
```

---

## Task 2: Request router (`route_request`)

**Files:**
- Create: `ui/xkeen-manager/backend/lib/router.sh`
- Test: `test/router_test.sh`

A pure function mapping `REQUEST_METHOD` + `PATH_INFO` to a handler token, so the front controller stays
declarative and the routing is unit-testable without uhttpd. Unknown route → `not_found`; known path with
wrong method → `method_not_allowed`.

- [ ] **Step 1: Write the failing test** (`test/router_test.sh`)

```sh
#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
XKEEN_LIB_DIR="$DIR/../ui/xkeen-manager/backend/lib"; export XKEEN_LIB_DIR
. "$XKEEN_LIB_DIR/router.sh"

assert_eq "GET state"        "get_state"            "$(route_request GET  /v1/state)"
assert_eq "PUT state"        "put_state"            "$(route_request PUT  /v1/state)"
assert_eq "POST apply"       "post_apply"           "$(route_request POST /v1/apply)"
assert_eq "GET apply job"    "get_apply_status"     "$(route_request GET  /v1/apply/abc123)"
assert_eq "POST login"       "post_login"           "$(route_request POST /v1/auth/login)"
assert_eq "GET health"       "get_health"           "$(route_request GET  /v1/health)"
assert_eq "GET core"         "get_core"             "$(route_request GET  /v1/core)"
assert_eq "subscription stub" "stub_501"            "$(route_request POST /v1/subscription/import)"
assert_eq "devices stub"     "stub_501"             "$(route_request GET  /v1/devices)"
assert_eq "unknown route"    "not_found"            "$(route_request GET  /v1/nope)"
assert_eq "bad method"       "method_not_allowed"   "$(route_request DELETE /v1/state)"
test_summary
```

- [ ] **Step 2: Run → fails.** `sh test/router_test.sh`.

- [ ] **Step 3: Implement `route_request`** (`ui/xkeen-manager/backend/lib/router.sh`). Use a `case` over
  `"$1 $2"` with glob for the job-id segment. Full code:

```sh
# route_request <METHOD> <PATH_INFO> -> prints a handler token.
route_request() {
  _m="$1"; _p="$2"
  case "$_p" in
    /v1/state)
      case "$_m" in GET) echo get_state ;; PUT) echo put_state ;; *) echo method_not_allowed ;; esac ;;
    /v1/apply)
      case "$_m" in POST) echo post_apply ;; *) echo method_not_allowed ;; esac ;;
    /v1/apply/*)
      case "$_m" in GET) echo get_apply_status ;; *) echo method_not_allowed ;; esac ;;
    /v1/config/outbounds|/v1/config/routing)
      case "$_m" in GET) echo get_config ;; *) echo method_not_allowed ;; esac ;;
    /v1/auth/login)   case "$_m" in POST) echo post_login ;;  *) echo method_not_allowed ;; esac ;;
    /v1/auth/logout)  case "$_m" in POST) echo post_logout ;; *) echo method_not_allowed ;; esac ;;
    /v1/auth/session) case "$_m" in GET)  echo get_session ;; *) echo method_not_allowed ;; esac ;;
    /v1/core)
      case "$_m" in GET) echo get_core ;; PUT) echo put_core ;; *) echo method_not_allowed ;; esac ;;
    /v1/health)  case "$_m" in GET) echo get_health ;; *) echo method_not_allowed ;; esac ;;
    /v1/stack)   case "$_m" in GET) echo get_stack ;;  *) echo method_not_allowed ;; esac ;;
    /v1/logs)    case "$_m" in GET) echo get_logs ;;   *) echo method_not_allowed ;; esac ;;
    /v1/probe)   case "$_m" in POST) echo post_probe ;; *) echo method_not_allowed ;; esac ;;
    /v1/runtime/repair) case "$_m" in POST) echo post_repair ;; *) echo method_not_allowed ;; esac ;;
    /v1/services/*/restart) case "$_m" in POST) echo post_restart ;; *) echo method_not_allowed ;; esac ;;
    /v1/settings)
      case "$_m" in GET) echo get_settings ;; PUT) echo put_settings ;; *) echo method_not_allowed ;; esac ;;
    /v1/subscription/*|/v1/devices|/v1/devices/*|/v1/cores/mihomo/*)
      echo stub_501 ;;
    *) echo not_found ;;
  esac
}
```

- [ ] **Step 4: Run → passes** under sh and dash. **Step 5: Commit** `feat: /api/v1 request router`.

---

## Task 3: Apply pipeline orchestration (`run_apply`)

**Files:**
- Create: `ui/xkeen-manager/backend/lib/apply.sh`
- Test: `test/apply_test.sh`

`run_apply <state-file> <job-file>` runs: migrate → normalize → validate → (write configs via the gen libs)
→ config self-test → on success commit + signal restart; on failure roll back. Side effects that need a
real router (writing to `/opt/etc/xray/...`, `xray -test`, restart) are taken from **overridable shell
variables** so the state machine is unit-testable with stubs. It writes `{status, detail}` to the job file.

- [ ] **Step 1: Failing test** (`test/apply_test.sh`) — drives `run_apply` with stub commands that simulate
  success and failure, asserting the job file ends `ok` / `failed` and that rollback restores the prior
  config on a failing self-test. Full test:

```sh
#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
XKEEN_LIB_DIR="$DIR/../ui/xkeen-manager/backend/lib"; export XKEEN_LIB_DIR
. "$XKEEN_LIB_DIR/state-migrate.sh"; . "$XKEEN_LIB_DIR/normalize.sh"
. "$XKEEN_LIB_DIR/validate.sh"; . "$XKEEN_LIB_DIR/gen-xray.sh"
. "$XKEEN_LIB_DIR/apply.sh"

WORK="$(mktemp -d)"
export XKEEN_STATE_PATH="$WORK/state.json"
export XKEEN_XRAY_CONFDIR="$WORK/xray"
mkdir -p "$XKEEN_XRAY_CONFDIR"
# Inject stubs: self-test passes, restart succeeds, runtime rebuild is a no-op.
export XKEEN_SELFTEST_CMD="true"
export XKEEN_RESTART_CMD="true"
export XKEEN_RUNTIME_CMD="true"

JOB="$WORK/job.json"
run_apply "$DIR/fixtures/state-v1.json" "$JOB"
assert_eq "apply ok status" "ok" "$(jq -r .status "$JOB")"
assert_eq "state written" "2" "$(jq -r .schemaVersion "$XKEEN_STATE_PATH")"
assert_eq "outbounds written" "vless-reality" "$(jq -r '.outbounds[0].tag' "$XKEEN_XRAY_CONFDIR/04_outbounds.json")"

# Failure path: self-test fails -> status failed, configs rolled back to previous.
cp "$XKEEN_XRAY_CONFDIR/05_routing.json" "$WORK/prev_routing.json"
export XKEEN_SELFTEST_CMD="false"
run_apply "$DIR/fixtures/state-v1.json" "$JOB" || true
assert_eq "apply failed status" "failed" "$(jq -r .status "$JOB")"
assert_json_eq "routing rolled back" "$WORK/prev_routing.json" "$(cat "$XKEEN_XRAY_CONFDIR/05_routing.json")"
rm -rf "$WORK"
test_summary
```

- [ ] **Step 2: Run → fails.**
- [ ] **Step 3: Implement `run_apply`** with the overridable-command design. Contract (finalize exact code
  at execution; the test above pins behavior): reads `XKEEN_STATE_PATH`, `XKEEN_XRAY_CONFDIR`,
  `XKEEN_SELFTEST_CMD` (default `xray run -test -confdir "$XKEEN_XRAY_CONFDIR"`), `XKEEN_RESTART_CMD`,
  `XKEEN_RUNTIME_CMD`. Sequence: `migrate_state | normalize_state` (chained via temp) → `validate_state`
  (fail → job `failed`, no writes) → back up current `04_outbounds.json`/`05_routing.json`/state →
  `gen_xray_outbounds`/`gen_xray_routing` to temp, move into confdir → run `XKEEN_SELFTEST_CMD` →
  on success write state, run restart + runtime, job `ok`; on failure restore backups, job `failed`.
- [ ] **Step 4: Run → passes** (sh + dash). **Step 5: Commit** `feat: async apply pipeline orchestration`.

**Final shape (review-driven, as committed in `ui/xkeen-manager/backend/lib/apply.sh`):** the `pending`
job is written with plain `printf` (no jq dependency on a transient status); migrate/normalize/validate
stderr is captured per-stage and folded into the failure `detail`; the success payload includes a
`restartOk` boolean. **Deliberate decision:** a failed xray restart does NOT roll back — the committed
config is valid (self-test passed), so apply reports `{status:"ok", restartOk:false}` and the self-heal
watchdog recovers, consistent with the project's self-heal architecture. The test pins 12 cases incl.
restart-failure and full rollback of `04_outbounds`/`05_routing`/state.

---

## Task 4: Session cache

**Files:**
- Create: `ui/xkeen-manager/backend/lib/session-cache.sh`
- Test: `test/session_cache_test.sh`

Caches a validated session token → expiry so health polling doesn't hit Keenetic `/auth` every request.
`session_cache_put <token> <ttl>`; `session_cache_get <token>` exits 0 if present & unexpired else 1;
`session_cache_drop <token>`. Time source is `XKEEN_NOW` (overridable for tests; defaults to `date +%s`).
Store: a file `XKEEN_SESSION_CACHE` (default `/tmp/xkeen-session-cache`) of `sha256(token) expiry` lines.

- [ ] **Step 1: Failing test** — put a token with ttl 60 at now=1000, get at now=1030 (hit), get at
  now=1100 (miss/expired), drop then get (miss). Hash the token so the raw cookie isn't stored.
- [ ] **Step 2–4:** implement, run under sh+dash, **Commit** `feat: session cache for router auth`.

---

## Task 5: Front controller `api.cgi` + handlers (router-coupled)

**Files:**
- Create: `ui/xkeen-manager/backend/api.cgi`
- Create: `ui/xkeen-manager/backend/lib/handlers/{auth,state,apply,health,settings,stub}.sh`

`api.cgi` sets `PATH`, exports `XKEEN_LIB_DIR`, sources the libs + handlers, computes
`route_request "$REQUEST_METHOD" "$PATH_INFO"`, enforces auth for non-`auth/*` routes (via the session
cache + the existing Keenetic `/auth` check, ported from `routing.cgi`), and calls the handler. Handlers
reuse Phase 0a/0b libs:
- `state.sh`: `get_state` emits `XKEEN_STATE_PATH`; `put_state` reads body → `migrate|normalize|validate`
  → persist (no apply). `apply` handler: spawn `run_apply` detached (`… &`), return `202 {jobId}`;
  `get_apply_status` reads the job file.
- `health.sh`/`settings.sh`: port `emit_health`/`emit_stack_info`/`emit_logs` from `routing.cgi`; settings
  read/write `state.settings.ipv6Mode`.
- `stub.sh`: `stub_501` returns `501 {"ok":false,"error":"not_implemented"}` for subscription/devices/mihomo.
- Auth handlers: port `router_auth_login`/`logout`/`require_router_session` from `routing.cgi`, adding the
  Task 4 cache.

Verification (dev, partial): drive `api.cgi` with mocked CGI env vars (`REQUEST_METHOD`, `PATH_INFO`,
`HTTP_COOKIE`, body on stdin) for routes that don't need a live router (`route_request` dispatch, `stub_501`,
`get_state` against a temp `XKEEN_STATE_PATH`, `put_state` validation rejection). Full auth + apply paths are
exercised on the Giga in Task 9.

**Security decisions (from the T5a review, apply to ALL ported auth code):**
- **Validate the router session against `SERVER_ADDR`, never the client-controlled `HTTP_HOST`.** A LAN
  attacker can spoof `Host:` to point self-validation at a server that always returns 200, bypassing auth.
  `SERVER_ADDR` is the local IP the request arrived on and is not client-spoofable. This MUST be applied when
  porting `router_auth_login`/`router_auth_logout`/`require_router_session` from the old `routing.cgi`
  (which used `HTTP_HOST`).
- **Auth gate runs before stub/handler dispatch; only 404/405 are pre-auth.** `stub_501` is a normal handler
  (in `handlers/stub.sh`) so unauthenticated route enumeration is impossible.
- The auth bypass seam is `XKEEN_AUTH_BYPASS` — a server-side env var with no `HTTP_` prefix, so uhttpd can
  never populate it from a request.

**Progress:** Part A (skeleton: `http.sh`, `handlers/auth-gate.sh`, `handlers/stub.sh`, `api.cgi`) and
Part B (route handlers `handlers/{state,apply,config,settings,core}.sh`) are implemented and dev-tested
(api_test.sh + api_handlers_test.sh). Review-driven fixes landed: SERVER_ADDR auth, stub-behind-auth,
state-wipe guard on corrupt state (get/put return 500, never write a 0-byte file), strict alphanumeric
job-id charset (path-traversal-safe). Part C done: auth (`handlers/auth.sh`, SERVER_ADDR) and diagnostics (`handlers/diag.sh`:
health/stack/logs/probe/repair/restart, field-name-faithful port of `routing.cgi`). **T5 complete** —
the full `/api/v1` handler surface is implemented and dev-tested (88 assertions green under sh+dash);
router-only paths verified on the Giga (Task 9). Deltas for the shim author: `post_probe` returns 400
(was 500) on bad payload; `post_restart` reads svc from PATH_INFO, not the body.

**T6 shim caveat (design fork):** the old UI (`app.js`) expects the FLAT v1 state shape and builds the
xray config in the browser; the new backend uses v2 (`cores.xray.*`) and generates server-side. A
faithful `?kind=state` shim would need a v2→v1 down-converter for reads, and the browser-built
routing/outbounds POSTs are now superseded by server generation. This makes a full back-compat shim
real work for a UI that's slated for replacement — see the open decision recorded with the owner.

---

## Task 6: install + service wiring (router-coupled)

**Files:** Modify `install.sh`, `scripts/xkeen/opengater.initd.sh`, `ui/xkeen-manager/backend/routing.cgi`.

- `install.sh`: deploy `ui/xkeen-manager/backend/lib/**` to `/opt/share/xkeen-manager/api/lib/`, deploy
  `api.cgi` to `/opt/share/xkeen-manager/api/api.cgi`, add a netcat package (for `probe`; verify the exact
  Entware package name on the Giga — candidates: `netcat`, `nmap-ncat`) to the `PKGS` list, and keep
  deploying `routing.cgi` (now a shim).
- `routing.cgi` → thin shim: translate the legacy `?kind=…` to the v1 handlers by sourcing the same libs and
  calling the same handler functions, so the **current shipping UI keeps working unchanged** (Task 8 pins
  this with tests). 
- **Commit** `feat: install + serve the v1 API; routing.cgi becomes a shim`.

---

## Task 7: uhttpd clean-path + LAN-bind (Giga discovery)

**Files:** Modify `scripts/xkeen/opengater.initd.sh`.

- [ ] **Discover** on the Giga whether uhttpd_kn can serve `/api/v1/*` directly (e.g. via a `-x /api/v1`
  prefix pointing at `api.cgi`, an `index`/alias, or a uhttpd config file). Record the result.
- [ ] **Wire**: if clean paths work, configure them; otherwise the API base is `/api/api.cgi/v1` (set the UI
  `API_BASE` accordingly). Either way `PATH_INFO` reaches `api.cgi`.
- [ ] **LAN-bind**: replace `-p 0.0.0.0:8899` with the LAN bridge IP. Detect it like `install.sh`'s
  `print_summary` (`ndmc 'show interface'` → Bridge0 `address`); fall back to `0.0.0.0` only if detection
  fails, logging a warning. Verify from a WAN-side host that `:8899` is unreachable and from LAN that it is.
- **Commit** `feat: LAN-bind the UI server; wire /api/v1 path`.

---

## Task 8: backward-compat shim tests

**Files:** Test additions exercising `routing.cgi` (the shim) via mocked CGI env, asserting the legacy
`?kind=state` (GET/POST), `?kind=outbounds`, `?kind=health`, `?kind=login` paths still return the same
shapes the current `app.js` expects. This guards the "don't break the shipping UI" invariant. **Commit**
`test: legacy ?kind= shim parity`.

---

## Task 9: Comprehensive on-Giga integration test (the owner's "комплексная проверка")

Procedure on the Keenetic Giga 1010 (deploy the branch, then):
- [ ] Run the full dev test suite on the router (`sh test/run.sh` using busybox `sh` + `/opt/bin/jq`) to
  confirm jq-version parity with the dev machine.
- [ ] `GET /api/v1/health` and `/stack` return valid JSON; auth required without a session, succeeds with
  Keenetic creds; session cache hit on the second call (no second `/auth` round-trip — confirm via timing/log).
- [ ] `PUT /api/v1/state` with a real VLESS Reality config → `POST /api/v1/apply` → poll
  `GET /api/v1/apply/{id}` to `ok`; confirm `xray -test` passed, xray restarted, `04_outbounds.json`/
  `05_routing.json` match the generators, and a marked device actually routes through the VPN.
- [ ] Deliberately bad config (e.g. invalid port) → apply returns `failed`, configs rolled back, xray still up.
- [ ] Old UI still works end-to-end via the `routing.cgi` shim.
- [ ] LAN-bind verified (WAN-side `:8899` refused; LAN-side OK).
- [ ] Run the **TUN spike** here too (gates Phase 1/mihomo): check `/dev/net/tun`, load the module, run
  mihomo in TUN mode, push traffic — record TUN-viable or fall back to tproxy.
- Record results in `docs/troubleshooting.md` per project rules; **commit** any fixes the test surfaces.

---

## Self-review notes

- **Spec coverage (Phase 0b):** server-side config generation is wired via the apply pipeline (T3/T5);
  `/api/v1` contract + PATH_INFO routing (T2/T5/T7); state validation + normalization at `PUT /state`
  (T1/T5, closing design item I1); async apply with jobId (T3/T5); session cache (T4); LAN-bind (T7);
  install + compat shims (T6/T8); mihomo/subscription/devices are `501` stubs (T2/T5). The comprehensive
  on-hardware test is T9.
- **Dev-testable vs router-coupled:** T1–T4 are TDD with goldens/stubs and run under `sh`+`dash` like
  Phase 0a. T5–T9 are verified on the Giga; their procedures include explicit verification gates rather
  than guessed uhttpd/ndmc code, because those behaviors are confirmed on hardware (per the spec's
  open-items list).
- **Risk register:** uhttpd clean-path mapping (T7, fallback defined), exact netcat package name (T6,
  verified on Giga), TUN viability (T9, tproxy fallback). None block T1–T4.
```
