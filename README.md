# Opengater Proxy Manager

A self-hosted web control panel for running a VPN/proxy on **Keenetic** routers.
It manages [Xray](https://github.com/XTLS/Xray-core) (VLESS · Reality · XHTTP) and
[sing-box](https://github.com/SagerNet/sing-box) directly on the router, with a fast
single-page UI you open from any device on your network.

- 🔌 **One power button** — connect / disconnect the tunnel.
- 🌍 **Subscriptions** — paste a subscription link, pick a location, see live ping.
- 🧭 **Per-device routing** — choose which LAN devices go through the VPN.
- 🛣️ **Routing groups** — send domains/CIDRs through VPN, direct, or bypass.
- 🩺 **Health & logs** — xray / sing-box / self-heal status and tail logs from the UI.
- 📱 Works great on mobile; light & dark themes.

---

## Requirements

- A **Keenetic** router (tested on **Giga KN-1010**) with:
  - a **USB drive** mounted at `/opt`,
  - **Entware / OPKG** enabled (Keenetic web UI → *Applications* → *OPKG*).
- Internet access on the router (to fetch packages and the app).

> The app installs into `/opt/share/xkeen-manager` and serves the UI on port **8899**.

---

## Install (one command)

SSH into the router (or use the Keenetic CLI) and run:

```sh
wget -O - https://raw.githubusercontent.com/Eu342/Opengater-Proxy-Manager/main/install.sh | sh
```

…or download then run:

```sh
wget -O install.sh https://raw.githubusercontent.com/Eu342/Opengater-Proxy-Manager/main/install.sh
sh install.sh
```

The installer is **idempotent** — re-running it upgrades the app without touching your
saved settings or xray configs. It:

1. installs OPKG packages: `ca-bundle curl wget tar gzip jq gawk coreutils-base64 net-tools-netstat cron uhttpd_kn xray iptables ipset conntrack`,
2. installs **sing-box** (default v1.13.8),
3. downloads this repo and lays out the backend + UI under `/opt/share/xkeen-manager`,
4. registers the UI service (`/opt/etc/init.d/S26opm`) and the netfilter hook,
5. starts `uhttpd` on port **8899**.

When it finishes, open:

```
http://<router-ip>:8899/
```

Sign in with your **Keenetic router login and password**.

---

## Updating

Re-run the same install command — it upgrades the sources in place and keeps your
settings:

```sh
wget -O - https://raw.githubusercontent.com/Eu342/Opengater-Proxy-Manager/main/install.sh | sh
```

Force a clean re-seed of default configs (overwrites UI state) with `OPM_FORCE=1`:

```sh
OPM_FORCE=1 sh install.sh
```

> In-UI "check & install updates" is on the roadmap — see [docs](docs/).

### Installer options (env vars)

| Variable | Default | Purpose |
|---|---|---|
| `OPM_UI_PORT` | `8899` | UI listen port |
| `OPM_FORCE` | `0` | `1` re-seeds default configs |
| `SING_BOX_VERSION` | `1.13.8` | sing-box release to install |
| `OPM_REPO_OWNER` / `OPM_REPO_NAME` / `OPM_REPO_BRANCH` | `Eu342` / `Opengater-Proxy-Manager` / `main` | source to install from |

---

## Usage

1. **Add a subscription** — Subscriptions → *Add subscription* → paste your link → *Done*.
2. **Pick a location** — tap a node in the list; the tunnel switches to it.
3. **Connect** — press the power button on the dashboard.
4. **Per-device** — Devices → toggle which clients use the VPN.
5. **Routing** — Routing → enable/disable groups (VPN / direct / bypass).
6. **Ping** — Settings → Ping → choose method (TCP / ICMP / proxy GET·HEAD), test URL, and display (time or signal bars).

---

## Development

Repo layout:

```
ui-v2/index.html        single-file SPA (HTML + CSS + JS)
ui/xkeen-manager/backend/
  api.cgi               front controller (CGI over uhttpd)
  lib/                  POSIX-sh libs: router, handlers/*, session cache, jq generators
install.sh              on-router installer
scripts/xkeen/          deploy + init.d + netfilter hook
configs/xkeen/          sample xray / sing-box / state configs
test/                   POSIX-sh test suite (run.sh)
docs/                   design specs & plans
```

Run the test suite (POSIX sh + jq, no router needed):

```sh
sh test/run.sh
```

Deploy your working copy to a live router over SSH (reads `.env`, see `.env.example`):

```sh
cp .env.example .env       # fill in ROUTER_HOST / ROUTER_SSH_* (gitignored)
sh scripts/xkeen/deploy-giga.sh
```

Quick local UI preview (DEMO mode, no backend):

```sh
node scripts/preview-static.js   # serves ui-v2/ on http://127.0.0.1:8123
```

### Architecture (short)

- **Frontend:** one `index.html`. `render()` rebuilds the view from cached state; data
  refreshes happen in the background so navigation stays instant.
- **Backend:** `api.cgi` is a small front controller; `lib/router.sh` maps
  `METHOD /v1/...` to handler functions in `lib/handlers/*.sh`. State lives in JSON and is
  transformed into xray/sing-box configs by `jq` generators. uhttpd serializes CGI, so
  expensive fan-out work (e.g. probing all nodes) is parallelised server-side.
- **Auth:** the UI validates against the router's own `/auth` (Keenetic digest); a short
  session cache avoids re-validating on every poll.

---

## License

Licensed under the [MIT License](LICENSE).
