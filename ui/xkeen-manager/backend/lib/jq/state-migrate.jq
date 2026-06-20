if (.schemaVersion // 0) >= 2 then .
else
  {
    schemaVersion: 2,
    activeCore: "xray",
    activeProfileId: .activeProfileId,
    settings: ({ ipv6Mode: "reject", vpnEnabled: true } + (.settings // {})),
    profiles: ( (.profiles // []) | map(
      {
        id: .id,
        name: .name,
        cores: {
          xray: {
            proxyConfig: .proxyConfig,
            muxConfig: .muxConfig,
            domainStrategy: (.domainStrategy // "IPIfNonMatch"),
            fallbackOutbound: (.fallbackOutbound // "direct"),
            groups: (.groups // [])
          },
          mihomo: { proxyConfig: { transport: "reality" }, rules: [], proxyGroups: [] }
        }
      }
    ))
  }
end
