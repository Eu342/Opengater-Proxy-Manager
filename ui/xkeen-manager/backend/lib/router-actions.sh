# Real router-side side effects for the apply pipeline. api.cgi points
# XKEEN_RESTART_CMD / XKEEN_RUNTIME_CMD at these functions; the unit tests
# override both with `true`, so this file is a no-op off-router.

# Pull in the shared runtime (xkeen_vpn_*/teardown/repair) so the side-effect
# functions and the /v1/vpn handler can reconcile against the master flag.
[ -f /opt/share/xkeen-manager/api/xkeen-runtime.sh ] && . /opt/share/xkeen-manager/api/xkeen-runtime.sh 2>/dev/null || true

# Restart xray so it loads the freshly-generated configs; succeed iff it relistens on 61219.
# When the master VPN switch is OFF, keep xray down instead (apply stages config only).
opm_restart_xray() {
  if command -v xkeen_vpn_enabled >/dev/null 2>&1 && ! xkeen_vpn_enabled; then
    killall xray 2>/dev/null || true
    return 0
  fi
  killall xray 2>/dev/null || true
  rm -f /opt/var/run/xray-ui.pid /opt/var/run/xray.pid 2>/dev/null || true
  sleep 2
  mkdir -p /opt/var/log /opt/var/run 2>/dev/null || true
  XRAY_LOCATION_ASSET=/opt/etc/xray/dat \
  XRAY_LOCATION_CONFDIR="${XKEEN_XRAY_CONFDIR:-/opt/etc/xray/configs}" \
    /opt/sbin/start-stop-daemon -S -b -m -p /opt/var/run/xray-ui.pid -x /opt/sbin/xray -- run \
    >>/opt/var/log/xray-manual.log 2>&1
  # Poll for the redirect inbound to come up rather than a fixed sleep: with more geo
  # categories referenced, xray needs longer to read the .dat files (USB) before it
  # listens. A single short check here caused false "did not come back up" rollbacks.
  _i=0
  while [ "$_i" -lt 20 ]; do
    netstat -lnptu 2>/dev/null | grep -q ':61219 ' && return 0
    sleep 1; _i=$((_i+1))
  done
  return 1
}

# Rebuild the iptables/ipset runtime (xkeen chains + bypass/udp-route sets) from the new state.
# Best-effort: a runtime hiccup must not fail an otherwise-good apply (selfheal will retry).
opm_apply_runtime() {
  ( XKEEN_STATE_PATH="${XKEEN_STATE_PATH:-/opt/share/xkeen-manager/xkeen-ui-state.json}" \
    XKEEN_RUNTIME_LOG="/opt/var/log/xkeen-selfheal.log" \
    . /opt/share/xkeen-manager/api/xkeen-runtime.sh 2>/dev/null && xkeen_repair_hooks ) >/dev/null 2>&1 || true
  return 0
}

# Master VPN on/off for the /v1/vpn handler: write the flag + reconcile runtime.
opm_vpn_set() {
  command -v xkeen_vpn_set >/dev/null 2>&1 && xkeen_vpn_set "$1" >/dev/null 2>&1
  return 0
}
