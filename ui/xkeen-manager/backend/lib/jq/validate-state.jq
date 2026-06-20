.activeProfileId as $aid |
[
  (if (.schemaVersion // 0) == 2 then empty else "schemaVersion must be 2" end),
  ( (.activeCore // "") as $c
    | if ($c == "xray" or $c == "mihomo") then empty
      else "activeCore must be 'xray' or 'mihomo'" end ),
  ( if ((.profiles | type) == "array") and ((.profiles | length) > 0) then empty
    else "profiles must be a non-empty array" end ),
  ( if ((.profiles | type) == "array")
       and (([.profiles[].id] | index($aid)) != null) then empty
    else "activeProfileId must reference an existing profile" end ),
  # "direct" is allowed here though the routing generator treats it like bypass (no rule emitted).
  ( .profiles[]? | .id as $pid
    | (.cores.xray.groups // [])[]?
    | (.outboundTag // "") as $t
    | if (["vless-reality","direct","bypass"] | index($t)) != null then empty
      else "profile \($pid): group has invalid outboundTag '\($t)'" end )
]
