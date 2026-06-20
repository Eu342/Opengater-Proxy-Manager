# Master VPN power toggle (on/off) — design

**Date:** 2026-06-20
**Status:** Approved (pending spec review)

## Problem

The dashboard power button (`pbtn`) currently just restarts xray. There is no real
on/off: traffic for policy-bound devices always goes through xray. We want a master
switch where:

- **OFF** — all proxied devices behave as if there is no VPN: traffic goes **direct**
  out the ISP, and xray/sing-box are stopped.
- **ON** — xray (and sing-box) run, and devices bound to the Keenetic policy are
  routed through the proxy.

This is global (a master switch), orthogonal to the existing per-device toggles which
decide *which* devices are eligible for proxying.

## Background (how the data path works)

A LAN device bound to the Keenetic policy (`Policy42`, fwmark `0xffffaaa`) has its
packets marked. The nat `xkeen` chain `REDIRECT`s marked TCP to xray's transparent
inbound `:61219`; without that redirect, marked packets fall through to
`ip rule fwmark 0xffffaaa → table 4096 → ISP`, i.e. **direct**. So "turn the VPN off"
= remove the redirect (and stop the daemons); "turn it on" = install the redirect (and
start the daemons). Device policy membership is independent and is preserved across
on/off.

Keenetic rebuilds netfilter on many events and flushes the `xkeen` chain; a
`/opt/etc/ndm/netfilter.d/100-opm.sh` hook and the self-heal loop reinstall it. Both
must learn to respect the master flag, or they will turn the VPN back on after it was
switched off.

## Core invariant

> **xray (and sing-box) running AND the `xkeen` REDIRECT installed ⟺ `vpnEnabled == true`.**

Every component only *maintains* this invariant. Single source of truth:
`state.json → settings.vpnEnabled` (bool, default `true`, persisted, survives reboot).

## Approach (chosen: "flag-gated redirect + daemon lifecycle")

Rejected alternatives:
- *Stop only the daemons, keep the redirect* — redirect to a dead `:61219` causes RST,
  so devices lose internet instead of going direct. ✗
- *Unbind every device from the policy on OFF, rebind on ON* — churns
  `system configuration save` (flash wear), must remember/recreate the device list,
  fragile. The single-redirect toggle is simpler. ✗

## Components

### 1. State schema
- Add `settings.vpnEnabled` (bool).
- Migration: states without the field default to `true` (preserve current behavior —
  VPN on).
- normalize/validate: coerce to bool, default `true`.

### 2. `xkeen-runtime.sh`
- `xkeen_vpn_enabled()` — read `.settings.vpnEnabled` from `STATE_PATH` via jq;
  default `true` (return 0/1).
- `xkeen_teardown_hooks()` — reverse of repair: delete the nat `PREROUTING -j xkeen`
  jump and flush the `xkeen` chain, delete the mangle UDP-route jump, remove the
  IPv6 FORWARD reject for the mark. Result: marked traffic flows normally (direct),
  including IPv6.
- `xkeen_repair_hooks()` — guard at the top:
  `if ! xkeen_vpn_enabled; then xkeen_teardown_hooks; return 0; fi`, then the existing
  install logic. This makes **every** repair path (apply, self-heal, netfilter.d hook)
  honor the flag automatically.

### 3. `xkeen_vpn_sync` (in `xkeen-runtime.sh`) — single enforcement point
Lives in `xkeen-runtime.sh` so every enforcer that already sources it (apply via the
CGI, self-heal, the netfilter.d hook, boot) can call the same logic — no duplication.
Reads the flag and brings the runtime to match:
- **ON:** start xray → start sing-box → verify xray is listening on `:61219` →
  `xkeen_repair_hooks` (install redirect) → flush conntrack. **Order matters:** install
  the redirect only after xray actually listens, else redirect → dead port → RST.
- **OFF:** `xkeen_teardown_hooks` (traffic direct immediately) → stop xray → stop
  sing-box → flush conntrack.

Helper `xkeen_vpn_set <0|1>` writes the flag into `state.json` then calls `xkeen_vpn_sync`.

### 4. self-heal
Guard at the start of its xray/redirect management: if `! xkeen_vpn_enabled`, ensure
xray + sing-box are stopped and hooks torn down, then skip the keep-alive/repair logic.
If enabled, behave as today. (This is what stops the watchdog from re-enabling.)

### 5. netfilter.d hook
No change — it already calls `xkeen_repair_hooks`, which now respects the flag (OFF →
teardown).

### 6. Boot
`S26opm` (or a dedicated init step) calls `xkeen_vpn_sync` on boot so the router comes up
in the saved state: if OFF, xray does not start and the redirect is not installed.
Note: the existing `S24xray` init starts xray unconditionally — it must become
flag-aware (skip start when OFF) or be superseded by `xkeen_vpn_sync`.

### 7. apply pipeline (location change)
Regenerate config + `xray -test` as today, then call `xkeen_vpn_sync`: when ON, restart
xray with the new config and (re)install the redirect; when OFF, leave the config staged
and stay off (it takes effect when the user turns the VPN on).

## API
- `GET /v1/vpn` → `{ok, enabled, xrayRunning, redirectInstalled}`.
- `PUT /v1/vpn {enabled: bool}` → validate bool, `xkeen_vpn_set`, return the resulting
  `{enabled, xrayRunning, redirectInstalled}`.
- `/health` gains `vpnEnabled` so the UI reflects the *intent*, not just "is xray alive".

## Frontend
- `togglePower()` → `PUT /vpn {enabled: !POWER}` (replaces the restart call). Optimistic
  flip + toast "Turning on/off…", then `refreshDash()`.
- `POWER` initializes from `health.vpnEnabled`. OFF → pstate "Off", no uptime timer,
  exit IP "—".
- Per-device toggles: **unchanged** — they bind/unbind the Keenetic policy and stay
  green per actual assignment, independent of the master switch; changes accumulate and
  apply when the VPN is on.

## Error handling
- ON but xray fails to start (bad config): do **not** install the redirect; traffic
  stays direct; return 500 with an `xray failed` detail. Safe default — never break
  internet for proxied devices.
- conntrack flush is best-effort.

## Testing
- **Dev:** `/v1/vpn` GET/PUT routes in `router_test.sh`; schema coverage for
  `vpnEnabled` (migrate default true, normalize, validate).
- **On the Giga:** OFF → assert nat `xkeen` jump removed, xray/sing-box stopped, a
  policy device shows its real ISP IP (direct); ON → redirect back, daemons up, device
  proxied; reboot-with-OFF stays off (manual).

## Out of scope (YAGNI)
No schedules, no per-location on/off, no separate "route everything" mode. The master
switch is a single global boolean.
