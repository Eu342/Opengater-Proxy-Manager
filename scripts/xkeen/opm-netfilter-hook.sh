#!/bin/sh
# Opengater Proxy Manager — Keenetic netfilter reload hook.
#
# Keenetic rebuilds its netfilter tables on many events: adding/removing a
# device from the VPN policy (i.e. the OPM device toggle itself), WAN
# reconnect, DHCP renew, any config change in the Keenetic web UI, reboot.
# Every rebuild FLUSHES our custom `xkeen` nat REDIRECT chain. Without this
# hook, the rules only return on the next self-heal pass, and in that window
# policy devices leak straight out the ISP (real IP, no VPN).
#
# Keenetic invokes every script in /opt/etc/ndm/netfilter.d/ after a reload,
# passing the affected table/type via the environment (`table`, `type`).
# We defer a single debounced repair until the reconfigure burst settles, so
# we reinstall AFTER Keenetic has finished rebuilding every table.

# Only IPv4 tables carry our rules; ignore ip6tables passes.
[ "${type:-}" = "ip6tables" ] && exit 0
case "${table:-nat}" in
  nat|mangle|filter) ;;
  *) exit 0 ;;
esac

RUNTIME="/opt/share/xkeen-manager/api/xkeen-runtime.sh"
[ -f "$RUNTIME" ] || exit 0

# Debounce: a single reload fires this hook once per table. Schedule the repair
# only on the first call of the burst; later calls in the same burst no-op.
PENDING="/tmp/opm-nf-repair.pending"
[ -f "$PENDING" ] && exit 0
: > "$PENDING"

(
  # Let Keenetic finish rebuilding all tables before we reinstate our rules,
  # otherwise a table rebuilt after us would wipe what we just added.
  sleep 3
  rm -f "$PENDING"
  XKEEN_RUNTIME_LOG="/opt/var/log/xkeen-selfheal.log"
  export XKEEN_RUNTIME_LOG
  # shellcheck disable=SC1090
  . "$RUNTIME"
  xkeen_repair_hooks >/dev/null 2>&1
  xkeen_runtime_log "netfilter.d repair (trigger table=${table:-?} type=${type:-?})"
) >/dev/null 2>&1 &

exit 0
