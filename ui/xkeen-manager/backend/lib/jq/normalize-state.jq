# trim WITHOUT regex: Entware's jq is built WITHOUT oniguruma, so gsub/test/match
# are unavailable on the router. Strip leading/trailing spaces & tabs via slicing.
def trim:
  def ls: if startswith(" ") or startswith("\t") then .[1:]|ls else . end;
  def rs: if endswith(" ") or endswith("\t") then .[:-1]|rs else . end;
  ls|rs;
def clean_list:
  [ .[]? | tostring | trim | select(. != "") ]
  | reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);

def clamp_concurrency:
  ( ( . | tostring | tonumber? ) // 8 | floor ) as $n
  | if $n < 1 then 1 elif $n > 1024 then 1024 else $n end;

def norm_mux:
  ( . // {} ) as $m
  | ( $m.mode // "" ) as $mode
  | ( if ($mode == "off" or $mode == "xudp") then $mode
      elif ($mode == "") then "off"
      elif ( ( $m.xudpConcurrency // 0 | tostring | tonumber? ) // 0 ) > 0 then "xudp"
      else "off" end ) as $finalmode
  | { mode: $finalmode,
      tcpConcurrency: 8,
      xudpConcurrency: ( $m.xudpConcurrency | clamp_concurrency ),
      xudpProxyUDP443: ( if ( ["reject","skip","allow"] | index($m.xudpProxyUDP443) ) != null
                         then $m.xudpProxyUDP443 else "reject" end ) };

.profiles |= map(
  .cores.xray |= (
    .groups = ( ( .groups // [] ) | map(
        .domains = ( ( .domains // [] ) | clean_list )
      | .cidrs   = ( ( .cidrs   // [] ) | clean_list )
    ) )
    | .muxConfig = ( .muxConfig | norm_mux )
  )
)
