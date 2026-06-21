# routing-gen.jq — build xray 05_routing.json from the routing model.
#
# Input:  { mode, rules:[ {kind, value?, category?, action, match?} ] }
#   mode:   "rf-direct" (RF direct, world via VPN) | "selective" (only listed via VPN,
#           rest direct) | "all-vpn" | "all-direct"
#   rule.kind: "domain" (value, match: domain|full) | "ip" (value CIDR) |
#              "geosite" (category) | "geoip" (category)
#   rule.action: "direct" | "vpn"
# Args:   $gsfile active geosite .dat filename, $gifile active geoip .dat filename,
#         $gsdirect/$gidirect JSON arrays of categories the rf-direct preset sends direct
#         (RF role list + maintainer whitelist).
#
# Order (xray is first-match-wins): explicit USER rules come first, most-specific first
# (full > domain by label count > ip by prefix > group), so an explicit per-site choice
# always wins over the mode preset. THEN the mode preset (rf-direct: RF geosite/geoip ->
# direct), THEN a catch-all that sends "everything else" to the mode's default outbound.
def out(a): if a=="direct" then "direct" else "vless-reality" end;
def spec(r):
  if r.kind=="domain" then (if r.match=="full" then 1000 else 500 end) + ((r.value|split(".")|length))
  elif r.kind=="ip" then 300 + (((r.value|split("/"))[1] // "0")|tonumber)
  elif (r.kind=="geosite" or r.kind=="geoip") then 100
  else 0 end;
(if (.mode=="selective" or .mode=="all-direct") then "direct" else "vless-reality" end) as $def
| {
    routing: {
      domainStrategy: "IPIfNonMatch",
      rules: (
        [ {type:"field", inboundTag:["proxy-relay-ss"], outboundTag:"vless-reality"} ]
        + ( (.rules // [])
            | to_entries
            | sort_by([ -(spec(.value)), .key ])
            | map(.value)
            | map(
                out(.action) as $o
                | if .kind=="domain" then {type:"field",inboundTag:["redirect"],domain:[(if .match=="full" then "full:" else "domain:" end)+.value],outboundTag:$o}
                  elif .kind=="ip" then {type:"field",inboundTag:["redirect"],ip:[.value],outboundTag:$o}
                  elif .kind=="geosite" then {type:"field",inboundTag:["redirect"],domain:["ext:"+$gsfile+":"+.category],outboundTag:$o}
                  elif .kind=="geoip" then {type:"field",inboundTag:["redirect"],ip:["ext:"+$gifile+":"+.category],outboundTag:$o}
                  else empty end ) )
        + ( if (.mode=="rf-direct") then
              ( (if ($gsfile != "" and (($gsdirect|length)>0)) then [{type:"field",inboundTag:["redirect"],domain:($gsdirect|map("ext:"+$gsfile+":"+.)),outboundTag:"direct"}] else [] end)
              + (if ($gifile != "" and (($gidirect|length)>0)) then [{type:"field",inboundTag:["redirect"],ip:($gidirect|map("ext:"+$gifile+":"+.)),outboundTag:"direct"}] else [] end) )
            else [] end )
        + [ {type:"field", inboundTag:["redirect"], outboundTag: $def} ]
      )
    }
  }
