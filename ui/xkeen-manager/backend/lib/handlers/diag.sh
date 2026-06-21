# diag.sh — diagnostic handlers ported from routing.cgi.
# Provides: get_health, get_stack, get_logs, post_probe, post_repair, post_restart
# + helpers: parse_qs_param, valid_probe_address, valid_probe_port, _diag_restart_xray
#
# Design rules:
#   - All handlers end with `return`, never `exit`.
#   - Config paths: ${XKEEN_XRAY_CONFDIR:-/opt/etc/xray/configs}/...
#   - Log paths (/opt/var/log/...) are fixed (router-only).
#   - Tools like netstat/ndmc/iptables/ipset are absent on the dev box; every probe
#     falls back to 0/empty so the response is always syntactically valid JSON.
#   - jq / awk / sed / tail are available on both dev and router.

_DIAG_LOG_PATH="/opt/var/log/xray-manual.log"
_DIAG_XRAY_BIN="/opt/sbin/xray"
_DIAG_SELFHEAL_PATH="/opt/share/xkeen-manager/api/xkeen-selfheal.sh"

# ---------------------------------------------------------------------------
# Helpers (copied from routing.cgi, adapted: /opt/bin/awk -> awk)
# ---------------------------------------------------------------------------

parse_qs_param() {
  _want="$1"
  printf '%s' "${QUERY_STRING:-}" | awk -v want="$_want" '
    {
      count=split($0, parts, "&")
      for (i=1; i<=count; i++) {
        eqpos=index(parts[i], "=")
        if (eqpos == 0) continue
        key=substr(parts[i], 1, eqpos-1)
        val=substr(parts[i], eqpos+1)
        if (key == want) { print val; exit }
      }
    }
  '
}

valid_probe_address() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9.-]+$'
}

valid_probe_port() {
  printf '%s' "$1" | grep -Eq '^[0-9]+$' || return 1
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Internal: get the running xray PID (empty if not running).
_diag_get_xray_pid() {
  _pid="$(netstat -lnpt 2>/dev/null | awk '/:61219 / && /\/xray/ { split($NF, p, "/"); print p[1]; exit }')"
  [ -n "$_pid" ] && { printf '%s\n' "$_pid"; return 0; }
  for _pid in $(pidof xray 2>/dev/null); do
    _cmd="$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null || true)"
    case "$_cmd" in *" -test "*) continue ;; esac
    printf '%s\n' "$_pid"
    return 0
  done
}

# Internal: restart xray (router-only; no-op / false on dev box).
_diag_restart_xray() {
  killall xray 2>/dev/null || true
  rm -f /opt/var/run/xray-ui.pid /opt/var/run/xray.pid 2>/dev/null || true
  sleep 2
  XRAY_LOCATION_ASSET=/opt/etc/xray/dat XRAY_LOCATION_CONFDIR=/opt/etc/xray/configs \
    /opt/sbin/start-stop-daemon -S -b -m -p /opt/var/run/xray-ui.pid -x "$_DIAG_XRAY_BIN" \
    -- run >>"$_DIAG_LOG_PATH" 2>&1
  sleep 3
  netstat -lnptu 2>/dev/null | grep -q '61219'
}

# ---------------------------------------------------------------------------
# get_health  ←  emit_health
# ---------------------------------------------------------------------------
# _diag_resolve_cached <host> -> IPv4, memoized ~2 min in tmpfs. nslookup is ~600ms
# and BOTH get_health and get_stack need the VPN host IP, so share one lookup.
_diag_resolve_cached() {
  [ -n "$1" ] || return 0
  _rc="/tmp/opm-vpnip.cache"; _rnow="$(date +%s 2>/dev/null || echo 0)"
  if [ -f "$_rc" ]; then
    _rts="$(sed -n 1p "$_rc" 2>/dev/null)"; _rhost="$(sed -n 2p "$_rc" 2>/dev/null)"
    case "$_rts" in ''|*[!0-9]*) _rts=0 ;; esac
    if [ "$_rhost" = "$1" ] && [ $(( _rnow - _rts )) -lt 120 ]; then
      sed -n 3p "$_rc" 2>/dev/null; return 0
    fi
  fi
  _rip="$(nslookup "$1" 2>/dev/null | awk '/^Name:/{seen=1;next} seen&&/^Address [0-9]+:/{print $3;exit} seen&&/^Address:/{print $2;exit}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
  printf '%s\n%s\n%s\n' "$_rnow" "$1" "$_rip" > "$_rc" 2>/dev/null || true
  printf '%s' "$_rip"
}

get_health() {
  _xray_pid="$(_diag_get_xray_pid)"
  _sb_pid="$(pidof sing-box 2>/dev/null | awk '{ print $1 }')"
  _sh_pid="$(cat /opt/var/run/opm-selfheal-loop.pid 2>/dev/null | awk 'NR==1 && $0 ~ /^[0-9]+$/ { print }')"
  if [ -n "$_sh_pid" ] && ! kill -0 "$_sh_pid" 2>/dev/null; then
    _sh_pid=""
  fi

  _xray_tcp=0
  netstat -lnpt 2>/dev/null | grep -q ':61219 ' && _xray_tcp=1
  _xray_relay=0
  netstat -lnpu 2>/dev/null | grep -q '127.0.0.1:62640 ' && _xray_relay=1
  _sb_listen=0
  netstat -lnpu 2>/dev/null | grep -q ':61221 ' && _sb_listen=1

  _tproxy_end=0
  iptables -t mangle -S PREROUTING 2>/dev/null | tail -1 | grep -q 'xkeen_udp_route' && _tproxy_end=1
  _ip_rule=0
  ip rule show 2>/dev/null | grep -qE 'fwmark 0x111/0x111 (lookup|table) 111' && _ip_rule=1
  _udp_ipset=0
  ipset list xkeen_udp_route -terse >/dev/null 2>&1 && _udp_ipset=1
  _bypass_ipset=0
  ipset list xkeen_bypass -terse >/dev/null 2>&1 && _bypass_ipset=1

  _udp_ipset_sz=0
  if [ "$_udp_ipset" = "1" ]; then
    _udp_ipset_sz="$(ipset list xkeen_udp_route 2>/dev/null | awk '/^Members:/ { m=1; next } m && NF { c++ } END { print c+0 }')"
  fi
  _bypass_ipset_sz=0
  if [ "$_bypass_ipset" = "1" ]; then
    _bypass_ipset_sz="$(ipset list xkeen_bypass 2>/dev/null | awk '/^Members:/ { m=1; next } m && NF { c++ } END { print c+0 }')"
  fi

  _xray_fd=0; _xray_fd_lim=0
  if [ -n "$_xray_pid" ] && [ -d "/proc/$_xray_pid/fd" ]; then
    _xray_fd="$(ls "/proc/$_xray_pid/fd" 2>/dev/null | wc -l | tr -d ' ')"
    _xray_fd_lim="$(grep 'Max open files' "/proc/$_xray_pid/limits" 2>/dev/null | awk '{ print $4; exit }')"
    case "$_xray_fd_lim" in ''|unlimited) _xray_fd_lim=0 ;; esac
  fi
  case "$_xray_fd"     in ''|*[!0-9]*) _xray_fd=0 ;; esac
  case "$_xray_fd_lim" in ''|*[!0-9]*) _xray_fd_lim=0 ;; esac

  # real xray process uptime (seconds) = system uptime - process start time
  _xray_uptime=0
  if [ -n "$_xray_pid" ] && [ -r "/proc/$_xray_pid/stat" ]; then
    _st="$(awk '{print $22}' "/proc/$_xray_pid/stat" 2>/dev/null)"
    _hz="$(getconf CLK_TCK 2>/dev/null || echo 100)"
    _bootup="$(awk '{print int($1)}' /proc/uptime 2>/dev/null)"
    case "$_st"     in ''|*[!0-9]*) _st=0 ;; esac
    case "$_hz"     in ''|*[!0-9]*) _hz=100 ;; esac
    case "$_bootup" in ''|*[!0-9]*) _bootup=0 ;; esac
    [ "$_st" -gt 0 ] && _xray_uptime=$(( _bootup - _st / _hz ))
    [ "$_xray_uptime" -lt 0 ] && _xray_uptime=0
  fi

  _ct_count="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || printf '0')"
  _ct_max="$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || printf '0')"
  case "$_ct_count" in ''|*[!0-9]*) _ct_count=0 ;; esac
  case "$_ct_max"   in ''|*[!0-9]*) _ct_max=0 ;; esac

  _vpn_host=""; _vpn_port=0; _vpn_ip=""
  _vpn_est=0; _vpn_fin=0; _vpn_orphan=0; _vpn_total=0
  _ob_file="${XKEEN_XRAY_CONFDIR:-/opt/etc/xray/configs}/04_outbounds.json"
  if [ -f "$_ob_file" ] && command -v jq >/dev/null 2>&1; then
    _vpn_host="$(jq -r '.outbounds[]?|select(.tag=="vless-reality")|.settings.vnext[0].address // ""' "$_ob_file" 2>/dev/null | head -1)"
    _vpn_port="$(jq -r '.outbounds[]?|select(.tag=="vless-reality")|.settings.vnext[0].port // 0' "$_ob_file" 2>/dev/null | head -1)"
  fi
  case "$_vpn_port" in ''|*[!0-9]*) _vpn_port=0 ;; esac
  if [ -n "$_vpn_host" ] && [ "$_vpn_port" -gt 0 ]; then
    _vpn_ip="$(_diag_resolve_cached "$_vpn_host")"
  fi
  if [ -n "$_xray_pid" ] && [ -n "$_vpn_ip" ] && [ "$_vpn_port" -gt 0 ]; then
    _sock_lines="$(netstat -anp 2>/dev/null | grep "${_xray_pid}/xray" | grep "${_vpn_ip}:${_vpn_port}")"
    _vpn_total="$(printf '%s\n' "$_sock_lines" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
    _vpn_est="$(printf '%s\n' "$_sock_lines" | grep -c 'ESTABLISHED' || true)"
    _vpn_fin="$(printf '%s\n' "$_sock_lines" | grep -cE 'FIN_WAIT1|FIN_WAIT2' || true)"
    _vpn_orphan="$(netstat -anp 2>/dev/null | grep "${_vpn_ip}:${_vpn_port}" | grep -E 'FIN_WAIT1|FIN_WAIT2' | grep -c '[[:space:]]-[[:space:]]*$' || true)"
  fi
  case "$_vpn_est"    in ''|*[!0-9]*) _vpn_est=0 ;; esac
  case "$_vpn_fin"    in ''|*[!0-9]*) _vpn_fin=0 ;; esac
  case "$_vpn_orphan" in ''|*[!0-9]*) _vpn_orphan=0 ;; esac
  case "$_vpn_total"  in ''|*[!0-9]*) _vpn_total=0 ;; esac

  # Health status (mirrors selfheal thresholds)
  _hst="ok"
  if [ -z "$_xray_pid" ]; then
    _hst="xray_down"
  elif [ "$_xray_fd" -ge 600 ]; then
    _hst="fd_critical"
  elif [ "$_vpn_orphan" -ge 30 ]; then
    _hst="vpn_orphan_fin_critical"
  elif [ "$_vpn_fin" -ge 50 ]; then
    _hst="vpn_fin_critical"
  elif [ "$_xray_fd" -ge 400 ]; then
    _hst="fd_warn"
  elif [ "$_vpn_orphan" -ge 20 ]; then
    _hst="vpn_orphan_fin_warn"
  elif [ "$_vpn_fin" -ge 20 ]; then
    _hst="vpn_fin_warn"
  fi
  if [ "$_ct_max" -gt 0 ]; then
    _ct_pct=$(( _ct_count * 100 / _ct_max ))
    if [ "$_ct_pct" -ge 95 ] && [ "$_hst" = "ok" ]; then _hst="conntrack_critical"; fi
    if [ "$_ct_pct" -ge 85 ] && [ "$_hst" = "ok" ]; then _hst="conntrack_warn"; fi
  fi

  _xray_run=$([ -n "$_xray_pid" ] && printf 'true' || printf 'false')
  _sb_run=$([ -n "$_sb_pid" ] && printf 'true' || printf 'false')
  _sh_run=$([ -n "$_sh_pid" ] && printf 'true' || printf 'false')
  _vpn_en="$(jq -r '.settings.vpnEnabled' "${XKEEN_STATE_PATH:-/opt/share/xkeen-manager/xkeen-ui-state.json}" 2>/dev/null)"; [ "$_vpn_en" = "false" ] || _vpn_en=true
  _opm_has_subscription || _vpn_en=false   # no subscription -> VPN not enabled

  _payload="$(jq -n \
    --argjson vpn_enabled "$_vpn_en" \
    --argjson xray_run "$_xray_run" \
    --arg xray_pid "${_xray_pid:-}" \
    --argjson xray_tcp "$_xray_tcp" \
    --argjson xray_relay "$_xray_relay" \
    --argjson sb_run "$_sb_run" \
    --arg sb_pid "${_sb_pid:-}" \
    --argjson sb_listen "$_sb_listen" \
    --argjson sh_run "$_sh_run" \
    --arg sh_pid "${_sh_pid:-}" \
    --argjson tproxy_end "$_tproxy_end" \
    --argjson ip_rule_masked "$_ip_rule" \
    --argjson udp_ipset_ok "$_udp_ipset" \
    --argjson bypass_ipset_ok "$_bypass_ipset" \
    --argjson udp_ipset_size "$_udp_ipset_sz" \
    --argjson bypass_ipset_size "$_bypass_ipset_sz" \
    --argjson xray_fd "$_xray_fd" \
    --argjson xray_fd_limit "$_xray_fd_lim" \
    --argjson xray_uptime "$_xray_uptime" \
    --argjson ct_count "$_ct_count" \
    --argjson ct_max "$_ct_max" \
    --argjson vpn_established "$_vpn_est" \
    --argjson vpn_fin_wait "$_vpn_fin" \
    --argjson vpn_orphan_fin "$_vpn_orphan" \
    --argjson vpn_total "$_vpn_total" \
    --arg vpn_host "${_vpn_host:-}" \
    --arg health_status "$_hst" \
    '{
      ok: true,
      healthStatus: $health_status,
      vpnEnabled: $vpn_enabled,
      services: {
        xray:    { running: $xray_run, pid: $xray_pid, listenTcp: ($xray_tcp == 1), listenRelayUdp: ($xray_relay == 1) },
        singbox: { running: $sb_run, pid: $sb_pid, listenUdp: ($sb_listen == 1) },
        selfheal:{ running: $sh_run, pid: $sh_pid }
      },
      checks: {
        tproxyRuleAtEnd: ($tproxy_end == 1),
        ipRuleMasked:    ($ip_rule_masked == 1),
        udpIpsetExists:  ($udp_ipset_ok == 1),
        bypassIpsetExists: ($bypass_ipset_ok == 1)
      },
      ipsetSize: { udpRoute: $udp_ipset_size, bypass: $bypass_ipset_size },
      xrayFd: { count: $xray_fd, limit: $xray_fd_limit },
      xrayUptimeSec: $xray_uptime,
      conntrack: { count: $ct_count, max: $ct_max },
      vpnTunnel: {
        host: $vpn_host,
        established: $vpn_established,
        finWait: $vpn_fin_wait,
        orphanFin: $vpn_orphan_fin,
        total: $vpn_total
      }
    }')"

  printf 'Status: 200 OK\r\n'
  printf 'Content-Type: application/json; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n'
  printf '\r\n'
  printf '%s\n' "$_payload"
}

# ---------------------------------------------------------------------------
# get_stack  ←  emit_stack_info
# ---------------------------------------------------------------------------
get_stack() {
  _kernel="$(uname -r 2>/dev/null)"
  _hostname="$(uname -n 2>/dev/null)"
  # versions + model are static between upgrades; cache ~1h in tmpfs. `xray version`
  # and especially `sing-box version` cold-start ~200ms/~600ms; model from ndmc.
  _vc="/tmp/opm-stack-static.cache"; _vnow="$(date +%s 2>/dev/null || echo 0)"
  _vts="$(sed -n 1p "$_vc" 2>/dev/null)"; case "$_vts" in ''|*[!0-9]*) _vts=0 ;; esac
  if [ -f "$_vc" ] && [ $(( _vnow - _vts )) -lt 3600 ]; then
    _xray_ver="$(sed -n 2p "$_vc")"; _sb_ver="$(sed -n 3p "$_vc")"; _model="$(sed -n 4p "$_vc")"
  else
    _xray_ver="$(/opt/sbin/xray version 2>/dev/null | head -n 1 | awk '{print $2}')"
    _sb_ver="$(/opt/sbin/sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')"
    _model="$(ndmc -c 'show version' 2>/dev/null | awk -F': ' '/^[[:space:]]*description:/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')"
    printf '%s\n%s\n%s\n%s\n' "$_vnow" "$_xray_ver" "$_sb_ver" "$_model" > "$_vc" 2>/dev/null || true
  fi
  _uptime="$(awk '{ printf "%d", int($1) }' /proc/uptime 2>/dev/null)"
  case "$_uptime" in ''|*[!0-9]*) _uptime=0 ;; esac

  _ob_file="${XKEEN_XRAY_CONFDIR:-/opt/etc/xray/configs}/04_outbounds.json"
  _vpn_host=""; _vpn_port=0; _vpn_sni=""; _vpn_ip=""
  if [ -f "$_ob_file" ] && command -v jq >/dev/null 2>&1; then
    _vpn_host="$(jq -r '.outbounds[]?|select(.tag=="vless-reality")|.settings.vnext[0].address // ""' "$_ob_file" 2>/dev/null)"
    _vpn_port="$(jq -r '.outbounds[]?|select(.tag=="vless-reality")|.settings.vnext[0].port // 0' "$_ob_file" 2>/dev/null)"
    _vpn_sni="$(jq -r '.outbounds[]?|select(.tag=="vless-reality")|.streamSettings.realitySettings.serverName // ""' "$_ob_file" 2>/dev/null)"
  fi
  case "$_vpn_port" in ''|*[!0-9]*) _vpn_port=0 ;; esac
  if [ -n "$_vpn_host" ]; then
    _vpn_ip="$(_diag_resolve_cached "$_vpn_host")"
  fi

  _wan_iface="$(ip route show default 2>/dev/null | awk '/^default/{print $5; exit}')"
  _wan_ip=""
  if [ -n "$_wan_iface" ]; then
    _wan_ip="$(ip addr show "$_wan_iface" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)"
  fi
  _gw="$(ip route show default 2>/dev/null | awk '/^default/{print $3; exit}')"
  _lan_net="$(ip route show 2>/dev/null | awk '/scope link/ && /^(192\.168\.|10\.|172\.)/ {print $1; exit}')"

  _policy_block="$(ndmc -c 'show ip policy' 2>/dev/null)"
  _policy_line="$(printf '%s\n' "$_policy_block" | grep 'description.*xkeen' | head -n 1)"
  _policy_name="$(printf '%s' "$_policy_line" | sed -n 's/.*name *= *\([^,]*\).*/\1/p' | sed 's/[[:space:]]*$//')"
  _policy_desc="$(printf '%s' "$_policy_line" | sed -n 's/.*description *= *\([^,]*\).*/\1/p' | sed 's/[[:space:]]*$//' | sed 's/:[[:space:]]*$//' | sed 's/^xkeen:[[:space:]]*//' | sed 's/^xkeen$//')"
  if [ -z "$_policy_name" ]; then
    _policy_name="$(printf '%s\n' "$_policy_block" | awk '/^[[:space:]]*name:/{n=$2} /description.*xkeen/{print n; exit}')"
  fi
  if [ -z "$_policy_desc" ]; then
    _policy_desc="$(printf '%s\n' "$_policy_block" | awk -F ': ' '/description.*xkeen/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')"
  fi
  _xkeen_mark="$(printf '%s\n' "$_policy_block" | awk '
    /description.*xkeen/ { want=1; next }
    want && /mark/ { gsub(/[[:space:]]/,"",$0); split($0,a,":"); print a[2]; exit }
  ')"

  _mem_avail="$(grep '^MemAvailable:' /proc/meminfo 2>/dev/null | awk '{print $2}')"
  _mem_total="$(grep '^MemTotal:'     /proc/meminfo 2>/dev/null | awk '{print $2}')"
  _disk_line="$(df -k /opt 2>/dev/null | tail -n 1)"
  _disk_total="$(printf '%s' "$_disk_line" | awk '{print $2}')"
  _disk_used="$(printf '%s' "$_disk_line"  | awk '{print $3}')"
  _disk_avail="$(printf '%s' "$_disk_line" | awk '{print $4}')"
  _disk_mount="$(printf '%s' "$_disk_line" | awk '{print $NF}')"
  _ct_count="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || printf '0')"
  _ct_max="$(cat /proc/sys/net/netfilter/nf_conntrack_max   2>/dev/null || printf '0')"
  _xray_pid_s="$(_diag_get_xray_pid)"
  _xray_fd_s=0; _xray_fd_lim_s=0
  if [ -n "$_xray_pid_s" ] && [ -d "/proc/$_xray_pid_s/fd" ]; then
    _xray_fd_s="$(ls "/proc/$_xray_pid_s/fd" 2>/dev/null | wc -l | tr -d ' ')"
    _xray_fd_lim_s="$(grep 'Max open files' "/proc/$_xray_pid_s/limits" 2>/dev/null | awk '{print $4}')"
  fi
  case "$_mem_avail"    in ''|*[!0-9]*) _mem_avail=0 ;; esac
  case "$_mem_total"    in ''|*[!0-9]*) _mem_total=0 ;; esac
  case "$_ct_count"     in ''|*[!0-9]*) _ct_count=0 ;; esac
  case "$_ct_max"       in ''|*[!0-9]*) _ct_max=0 ;; esac
  case "$_xray_fd_s"    in ''|*[!0-9]*) _xray_fd_s=0 ;; esac
  case "$_xray_fd_lim_s" in ''|*[!0-9]*) _xray_fd_lim_s=0 ;; esac
  case "$_disk_total"   in ''|*[!0-9]*) _disk_total=0 ;; esac
  case "$_disk_used"    in ''|*[!0-9]*) _disk_used=0 ;; esac
  case "$_disk_avail"   in ''|*[!0-9]*) _disk_avail=0 ;; esac

  _payload="$(jq -n \
    --arg xray_ver "$_xray_ver" \
    --arg sb_ver "$_sb_ver" \
    --arg kernel "$_kernel" \
    --arg hostname "$_hostname" \
    --arg model "${_model:-}" \
    --argjson uptime_sec "$_uptime" \
    --arg vpn_host "${_vpn_host:-}" \
    --argjson vpn_port "$_vpn_port" \
    --arg vpn_sni "${_vpn_sni:-}" \
    --arg vpn_ip "${_vpn_ip:-}" \
    --arg wan_iface "${_wan_iface:-}" \
    --arg wan_ip "${_wan_ip:-}" \
    --arg lan_net "${_lan_net:-}" \
    --arg gw "${_gw:-}" \
    --arg policy_name "${_policy_name:-}" \
    --arg policy_desc "${_policy_desc:-}" \
    --arg xkeen_mark "${_xkeen_mark:-}" \
    --argjson mem_avail_kb "$_mem_avail" \
    --argjson mem_total_kb "$_mem_total" \
    --argjson ct_count "$_ct_count" \
    --argjson ct_max "$_ct_max" \
    --argjson xray_fd "$_xray_fd_s" \
    --argjson xray_fd_limit "$_xray_fd_lim_s" \
    --argjson disk_total_kb "$_disk_total" \
    --argjson disk_used_kb "$_disk_used" \
    --argjson disk_avail_kb "$_disk_avail" \
    --arg disk_mount "${_disk_mount:-}" \
    '{
      ok: true,
      versions: { xray: $xray_ver, singbox: $sb_ver, kernel: $kernel, hostname: $hostname, model: $model, uptimeSec: $uptime_sec },
      vpn:      { host: $vpn_host, port: $vpn_port, sni: $vpn_sni, exitIp: $vpn_ip },
      network:  { wanIface: $wan_iface, wanIp: $wan_ip, gateway: $gw, lanNet: $lan_net },
      xkeen:    { policyName: $policy_name, policyDescription: $policy_desc, mark: $xkeen_mark, tproxyUdp: 61221, redirectTcp: 61219, ssRelay: "127.0.0.1:62640" },
      runtime:  { selfhealIntervalSec: 15, logRotateInterval: "daily", backupRetention: 5, fdWarn: 400, fdCritical: 600 },
      resources:{ memAvailKb: $mem_avail_kb, memTotalKb: $mem_total_kb, conntrackCount: $ct_count, conntrackMax: $ct_max, xrayFd: $xray_fd, xrayFdLimit: $xray_fd_limit, diskTotalKb: $disk_total_kb, diskUsedKb: $disk_used_kb, diskAvailKb: $disk_avail_kb, diskMount: $disk_mount }
    }')"

  printf 'Status: 200 OK\r\n'
  printf 'Content-Type: application/json; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n'
  printf '\r\n'
  printf '%s\n' "$_payload"
}

# ---------------------------------------------------------------------------
# get_logs  ←  emit_logs  (reads svc + n from QUERY_STRING)
# ---------------------------------------------------------------------------
get_logs() {
  _svc="$(parse_qs_param svc)"
  _n="$(parse_qs_param n)"
  case "$_n" in ''|*[!0-9]*) _n=100 ;; esac
  if [ "$_n" -gt 1000 ]; then _n=1000; fi

  case "$_svc" in
    xray)     _log="/opt/var/log/xray/error.log" ;;
    xray-run) _log="/opt/var/log/xray-manual.log" ;;
    singbox)  _log="/opt/var/log/sing-box-xkeen.log" ;;
    selfheal) _log="/opt/var/log/xkeen-selfheal.log" ;;
    health)   _log="/opt/var/log/xkeen-health.log" ;;
    sysctl)   _log="/opt/var/log/xkeen-sysctl.log" ;;
    fd-dump)
      _log="$(ls -t /opt/var/log/xray-fd-dump-*.txt 2>/dev/null | head -n 1)"
      ;;
    *)
      printf 'Status: 500 Internal Server Error\r\n'
      printf 'Content-Type: application/json; charset=utf-8\r\n'
      printf 'Cache-Control: no-store\r\n'
      printf '\r\n'
      printf '{"ok":false,"error":"unknown svc"}\n'
      return
      ;;
  esac

  printf 'Status: 200 OK\r\n'
  printf 'Content-Type: text/plain; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n'
  printf '\r\n'
  if [ -z "$_log" ]; then
    printf '(no fd-dump file present yet — none has been triggered since boot)\n'
  elif [ -f "$_log" ]; then
    if [ "$_svc" = "fd-dump" ]; then
      printf '# %s\n\n' "$_log"
      cat "$_log" 2>/dev/null
    else
      tail -n "$_n" "$_log" 2>/dev/null
    fi
  else
    printf '(log file %s does not exist)\n' "$_log"
  fi
}

# ---------------------------------------------------------------------------
# post_probe  ←  kind=probe POST block
# ---------------------------------------------------------------------------
# _url_hostport <url> -> "host port"  (port defaults by scheme; path stripped)
_url_hostport() {
  _u="$1"
  case "$_u" in
    https://*) _defp=443; _u="${_u#https://}" ;;
    http://*)  _defp=80;  _u="${_u#http://}"  ;;
    *)         _defp=443 ;;
  esac
  _u="${_u%%/*}"
  case "$_u" in
    *:*) printf '%s %s' "${_u%%:*}" "${_u##*:}" ;;
    *)   printf '%s %s' "$_u" "$_defp" ;;
  esac
}

# _probe_ms <addr> <port> <proto> <url> -> '{"ms":N}' or 'null'.
# Whatever the user picked in Settings -> Ping is what runs, per node:
#   tcp        TCP connect latency to the node (time_connect, before the hanging
#              reality TLS; max-time just caps the wasted tail).
#   icmp       ICMP round-trip (avg) to the node address.
#   proxy-get  GET  the test URL with the TCP connection pinned to this node.
#   proxy-head HEAD the test URL with the TCP connection pinned to this node.
_probe_ms() {
  [ -n "$1" ] || { printf 'null'; return; }
  _pma="$1"; _pmp="${2:-443}"; _pmproto="${3:-tcp}"; _pmurl="$4"
  case "$_pmproto" in
    icmp)
      _ct="$(/opt/bin/ping -c 1 -W 2 "$_pma" 2>/dev/null | sed -n 's#.* = [0-9.]*/\([0-9.]*\)/.*#\1#p')"
      case "$_ct" in ''|0|0.0) printf 'null'; return ;; esac
      _ms="$(/opt/bin/awk "BEGIN{printf \"%d\", $_ct+0.5}" 2>/dev/null)"
      ;;
    proxy-get|proxy-head)
      set -- $(_url_hostport "$_pmurl"); _uh="$1"; _up="$2"
      [ -n "$_uh" ] || { printf 'null'; return; }
      _hd=""; [ "$_pmproto" = "proxy-head" ] && _hd="-I"
      # Record the TCP connect to the node (fast + stable). A full GET/HEAD through
      # the node reaches its real upstream and is 2-4x slower and highly variable,
      # and the TLS handshake to the node's masquerade is slower still -- neither is
      # a usable per-node indicator. So we issue the GET/HEAD (-I for HEAD, via the
      # test URL) but time the connect, capped by max-time. -k: cert won't match.
      _ct="$(/opt/bin/curl -s -k -o /dev/null $_hd -A 'Happ' --connect-to "$_uh:$_up:$_pma:$_pmp" -w '%{time_connect}' --connect-timeout 3 --max-time 4 "$_pmurl" 2>/dev/null)"
      case "$_ct" in ''|0|0.000000) printf 'null'; return ;; esac
      _ms="$(/opt/bin/awk "BEGIN{printf \"%d\", $_ct*1000}" 2>/dev/null)"
      ;;
    *)
      _ct="$(/opt/bin/curl -s -o /dev/null -w '%{time_connect}' --connect-timeout 3 --max-time 3 "https://$_pma:$_pmp" 2>/dev/null)"
      case "$_ct" in ''|0|0.000000) printf 'null'; return ;; esac
      _ms="$(/opt/bin/awk "BEGIN{printf \"%d\", $_ct*1000}" 2>/dev/null)"
      ;;
  esac
  case "$_ms" in ''|*[!0-9]*) printf 'null'; return ;; esac
  [ "$_ms" -le 0 ] && { printf 'null'; return; }
  printf '{"ms":%s}' "$_ms"
}

# POST /v1/probe/batch  {targets:[{address,port}...]}  -> {results:[{ms}|null...]}
# Fans out all probes in parallel on the router (uhttpd serializes CGI, so one
# request doing the fan-out is far faster than N separate /probe calls).
post_probe_batch() {
  _pb="$(cat)"
  _pn="$(printf '%s' "$_pb" | jq '.targets|length' 2>/dev/null)"
  case "$_pn" in ''|*[!0-9]*) _pn=0 ;; esac
  [ "$_pn" -gt 0 ] || { http_ok '{"ok":true,"results":[]}'; return; }
  [ "$_pn" -gt 64 ] && _pn=64
  _proto="$(printf '%s' "$_pb" | jq -r '.proto // "tcp"')"
  case "$_proto" in proxy-get|proxy-head|tcp|icmp) : ;; *) _proto=tcp ;; esac
  _url="$(printf '%s' "$_pb" | jq -r '.url // ""')"
  case "$_url" in http://*|https://*) : ;; *) _url='https://www.gstatic.com/generate_204' ;; esac
  _pd="$(mktemp -d)"
  _pi=0
  while [ "$_pi" -lt "$_pn" ]; do
    _pa="$(printf '%s' "$_pb" | jq -r ".targets[$_pi].address // empty")"
    _pp="$(printf '%s' "$_pb" | jq -r ".targets[$_pi].port // 443")"
    case "$_pp" in ''|*[!0-9]*) _pp=443 ;; esac
    ( _probe_ms "$_pa" "$_pp" "$_proto" "$_url" > "$_pd/$_pi" ) &
    _pi=$((_pi+1))
  done
  wait
  _pi=0; : > "$_pd/all"
  while [ "$_pi" -lt "$_pn" ]; do { cat "$_pd/$_pi" 2>/dev/null || printf 'null'; printf '\n'; } >> "$_pd/all"; _pi=$((_pi+1)); done
  _pres="$(jq -s '.' "$_pd/all" 2>/dev/null)"
  rm -rf "$_pd"
  case "$_pres" in '['*) : ;; *) _pres='[]' ;; esac
  http_ok "$(jq -n --argjson r "$_pres" '{ok:true,results:$r}')"
}

post_probe() {
  _body="$(mktemp)"; cat > "$_body"
  _addr="$(sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_body" | head -n 1)"
  _port="$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_body" | head -n 1)"
  rm -f "$_body"

  if [ -z "$_addr" ] || [ -z "$_port" ] || \
     ! valid_probe_address "$_addr" || ! valid_probe_port "$_port"; then
    printf 'Status: 400 Bad Request\r\n'
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf '\r\n'
    printf '{"ok":false,"error":"invalid probe payload"}\n'
    return
  fi

  _rip="$(nslookup "$_addr" 2>/dev/null | awk '/^Address [0-9]*: /{print $3} /^Address: /{print $2}' | tail -n 1)"
  if printf '' | nc "$_addr" "$_port" >/dev/null 2>&1; then
    printf 'Status: 200 OK\r\n'
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf '\r\n'
    printf '{"ok":true,"address":"%s","port":%s,"resolvedIp":"%s"}\n' "$_addr" "$_port" "${_rip:-}"
  else
    printf 'Status: 500 Internal Server Error\r\n'
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf '\r\n'
    printf '{"ok":false,"error":"tcp connect failed"}\n'
  fi
}

# ---------------------------------------------------------------------------
# post_repair  ←  repair_runtime  (repair-runtime POST block)
# ---------------------------------------------------------------------------
post_repair() {
  if [ -x "$_DIAG_SELFHEAL_PATH" ]; then
    "$_DIAG_SELFHEAL_PATH" --force >/dev/null 2>&1
    _rc=$?
  elif command -v xkeen_repair_hooks >/dev/null 2>&1; then
    if xkeen_repair_hooks 2>/dev/null && _diag_restart_xray 2>/dev/null; then
      _rc=0
    else
      _rc=1
    fi
  else
    _rc=1
  fi

  if [ "$_rc" -eq 0 ]; then
    printf 'Status: 200 OK\r\n'
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf '\r\n'
    printf '{"ok":true,"message":"runtime restored"}\n'
  else
    printf 'Status: 500 Internal Server Error\r\n'
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf '\r\n'
    printf '{"ok":false,"error":"failed to restore xkeen/xray runtime"}\n'
  fi
}

# ---------------------------------------------------------------------------
# post_restart  ←  restart_service  (svc read from PATH_INFO, not body)
# ---------------------------------------------------------------------------
# GET /v1/services/xray/loglevel -> {level}
get_loglevel() {
  _lf="${XKEEN_XRAY_CONFDIR:-/opt/etc/xray/configs}/01_log.json"
  _lvl="$(jq -r '.log.loglevel // "warning"' "$_lf" 2>/dev/null)"
  case "$_lvl" in none|error|warning|info|debug) : ;; *) _lvl="warning" ;; esac
  http_ok "$(jq -n --arg l "$_lvl" '{ok:true,level:$l}')"
}

# PUT /v1/services/xray/loglevel  {level:"none|error|warning|info|debug"}
# writes 01_log.json then restarts xray to apply.
put_loglevel() {
  _lvl="$(cat | jq -r '.level // empty' 2>/dev/null)"
  case "$_lvl" in
    none|error|warning|info|debug) : ;;
    *) http_error 400 bad_request "level must be none|error|warning|info|debug"; return ;;
  esac
  _lf="${XKEEN_XRAY_CONFDIR:-/opt/etc/xray/configs}/01_log.json"
  _new="$(jq --arg l "$_lvl" '(.log //= {}) | .log.loglevel=$l' "$_lf" 2>/dev/null)"
  [ -n "$_new" ] || { http_error 500 write_failed "could not build $_lf"; return; }
  printf '%s\n' "$_new" > "$_lf" 2>/dev/null || { http_error 500 write_failed "write denied"; return; }
  _diag_restart_xray >/dev/null 2>&1
  http_ok "$(jq -n --arg l "$_lvl" '{ok:true,level:$l,restarted:true}')"
}

# _opm_has_subscription -> 0 when a subscription with >=1 location is stored (a node to
# connect to). The VPN can't be enabled without one.
_opm_has_subscription() {
  _sf="${OPM_SUB_FILE:-/opt/share/xkeen-manager/subscription.json}"
  [ -f "$_sf" ] || return 1
  _n="$(jq -r '(.locations|length)//0' "$_sf" 2>/dev/null)"
  [ -n "$_n" ] && [ "$_n" -gt 0 ] 2>/dev/null
}

# _vpn_status_json -> {ok,enabled,xrayRunning,redirectInstalled}
_vpn_status_json() {
  _vsp="${XKEEN_STATE_PATH:-/opt/share/xkeen-manager/xkeen-ui-state.json}"
  _ven="$(jq -r '.settings.vpnEnabled' "$_vsp" 2>/dev/null)"; [ "$_ven" = "false" ] || _ven=true
  _opm_has_subscription || _ven=false   # no subscription -> not (and can't be) enabled
  _vxr=false; pidof xray >/dev/null 2>&1 && _vxr=true
  _vrd=false; iptables -t nat -S xkeen 2>/dev/null | grep -q 'REDIRECT --to-ports' && _vrd=true
  jq -n --argjson e "$_ven" --argjson x "$_vxr" --argjson r "$_vrd" \
    '{ok:true,enabled:$e,xrayRunning:$x,redirectInstalled:$r}'
}

# GET /v1/vpn
get_vpn() { http_ok "$(_vpn_status_json)"; }

# PUT /v1/vpn  {enabled: bool}  -> set master switch (write flag + reconcile runtime)
put_vpn() {
  _en="$(cat | jq -r '.enabled' 2>/dev/null)"
  case "$_en" in true|false) : ;; *) http_error 400 bad_request "enabled must be a boolean"; return ;; esac
  if [ "$_en" = true ] && ! _opm_has_subscription; then
    http_error 400 no_subscription "add a subscription before enabling the VPN"; return
  fi
  command -v opm_vpn_set >/dev/null 2>&1 && opm_vpn_set "$_en"
  http_ok "$(_vpn_status_json)"
}

post_restart() {
  _svc="$(printf '%s' "$PATH_INFO" | sed -n 's#^.*/services/\([^/]*\)/restart$#\1#p')"

  case "$_svc" in
    xray)
      if _diag_restart_xray; then
        printf 'Status: 200 OK\r\n'
        printf 'Content-Type: application/json; charset=utf-8\r\n'
        printf 'Cache-Control: no-store\r\n'
        printf '\r\n'
        printf '{"ok":true,"service":"xray"}\n'
      else
        printf 'Status: 500 Internal Server Error\r\n'
        printf 'Content-Type: application/json; charset=utf-8\r\n'
        printf 'Cache-Control: no-store\r\n'
        printf '\r\n'
        printf '{"ok":false,"error":"xray restart failed"}\n'
      fi
      ;;
    singbox)
      if [ -x /opt/etc/init.d/S24opm-singbox ]; then
        /opt/etc/init.d/S24opm-singbox restart >/dev/null 2>&1
        sleep 1
        if pidof sing-box >/dev/null 2>&1; then
          printf 'Status: 200 OK\r\n'
          printf 'Content-Type: application/json; charset=utf-8\r\n'
          printf 'Cache-Control: no-store\r\n'
          printf '\r\n'
          printf '{"ok":true,"service":"singbox"}\n'
        else
          printf 'Status: 500 Internal Server Error\r\n'
          printf 'Content-Type: application/json; charset=utf-8\r\n'
          printf 'Cache-Control: no-store\r\n'
          printf '\r\n'
          printf '{"ok":false,"error":"singbox not running after restart"}\n'
        fi
      else
        printf 'Status: 500 Internal Server Error\r\n'
        printf 'Content-Type: application/json; charset=utf-8\r\n'
        printf 'Cache-Control: no-store\r\n'
        printf '\r\n'
        printf '{"ok":false,"error":"singbox init script missing"}\n'
      fi
      ;;
    selfheal)
      if [ -x /opt/etc/init.d/S25opm-selfheal ]; then
        /opt/etc/init.d/S25opm-selfheal restart >/dev/null 2>&1
        sleep 1
        printf 'Status: 200 OK\r\n'
        printf 'Content-Type: application/json; charset=utf-8\r\n'
        printf 'Cache-Control: no-store\r\n'
        printf '\r\n'
        printf '{"ok":true,"service":"selfheal"}\n'
      else
        printf 'Status: 500 Internal Server Error\r\n'
        printf 'Content-Type: application/json; charset=utf-8\r\n'
        printf 'Cache-Control: no-store\r\n'
        printf '\r\n'
        printf '{"ok":false,"error":"selfheal init script missing"}\n'
      fi
      ;;
    *)
      printf 'Status: 500 Internal Server Error\r\n'
      printf 'Content-Type: application/json; charset=utf-8\r\n'
      printf 'Cache-Control: no-store\r\n'
      printf '\r\n'
      printf '{"ok":false,"error":"unknown service"}\n'
      ;;
  esac
}
