# Phase 0 — Core-Pluggable API Foundation & Hardening (design)

Date: 2026-06-20
Status: approved for spec review
Owner: e@opengater.com

## Context

Opengater is a router-hosted control panel for Keenetic + Entware. Today it drives `xray` (TCP) +
`sing-box` (UDP); the single source of truth is `xkeen-ui-state.json`. We are extending it into part
of a **paid client VPN service**, and adding a **second proxy core (mihomo / Clash.Meta)** that the
user can switch to from the UI.

Full roadmap (each row is an independent sub-project with its own spec → plan → implementation):

| Phase | Sub-project | Status |
|-------|-------------|--------|
| 0 | **Core-pluggable API foundation + hardening** (this spec) | active |
| 1 | mihomo core implementation (install, TUN runtime, generator, switch, routing editor) | next |
| 2 | Subscription import (paste base64 `vless://` list or JSON sub → proxyConfig) | later |
| 3 | Device management (list LAN devices, toggle VPN per device) | later |
| 4 | FakeIP support (primarily via mihomo) | later |
| 5 | Backend integration (auto-pull subscription after auth) | deferred by owner |
| 6 | New UI built on the v1 API | last |

This document covers **Phase 0 only**.

### Why Phase 0 first

The README claims the backend generates the xray configs. In reality the **frontend** does
(`buildOutboundsDocument` / `buildRoutingDocument` in `app.js`); the CGI only writes posted JSON after
a weak `grep` check. Config derivation is split across two languages (JS + jq). Until it moves
server-side and the state schema becomes core-aware, no other client (the owner's backend, a new UI,
the future mihomo core) can drive the router. Phase 0 fixes this and freezes the API contract for
every later phase.

## Goals

1. Make `state.json` the single, **core-namespaced** input; move xray config derivation to the router.
2. Expose a versioned REST API (`/api/v1`) whose contract covers all planned functionality and both
   cores, even where the implementation is a Phase 0 stub.
3. Validate state before any write.
4. Make "apply" asynchronous (202 + jobId, poll for status).
5. Cache validated sessions so health polling doesn't hammer Keenetic `/auth`.
6. Baseline hardening: HTTP bound only to the LAN interface (TLS deferred).
7. **De-risk the mihomo TUN assumption with a hardware spike before committing to it.**
8. Do not break the currently-shipping UI during migration.

Non-goals (later phases): subscription parsing, mihomo implementation, device toggling, FakeIP, new UI.
Phase 0 only stubs their endpoints and fixes the schema/contract.

## Decisions (resolved with owner)

- **Cores:** xray and mihomo, **one active at a time**, switchable in the UI (RAM-safe on 256MB).
- **Routing UX:** **separate editors per core** — not a unified abstraction. State is namespaced per
  core; each core has its own routing model and generator.
- **mihomo transparent mode:** **TUN**, but **spike first; tproxy is the fallback** if TUN is not
  viable on KeeneticOS.
- **Transports:** **Reality + XHTTP now**; ws/grpc later. proxyConfig gains a transport abstraction.
- **API routing:** real paths via `PATH_INFO` on one front-controller CGI, not `?kind=`.
- **TLS:** deferred. HTTP + hard LAN-bind now; digest stays server-side. Debt: passwords still travel
  in clear within the LAN until TLS lands.
- **Apply:** asynchronous.
- **UI tech (Phase 6):** build on a dev machine, ship static assets to the router.

## Architecture

### State schema (core-namespaced)

```jsonc
{
  "schemaVersion": 2,
  "activeCore": "xray",            // "xray" | "mihomo"
  "activeProfileId": "profile-1",
  "settings": { "ipv6Mode": "reject" },   // reject | allow (was hardcoded reject)
  "profiles": [
    {
      "id": "profile-1",
      "name": "Profile 1",
      "cores": {
        "xray": {
          "proxyConfig": { "transport": "reality", /* reality|xhttp params */ },
          "muxConfig":   { /* unchanged */ },
          "domainStrategy": "IPIfNonMatch",
          "fallbackOutbound": "direct",
          "groups": [ /* current domains/cidrs -> outboundTag model */ ]
        },
        "mihomo": {
          "proxyConfig": { "transport": "reality" },
          "rules": [],          // Clash-style rules (Phase 2 editor)
          "proxyGroups": []
        }
      }
    }
  ]
}
```

A **migration step** lifts existing flat `proxyConfig`/`groups` into `cores.xray.*` and sets
`activeCore: "xray"`, `schemaVersion: 2`. Old states load unchanged in behavior.

### Components

1. **Core abstraction layer** (`lib/core.sh`): knows the active core, the per-core process set, and
   the per-core runtime/generator. `core_switch <name>`: stop current core's processes + tear down its
   iptables/runtime, then start the target core + bring up its runtime. Only one core runs at a time.

2. **Config generators** (per core):
   - `gen-xray.sh` — `gen_outbounds` + `gen_routing` (jq), byte-equivalent to today's frontend
     builders, **plus XHTTP transport** in `04_outbounds.json` streamSettings.
   - `gen-mihomo.sh` — Phase 1 (stub in Phase 0). Will emit mihomo YAML from `cores.mihomo`.

3. **Runtime layer** (split from `xkeen-runtime.sh`, core-aware):
   - `runtime-xray.sh` — current redirect(61219) + sing-box tproxy(61221) + ipsets. Unchanged behavior.
   - `runtime-mihomo.sh` — Phase 1. TUN by default; tproxy fallback selected by the spike result.

4. **Apply pipeline** (`POST /api/v1/apply`, async): validate state → backup → write state →
   generate active core's config → core's config self-test (`xray -test` / mihomo `-t`) → on success
   restart the active core + rebuild its runtime; on failure roll back. Heavy part runs in background;
   returns `202 {jobId}`. `GET /api/v1/apply/{id}` → `{status: pending|ok|failed, detail}`
   (job file in `/tmp/xkeen-apply-<id>.json`).

5. **Front-controller CGI** routing on `PATH_INFO`, split into sourced handler modules
   (`lib/http.sh`, `lib/auth.sh`, `lib/state.sh`, `lib/core.sh`, `lib/health.sh`, …). Breaks the
   825-line monolith and defines the API. Exact uhttpd `/api/v1/*` → CGI mapping verified on hardware;
   `?kind=` shims retained.

6. **State validation** (`lib/validate.sh`, jq): `schemaVersion`, `activeCore ∈ {xray,mihomo}`,
   non-empty `profiles`, resolvable `activeProfileId`, per-core proxyConfig field/type checks,
   `transport ∈ {reality,xhttp}`, xray group `outboundTag ∈ {vless-reality,direct,bypass}`,
   array/CIDR checks. Reject `400` + reasons before any write. Shared by `PUT /state` and import.

   **Input normalization is a `PUT /state` responsibility, kept OUT of the generators.** The frontend
   normalizes before persisting (`normalizeProfile` dedups/trims domains & cidrs via `uniq()`;
   `normalizeMuxConfig` clamps `xudpConcurrency` to [1,1024] and coerces an invalid `xudpProxyUDP443`
   to `"reject"`). The server-side config generators are pure transforms and do NOT re-normalize, so
   `PUT /state` must apply the same normalization (a `normalize_state` step before validate + persist)
   so state-at-rest is always normalized regardless of client (UI, API, or the owner's backend). Add a
   parity fixture proving the generators match the frontend on a normalized state.

7. **Session cache** (`lib/auth.sh`): cache `hash(cookie) -> expiry` in `/tmp` with 30–60s TTL;
   `require_router_session` hits Keenetic `/auth` only on a miss; logout purges.

8. **Hardening:** uhttpd binds only the LAN bridge (not `0.0.0.0`). jq replaces all `sed`-based JSON
   extraction in new handlers.

### REST API v1 contract

| Group | Endpoint | Phase | Phase 0 behavior |
|-------|----------|-------|------------------|
| Auth | `POST /auth/login`, `/auth/logout`, `GET /auth/session` | 0 | implemented |
| Core | `GET /core` (active + available) | 0 | implemented |
| | `PUT /core` (switch active core) | 0 | xray works; mihomo target → `501` until Phase 2 |
| State | `GET /state`, `PUT /state` (validate + persist) | 0 | implemented |
| | `POST /apply`, `GET /apply/{id}` | 0 | implemented (async, xray) |
| | `GET /config/outbounds`, `/config/routing` | 0 | read derived files |
| Cores/mihomo | `GET/PUT /cores/mihomo/routing` | 1 | `501` stub |
| Subscription | `POST /subscription/parse`, `/subscription/import` | 2 | `501` stub |
| Devices | `GET /devices`, `POST /devices/{mac}/vpn` | 3 | `501` stub |
| Health/diag | `GET /health`, `/stack`, `/logs`; `POST /services/{svc}/restart`, `/runtime/repair`, `/probe` | 0 | implemented |
| Settings | `GET/PUT /settings` (`ipv6Mode` now; FakeIP later) | 0/4 | implemented |

Error envelope: `{ "ok": false, "error": "<code>", "detail": "<msg>" }`. Success: `{ "ok": true, … }`.

### TUN feasibility spike (FIRST task of Phase 0)

On the Giga 1010: check `/dev/net/tun` presence, attempt to load the tun module, run mihomo in TUN
mode, push real traffic through it. Outcome decides `runtime-mihomo.sh`'s default mode:
- **TUN works** → mihomo uses TUN (Phase 2).
- **TUN unavailable** → mihomo uses tproxy (reuse existing TPROXY infra); record the limitation.
This is the only Phase 0 task that touches hardware behavior and it gates Phase 1's design.

## Folded-in bug fixes (from the code review)

1. State write had no schema validation → component 6.
2. Auth round-trip on every request → component 7.
3. Synchronous `killall xray` + ~10s apply holding a worker → component 4.
4. `probe` uses `/opt/bin/nc` not in the install package list → add netcat to `install.sh` (or use a
   built-in connect test) and verify on hardware.
5. Fragile `sed` JSON parsing → jq in new handlers.
6. Plaintext credentials → partially mitigated by LAN-bind; full fix is the deferred TLS phase.
7. IPv6 hardcoded REJECT → now a `settings.ipv6Mode` toggle.

## Migration & backward compatibility

- Existing `?kind=…` endpoints remain as thin shims forwarding to v1, so the shipping UI keeps working
  until the new UI (Phase 6).
- The schema migration (flat → `cores.xray.*`) runs on first load of an old `state.json`.

## Testing strategy

- **Golden parity test (critical):** feed the sample state + crafted states (multiple vless groups,
  direct/bypass mix, empty groups, mux on/off, reality vs xhttp transport) through `gen-xray.sh` and
  compare to `app.js` output, normalized for key order. Must match before migration is safe.
- **Schema-migration test:** an old flat state migrates to v2 and produces identical xray output.
- **Validation unit tests:** valid + each invalid shape returns expected `400` reasons.
- **shellcheck** on all new/modified shell files.
- **On-router integration** (Giga 1010): TUN spike; `PUT /state` → `POST /apply` → poll → confirm
  config self-test passed, xray restarted, routing works; deliberate bad config → rollback; confirm
  LAN-bind (UI unreachable from WAN); measure apply latency / worker behavior.

## Open items to verify on hardware during implementation

- TUN availability for mihomo (the spike) — gates Phase 2.
- uhttpd_kn `PATH_INFO` / CGI mapping for `/api/v1/*` paths.
- netcat package availability for `probe`.
- uhttpd LAN-interface bind syntax on this KeeneticOS build.
