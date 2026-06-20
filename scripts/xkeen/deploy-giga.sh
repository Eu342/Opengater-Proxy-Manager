#!/bin/sh
# Deploy the v2 UI + /api/v1 backend to a Keenetic already running Opengater Proxy Manager,
# over plain SSH exec (tar pipe — no scp/sftp needed on the router).
#
# Reads repo-root .env (gitignored):
#   ROUTER_HOST=192.168.5.1
#   ROUTER_SSH_USER=root
#   ROUTER_SSH_PASSWORD=...
#   ROUTER_SSH_PORT=222
#
# Usage:  sh scripts/xkeen/deploy-giga.sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$ROOT/.env" ] && . "$ROOT/.env"
H="${ROUTER_HOST:-192.168.5.1}"
U="${ROUTER_SSH_USER:-root}"
PT="${ROUTER_SSH_PORT:-222}"
PW="${ROUTER_SSH_PASSWORD:-}"
DEST=/opt/share/xkeen-manager

[ -n "$PW" ] || { echo "ERROR: set ROUTER_SSH_PASSWORD in $ROOT/.env" >&2; exit 1; }
command -v sshpass >/dev/null || { echo "ERROR: sshpass not installed (brew install sshpass)" >&2; exit 1; }

SSHO="-p $PT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
rsh() { sshpass -p "$PW" ssh $SSHO "$U@$H" "$@"; }

echo "==> staging files"
stage="$(mktemp -d)"
mkdir -p "$stage/api/lib/jq" "$stage/api/lib/handlers"
cp "$ROOT/ui-v2/index.html"                              "$stage/index.html"
[ -f "$ROOT/ui-v2/preview/logo.png" ] && cp "$ROOT/ui-v2/preview/logo.png" "$stage/logo.png" || true
cp "$ROOT/ui/xkeen-manager/backend/api.cgi"              "$stage/api/api.cgi"
cp "$ROOT/ui/xkeen-manager/backend/xkeen-runtime.sh"    "$stage/api/xkeen-runtime.sh"
cp "$ROOT/ui/xkeen-manager/backend/xkeen-selfheal.sh"   "$stage/api/xkeen-selfheal.sh"
cp "$ROOT/scripts/xkeen/opm-netfilter-hook.sh"          "$stage/api/opm-netfilter-hook.sh"
cp "$ROOT/ui/xkeen-manager/backend/lib/"*.sh            "$stage/api/lib/"
cp "$ROOT/ui/xkeen-manager/backend/lib/jq/"*.jq         "$stage/api/lib/jq/"
cp "$ROOT/ui/xkeen-manager/backend/lib/handlers/"*.sh   "$stage/api/lib/handlers/"

echo "==> sanity: SSH to $U@$H:$PT"
rsh 'echo connected; uname -m; [ -d /opt/share/xkeen-manager ] && echo "Opengater Proxy Manager present" || echo "WARN: /opt/share/xkeen-manager missing (install Opengater Proxy Manager first)"'

echo "==> pushing $(cd "$stage" && find . -type f | wc -l | tr -d " ") files via tar pipe"
rsh "mkdir -p $DEST/api/lib/jq $DEST/api/lib/handlers; [ -f $DEST/index.html ] && cp $DEST/index.html $DEST/index.html.opg-bak 2>/dev/null || true"
( cd "$stage" && tar czf - . ) | sshpass -p "$PW" ssh $SSHO "$U@$H" \
  "cd $DEST && /opt/bin/tar xzf - && chmod 755 api/api.cgi api/xkeen-runtime.sh api/xkeen-selfheal.sh \
   && mkdir -p /opt/etc/ndm/netfilter.d \
   && cp api/opm-netfilter-hook.sh /opt/etc/ndm/netfilter.d/100-opm.sh && chmod 755 /opt/etc/ndm/netfilter.d/100-opm.sh \
   && chmod 644 index.html && echo extracted"

echo "==> verifying on router"
rsh "ls -la $DEST/api/api.cgi $DEST/index.html; /opt/bin/jq --version 2>/dev/null; /opt/sbin/xray version 2>/dev/null | head -1 || true"

echo "==> restarting UI server"
rsh "[ -x /opt/etc/init.d/S26opm ] && /opt/etc/init.d/S26opm restart >/dev/null 2>&1 || true; sleep 1; netstat -lnpt 2>/dev/null | grep ':8899 ' || true"

rm -rf "$stage"
echo
echo "DONE. Open  http://$H:8899/   (new Opengater UI; API at /api/api.cgi/v1)"
