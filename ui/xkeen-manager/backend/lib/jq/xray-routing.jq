(.activeProfileId) as $id
| (.profiles[] | select(.id == $id) | .cores.xray) as $x
| {
    routing: {
      domainStrategy: ($x.domainStrategy // "IPIfNonMatch"),
      rules: (
        [ { type: "field", inboundTag: ["proxy-relay-ss"], outboundTag: "vless-reality" } ]
        + ( [ ($x.groups // [])[]
              | select((.enabled != false) and (.outboundTag != "direct") and (.outboundTag != "bypass")) ]
            | map(
                ( if (.domains | length) > 0
                  then [ { type: "field", inboundTag: ["redirect"], domain: .domains, outboundTag: .outboundTag } ]
                  else [] end )
                + ( if (.cidrs | length) > 0
                    then [ { type: "field", inboundTag: ["redirect"], ip: .cidrs, outboundTag: .outboundTag } ]
                    else [] end )
              )
            | add // [] )
        + [ { type: "field", inboundTag: ["redirect"], outboundTag: ($x.fallbackOutbound // "vless-reality") } ]
      )
    }
  }
