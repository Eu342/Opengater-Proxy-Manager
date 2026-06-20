#!/bin/sh
# One-command bring-up of Opengater Proxy Manager on a Keenetic that already has
# Entware (/opt) — straight from this dev machine, no GitHub fork needed.
# Pushes the committed repo tree and runs install.sh with OPM_LOCAL_SRC.
#
# Prerequisite the script cannot do for you: Entware on a USB stick + the Keenetic
# component setup (README "Подготовка Keenetic"). Everything else is automated here.
#
# Reads repo-root .env (gitignored): ROUTER_HOST/ROUTER_SSH_USER/ROUTER_SSH_PASSWORD/ROUTER_SSH_PORT
# Usage:  sh scripts/xkeen/bringup-giga.sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$ROOT/.env" ] && . "$ROOT/.env"
H="${ROUTER_HOST:-192.168.5.1}"
U="${ROUTER_SSH_USER:-root}"
PT="${ROUTER_SSH_PORT:-222}"
PW="${ROUTER_SSH_PASSWORD:-}"

[ -n "$PW" ] || { echo "ERROR: set ROUTER_SSH_PASSWORD in $ROOT/.env" >&2; exit 1; }
command -v sshpass >/dev/null || { echo "ERROR: sshpass not installed (brew install sshpass)" >&2; exit 1; }

SSHO="-p $PT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12"
rsh() { sshpass -p "$PW" ssh $SSHO "$U@$H" "$@"; }

echo "==> assessing router $U@$H:$PT"
rsh 'echo "arch: $(uname -m)"; if [ -x /opt/bin/opkg ]; then echo "Entware: OK"; else echo "Entware: MISSING"; fi' || { echo "SSH failed — check .env creds" >&2; exit 1; }
rsh '[ -x /opt/bin/opkg ]' || { echo; echo "STOP: no Entware on the router. Do the one-time USB/Entware prep first (README), then re-run."; exit 3; }

echo "==> pushing repo (git archive HEAD) to /tmp/opm-src"
rsh "rm -rf /tmp/opm-src && mkdir -p /tmp/opm-src"
( cd "$ROOT" && git archive --format=tar HEAD ) | sshpass -p "$PW" ssh $SSHO "$U@$H" "cd /tmp/opm-src && /opt/bin/tar xf -"

echo "==> running installer with OPM_LOCAL_SRC (this installs packages, sing-box, policy, configs, UI, API)"
rsh "cd /tmp/opm-src && OPM_LOCAL_SRC=/tmp/opm-src /opt/bin/sh install.sh"

echo
echo "DONE. Open  http://$H:8899/   — Opengater Proxy Manager (API at /api/api.cgi/v1)"
