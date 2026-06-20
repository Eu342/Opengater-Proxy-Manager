(.activeProfileId) as $id
| (.profiles[] | select(.id == $id) | .cores.xray) as $x
| ($x.proxyConfig) as $p
| ($x.muxConfig // {mode:"off"}) as $m
| ($p.transport // "reality") as $transport
| ( if $transport == "xhttp" then ""
    elif ($p.flow // "") == "" then "xtls-rprx-vision"
    else $p.flow end ) as $flow
| ( { publicKey: $p.publicKey,
      fingerprint: ($p.fingerprint // "random"),
      serverName: $p.serverName,
      shortId: $p.shortId,
      spiderX: "/" } ) as $reality
| {
    outbounds: [
      {
        tag: "vless-reality",
        protocol: "vless",
        settings: { vnext: [ {
          address: $p.address,
          port: ($p.port | tonumber),
          users: [ { id: $p.uuid, encryption: "none", flow: $flow, level: 0 } ]
        } ] },
        streamSettings: (
          if $transport == "xhttp" then
            {
              network: "xhttp", security: "reality",
              xhttpSettings: { host: ($p.serverName // ""), path: ($p.xhttpPath // "/"), mode: ($p.xhttpMode // "auto") },
              realitySettings: $reality
            }
          else
            { network: "tcp", security: "reality", realitySettings: $reality }
          end
        ),
        mux: ( if $m.mode == "xudp"
               then { enabled: true, concurrency: -1, xudpConcurrency: $m.xudpConcurrency, xudpProxyUDP443: $m.xudpProxyUDP443 }
               else { enabled: false } end )
      },
      { protocol: "freedom", tag: "direct" }
    ]
  }
