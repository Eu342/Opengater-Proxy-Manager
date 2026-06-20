# backend/lib — server-side state & config core

Sourced by the CGI apply path and self-heal. Set `XKEEN_LIB_DIR` to this directory before sourcing
under plain POSIX sh (no `$BASH_SOURCE`); the wrappers fail loudly via `: "${XKEEN_LIB_DIR:?...}"`
if it is unset.

- `state-migrate.sh` → `migrate_state <state-file>`: prints migrated v2 JSON. Idempotent.
- `validate.sh` → `validate_state <state-file>`: exit 0 if valid; else errors to stderr, exit 1.
  Structural shape only — apply-readiness (port/uuid present) is checked in the apply pipeline.
- `gen-xray.sh` → `gen_xray_outbounds <state-file>`, `gen_xray_routing <state-file>`: print the xray
  `04_outbounds.json` / `05_routing.json` content for the active profile's xray core. Supports the
  `reality` and `xhttp` transports (`proxyConfig.transport`).

The generators are **pure transforms of an already-normalized, already-validated state**. Input
normalization (dedup/trim domains & cidrs, clamp `xudpConcurrency`, coerce `xudpProxyUDP443`) — what
the frontend's `normalizeProfile`/`normalizeMuxConfig` do — is a `PUT /state` responsibility added in
Plan 0b (`normalize_state`), not done here. Garbage in → garbage out by design.

Apply pipeline (Plan 0b) order: migrate → normalize → validate → write state → gen_xray_* →
`xray -test` → restart + runtime rebuild, with rollback on failure.

Tests: `sh test/run.sh` from the repo root (also run under `dash` to catch `set -eu` divergences).
Requires `jq`.
