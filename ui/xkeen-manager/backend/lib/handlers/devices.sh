# Keenetic device management: list LAN hosts and toggle their membership in the
# xkeen (Opengater) policy. VPN-on = register the host + bind it to the policy;
# VPN-off = remove the policy binding. ndmc is the Keenetic control channel.

# _opm_policy_name -> the policy NAME (e.g. Policy42) whose description is "xkeen".
_opm_policy_name() {
  _pb="$(ndmc -c 'show ip policy' 2>/dev/null)"
  _pl="$(printf '%s\n' "$_pb" | grep 'description.*xkeen' | head -n 1)"
  _pn="$(printf '%s' "$_pl" | sed -n 's/.*name *= *\([^,]*\).*/\1/p' | sed 's/[[:space:]]*$//')"
  [ -n "$_pn" ] || _pn="$(printf '%s\n' "$_pb" | awk '/^[[:space:]]*name:/{n=$2} /description.*xkeen/{print n; exit}')"
  printf '%s' "$_pn"
}

# get_devices: every hotspot host with {mac, ip, hostname, name, active, registered, vpn}.
get_devices() {
  _pname="$(_opm_policy_name)"
  # running-config stores the binding nested under the `ip hotspot` section as
  # `host <mac> policy <PolicyName>` (no `ip hotspot` prefix on the line). Scan
  # every line: remember the token after `host` (the MAC) and emit it when the
  # same line also carries `policy <our-policy>`. Handles both the nested form
  # and the full `ip hotspot host <mac> policy <p>` form.
  _vpn="$(ndmc -c 'show running-config' 2>/dev/null | awk -v p="$_pname" '
    { hmac="";
      for (i=1;i<=NF;i++) {
        if ($i=="host") hmac=$(i+1);
        if ($i=="policy" && $(i+1)==p && hmac!="") print hmac;
      } }' | tr 'A-Z' 'a-z' | tr '\n' ' ')"
  # Keenetic nests an `interface:` block (with its own `name:` = LAN segment, e.g.
  # "Home") inside every `host:`. Split records on `host:`, and only read the
  # host-level `name:`/`hostname:` BEFORE the nested `interface:` block begins.
  _rows="$(ndmc -c 'show ip hotspot' 2>/dev/null | awk '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    function emit(){ if(m!=""){ printf "%s\t%s\t%s\t%s\t%s\t%s\n", m, ip, hn, nm, ac, rg } }
    /^[[:space:]]*host:[[:space:]]*$/     { emit(); m="";ip="";hn="";nm="";ac="";rg=""; inhost=1 }
    /^[[:space:]]*interface:/             { inhost=0 }
    inhost && /^[[:space:]]*mac:[[:space:]]/      { m=trim($2) }
    inhost && /^[[:space:]]*ip:[[:space:]]/       { ip=trim($2) }
    inhost && /^[[:space:]]*hostname:[[:space:]]/ { v=$0; sub(/^[[:space:]]*hostname:[[:space:]]*/,"",v); hn=trim(v) }
    inhost && /^[[:space:]]*name:[[:space:]]/     { v=$0; sub(/^[[:space:]]*name:[[:space:]]*/,"",v); nm=trim(v) }
    /^[[:space:]]*active:[[:space:]]/     { ac=trim($2) }
    /^[[:space:]]*registered:[[:space:]]/ { rg=trim($2) }
    END { emit() }
  ')"
  # NOTE: bind the row to $r. Inside `$v|index(...)` the pipe rebinds `.` to $v,
  # so a bare `.[0]` there would read $v's first element (always present) and
  # every device would show vpn:true. $r[0] stays the device's own mac.
  _devs="$(printf '%s\n' "$_rows" | jq -R -s --arg vpn "$_vpn" '
    ($vpn|split(" ")|map(select(length>0))) as $v
    | [ split("\n")[] | select(length>0) | (split("\t")) as $r
        | { mac:$r[0], ip:($r[1]//""), hostname:($r[2]//""), name:($r[3]//""),
            active:($r[4]=="yes"), registered:($r[5]=="yes"), vpn:(($v|index($r[0]))!=null) } ]' 2>/dev/null)"
  case "$_devs" in '['*) : ;; *) _devs='[]' ;; esac
  http_ok "$(jq -n --argjson d "$_devs" --arg policy "$_pname" '{ok:true, policy:$policy, devices:$d}')"
}

# _opm_flush_device_conntrack <mac>: drop existing conntrack flows for the
# device so a VPN on/off toggle takes effect on current connections, not just
# new ones (policy/redirect rules only steer freshly-established flows).
_opm_flush_device_conntrack() {
  command -v conntrack >/dev/null 2>&1 || return 0
  _fm="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  ip neigh show 2>/dev/null | awk -v m="$_fm" 'tolower($5)==m && $1 ~ /\./ {print $1}' | while IFS= read -r _dip; do
    [ -n "$_dip" ] || continue
    conntrack -D -s "$_dip" >/dev/null 2>&1 || true
  done
}

# post_device_vpn: POST /v1/devices/<mac>/vpn  body {enabled: bool}
post_device_vpn() {
  _mac="$(printf '%s' "$PATH_INFO" | sed -n 's#^.*/devices/\([^/]*\)/vpn$#\1#p')"
  case "$_mac" in ''|*[!0-9A-Fa-f:]*) http_error 400 bad_request "invalid mac"; return ;; esac
  _en="$(cat | jq -r '.enabled' 2>/dev/null)"
  _pname="$(_opm_policy_name)"
  [ -n "$_pname" ] || { http_error 500 no_policy "xkeen policy not found"; return; }
  if [ "$_en" = "true" ]; then
    _nm="$(ndmc -c 'show ip hotspot' 2>/dev/null | awk -v mac="$_mac" '
      /^[[:space:]]*mac:[[:space:]]/{cur=$2}
      cur==mac && /^[[:space:]]*hostname:[[:space:]]/{v=$0;sub(/^[[:space:]]*hostname:[[:space:]]*/,"",v);print v;exit}')"
    _nm="$(printf '%s' "${_nm:-}" | tr -cd 'A-Za-z0-9._-')"
    [ -n "$_nm" ] || _nm="dev$(printf '%s' "$_mac" | tr -cd '0-9A-Fa-f' | tail -c 6)"
    ndmc -c "known host $_nm $_mac" >/dev/null 2>&1 || true
    ndmc -c "ip hotspot host $_mac policy $_pname" >/dev/null 2>&1
    ndmc -c "system configuration save" >/dev/null 2>&1 || true
    _opm_flush_device_conntrack "$_mac"
    http_ok '{"ok":true,"vpn":true}'
  else
    ndmc -c "no ip hotspot host $_mac policy" >/dev/null 2>&1
    ndmc -c "system configuration save" >/dev/null 2>&1 || true
    _opm_flush_device_conntrack "$_mac"
    http_ok '{"ok":true,"vpn":false}'
  fi
}
