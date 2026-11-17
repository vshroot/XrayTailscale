_cascade_ensure_dir() {
  mkdir -p "$UPSTREAMS_DIR"
  chmod 700 "$UPSTREAMS_DIR" 2>/dev/null
  chown xray:xray "$UPSTREAMS_DIR" 2>/dev/null || true
}

_cascade_config_file() {
  echo "$UPSTREAMS_DIR/cascade.json"
}

_cascade_enabled() {
  [[ -f "$CASCADE_ACTIVE_FILE" ]] && jq -e '.outbounds[]? | select(.tag == "cascade-upstream")' "$CONFIG_FILE" >/dev/null 2>&1
}

_cascade_print_status() {
  local upstream_file transport
  upstream_file=$(_cascade_config_file)
  if _cascade_enabled; then
    echo -e "${GREEN}Cascade: enabled${NC}"
  else
    echo -e "${YELLOW}Cascade: disabled${NC}"
  fi

  if [[ -f "$upstream_file" ]]; then
    transport=$(jq -r '.transport // "tcp"' "$upstream_file" 2>/dev/null)
    echo -e "${CYAN}Upstream:${NC} $(jq -r '.address' "$upstream_file"):$(jq -r '.port' "$upstream_file") transport=${transport} sni=$(jq -r '.sni' "$upstream_file")"
  else
    echo -e "${YELLOW}Upstream not configured${NC}"
  fi
}

_cascade_uri_decode() {
  local value="${1//+/ }"
  printf '%b' "${value//%/\\x}"
}

_cascade_query_param() {
  local query="$1"
  shift
  local pair key value wanted
  local -a pairs=()
  IFS='&' read -r -a pairs <<< "$query"
  for pair in "${pairs[@]}"; do
    [[ -z "$pair" ]] && continue
    key=$(_cascade_uri_decode "${pair%%=*}")
    if [[ "$pair" == *=* ]]; then
      value=$(_cascade_uri_decode "${pair#*=}")
    else
      value=""
    fi
    for wanted in "$@"; do
      if [[ "$key" == "$wanted" ]]; then
        printf '%s\n' "$value"
        return 0
      fi
    done
  done
  return 1
}

_cascade_parse_vless_uri() {
  local uri=$1
  if [[ "$uri" != vless://* ]]; then
    echo -e "${RED}✗ Expected a vless:// link${NC}" >&2
    return 1
  fi

  local rest authority query uuid server address port
  rest="${uri#vless://}"
  rest="${rest%%#*}"
  if [[ "$rest" == *\?* ]]; then
    authority="${rest%%\?*}"
    query="${rest#*\?}"
  else
    authority="$rest"
    query=""
  fi

  if [[ "$authority" != *@* ]]; then
    echo -e "${RED}✗ The VLESS link has no UUID or address${NC}" >&2
    return 1
  fi
  uuid="${authority%%@*}"
  server="${authority#*@}"

  if [[ "$server" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
    address="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  elif [[ "$server" =~ ^(.+):([0-9]+)$ ]]; then
    address="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  else
    echo -e "${RED}✗ Could not parse host:port from the VLESS link${NC}" >&2
    return 1
  fi

  local encryption security transport sni fingerprint public_key short_id
  local flow packet_encoding xhttp_path xhttp_host xhttp_mode
  encryption=$(_cascade_query_param "$query" encryption 2>/dev/null || true)
  encryption="${encryption:-none}"
  security=$(_cascade_query_param "$query" security 2>/dev/null || true)
  transport=$(_cascade_query_param "$query" type 2>/dev/null || true)
  transport="${transport:-tcp}"
  sni=$(_cascade_query_param "$query" sni serverName 2>/dev/null || true)
  fingerprint=$(_cascade_query_param "$query" fp 2>/dev/null || true)
  fingerprint="${fingerprint:-$DEFAULT_CLIENT_FINGERPRINT}"
  public_key=$(_cascade_query_param "$query" pbk publicKey 2>/dev/null || true)
  short_id=$(_cascade_query_param "$query" sid shortId 2>/dev/null || true)
  flow=$(_cascade_query_param "$query" flow 2>/dev/null || true)
  packet_encoding=$(_cascade_query_param "$query" packetEncoding packetencoding 2>/dev/null || true)
  xhttp_path=$(_cascade_query_param "$query" path 2>/dev/null || true)
  xhttp_path="${xhttp_path:-/}"
  xhttp_host=$(_cascade_query_param "$query" host 2>/dev/null || true)
  [[ -z "$xhttp_host" ]] && xhttp_host="$sni"
  xhttp_mode=$(_cascade_query_param "$query" mode 2>/dev/null || true)
  xhttp_mode="${xhttp_mode:-auto}"

  if [[ "$security" != "reality" ]]; then
    echo -e "${RED}✗ The cascade supports only security=reality${NC}" >&2
    return 1
  fi
  if [[ "$encryption" != "none" ]]; then
    echo -e "${RED}✗ The cascade supports only encryption=none${NC}" >&2
    return 1
  fi
  if [[ "$transport" != "tcp" && "$transport" != "xhttp" ]]; then
    echo -e "${RED}✗ Only upstream type=tcp and type=xhttp are supported${NC}" >&2
    return 1
  fi

  jq -n \
    --arg address "$address" \
    --argjson port "$port" \
    --arg uuid "$uuid" \
    --arg transport "$transport" \
    --arg sni "$sni" \
    --arg fingerprint "$fingerprint" \
    --arg public_key "$public_key" \
    --arg short_id "$short_id" \
    --arg flow "$flow" \
    --arg packet_encoding "$packet_encoding" \
    --arg xhttp_path "$xhttp_path" \
    --arg xhttp_host "$xhttp_host" \
    --arg xhttp_mode "$xhttp_mode" '
      {
        version: 2,
        tag: "cascade-upstream",
        address: $address,
        port: $port,
        uuid: $uuid,
        transport: $transport,
        sni: $sni,
        fingerprint: $fingerprint,
        public_key: $public_key,
        short_id: $short_id
      }
      + (if $transport == "tcp" then
          (if $flow == "" then {} else {flow: $flow} end)
          + (if $packet_encoding == "" then {} else {packet_encoding: $packet_encoding} end)
        else
          {
            xhttp_path: $xhttp_path,
            xhttp_host: $xhttp_host,
            xhttp_mode: $xhttp_mode
          }
        end)
    '
}

_cascade_validate_upstream_file() {
  local upstream_file=$1
  if ! jq -e . "$upstream_file" >/dev/null 2>&1; then
    echo -e "${RED}✗ Upstream JSON is corrupt${NC}"
    return 1
  fi

  local address port uuid public_key short_id sni fingerprint transport flow packet_encoding
  local xhttp_path xhttp_host xhttp_mode
  address=$(jq -r '.address // empty' "$upstream_file")
  port=$(jq -r '.port // empty' "$upstream_file")
  uuid=$(jq -r '.uuid // empty' "$upstream_file")
  public_key=$(jq -r '.public_key // empty' "$upstream_file")
  short_id=$(jq -r '.short_id // ""' "$upstream_file")
  sni=$(jq -r '.sni // empty' "$upstream_file")
  fingerprint=$(jq -r --arg default_fp "$DEFAULT_CLIENT_FINGERPRINT" '.fingerprint // $default_fp' "$upstream_file")
  transport=$(jq -r '.transport // "tcp"' "$upstream_file")
  flow=$(jq -r '.flow // ""' "$upstream_file")
  packet_encoding=$(jq -r '.packet_encoding // ""' "$upstream_file")
  xhttp_path=$(jq -r '.xhttp_path // "/"' "$upstream_file")
  xhttp_host=$(jq -r '.xhttp_host // .sni // empty' "$upstream_file")
  xhttp_mode=$(jq -r '.xhttp_mode // "auto"' "$upstream_file")

  if [[ -z "$address" || "$address" =~ ^(localhost$|0\.0\.0\.0$|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|::1$) ]]; then
    echo -e "${RED}✗ The upstream address must not be local/private${NC}"
    return 1
  fi
  if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
    echo -e "${RED}✗ Invalid port${NC}"
    return 1
  fi
  if [[ ! "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo -e "${RED}✗ Invalid UUID${NC}"
    return 1
  fi
  if [[ ! "$public_key" =~ ^[A-Za-z0-9_-]{40,}$ ]]; then
    echo -e "${RED}✗ Invalid Reality publicKey${NC}"
    return 1
  fi
  if [[ ! "$short_id" =~ ^[0-9a-fA-F]{0,16}$ ]] || (( ${#short_id} % 2 != 0 )); then
    echo -e "${RED}✗ Invalid shortId${NC}"
    return 1
  fi
  if [[ -z "$sni" || ! "$sni" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo -e "${RED}✗ Invalid SNI${NC}"
    return 1
  fi
  if [[ ! "$fingerprint" =~ ^(chrome|firefox|safari|ios|android|edge|qq|random|randomized)$ ]]; then
    echo -e "${RED}✗ Invalid fingerprint${NC}"
    return 1
  fi
  if [[ "$transport" != "tcp" && "$transport" != "xhttp" ]]; then
    echo -e "${RED}✗ transport supports only tcp or xhttp${NC}"
    return 1
  fi
  if [[ "$transport" == "tcp" ]]; then
    if [[ -n "$flow" && "$flow" != "xtls-rprx-vision" ]]; then
      echo -e "${RED}✗ For TCP only flow=xtls-rprx-vision or an empty value is supported${NC}"
      return 1
    fi
    if [[ -n "$packet_encoding" && "$packet_encoding" != "xudp" ]]; then
      echo -e "${RED}✗ packetEncoding supports only xudp or an empty value${NC}"
      return 1
    fi
  else
    if [[ "$xhttp_path" != /* ]]; then
      echo -e "${RED}✗ The XHTTP path must start with /${NC}"
      return 1
    fi
    if [[ -z "$xhttp_host" || ! "$xhttp_host" =~ ^[a-zA-Z0-9.-]+$ ]]; then
      echo -e "${RED}✗ Invalid XHTTP host${NC}"
      return 1
    fi
    if [[ ! "$xhttp_mode" =~ ^(auto|packet-up|stream-up|stream-one)$ ]]; then
      echo -e "${RED}✗ Invalid XHTTP mode${NC}"
      return 1
    fi
  fi
}

_cascade_build_outbound_json() {
  local upstream_file=$1
  _cascade_validate_upstream_file "$upstream_file" || return 1

  jq -cn --arg default_fp "$DEFAULT_CLIENT_FINGERPRINT" --slurpfile upstream "$upstream_file" '
    $upstream[0] as $u |
    ($u.transport // "tcp") as $transport |
    {
      tag: "cascade-upstream",
      protocol: "vless",
      settings: {
        vnext: [{
          address: $u.address,
          port: $u.port,
          users: [{
            id: $u.uuid,
            encryption: "none"
          }
          + (if (($u.flow // "") | length) == 0 then {} else {flow: $u.flow} end)
          + (if (($u.packet_encoding // "") | length) == 0 then {} else {packetEncoding: $u.packet_encoding} end)]
        }]
      },
      streamSettings: ({
        network: $transport,
        security: "reality",
        sockopt: {
          dialerProxy: "cascade-fragment"
        },
        realitySettings: {
          serverName: $u.sni,
          fingerprint: ($u.fingerprint // $default_fp),
          publicKey: $u.public_key,
          shortId: ($u.short_id // ""),
          spiderX: "/"
        }
      }
      + (if $transport == "tcp" then {
          sockopt: {
            dialerProxy: "cascade-fragment",
            tcpFastOpen: true,
            tcpNoDelay: true
          }
        } else {
          xhttpSettings: {
            path: ($u.xhttp_path // "/"),
            host: ($u.xhttp_host // $u.sni),
            mode: ($u.xhttp_mode // "auto")
          }
        } end))
    }'
}

_cascade_build_fragment_outbound_json() {
  jq -cn '{
    tag: "cascade-fragment",
    protocol: "freedom",
    settings: {
      fragment: {
        packets: "tlshello",
        length: "100-200",
        interval: "10-20"
      }
    }
  }'
}

_cascade_apply_current_upstream() {
  local reason=${1:-cascade_apply}
  local upstream_file outbound_json fragment_json address old_address had_active=false
  local rollback_config=""
  upstream_file=$(_cascade_config_file)
  [[ -f "$upstream_file" ]] || {
    echo -e "${RED}✗ Configure the upstream node first${NC}"
    return 1
  }
  _cascade_validate_upstream_file "$upstream_file" || return 1
  outbound_json=$(_cascade_build_outbound_json "$upstream_file") || return 1
  fragment_json=$(_cascade_build_fragment_outbound_json) || return 1
  address=$(jq -r '.address' "$upstream_file")
  old_address=$(jq -r 'first(.outbounds[]? | select(.tag == "cascade-upstream") | .settings.vnext[0].address) // ""' "$CONFIG_FILE" 2>/dev/null)
  [[ -f "$CASCADE_ACTIVE_FILE" ]] && had_active=true

  backup_config "$reason" rollback_config || return 1
  if ! safe_jq_write \
      --argjson outbound "$outbound_json" \
      --argjson fragment "$fragment_json" \
      --arg address "$address" \
      --arg old_address "$old_address" '
      def is_ip($a):
        (($a | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) or ($a | test(":")));
      def upstream_direct_rule:
        if is_ip($address) then
          {"type":"field","ip":[$address],"outboundTag":"direct"}
        else
          {"type":"field","domain":["domain:" + $address],"outboundTag":"direct"}
        end;
      def direct_rule_matches($a):
        if $a == "" then false
        elif is_ip($a) then (((.ip // []) | index($a)) != null)
        else (((.domain // []) | index("domain:" + $a)) != null)
        end;
      def upstream_direct_match:
        (.outboundTag == "direct" and (direct_rule_matches($address) or direct_rule_matches($old_address)));
      def catch_all:
        (.type == "field" and (.network // "") == "tcp,udp"
         and (.domain // null) == null and (.ip // null) == null and (.port // null) == null);
      .outbounds = ((.outbounds // []) | map(select(.tag != "cascade-upstream" and .tag != "cascade-fragment"))) |
      .outbounds += [$fragment, $outbound] |
      .routing.rules = [
        .routing.rules[]?
        | select((upstream_direct_match or catch_all) | not)
      ] |
      .routing.rules = [upstream_direct_rule] + .routing.rules + [
        {"type":"field","network":"tcp,udp","outboundTag":"cascade-upstream"}
      ]
    ' "$CONFIG_FILE"; then
    echo -e "${RED}✗ Could not apply the cascade config${NC}"
    return 1
  fi

  fix_xray_permissions
  if safe_restart_xray "$rollback_config"; then
    touch "$CASCADE_ACTIVE_FILE"
    chown xray:xray "$CASCADE_ACTIVE_FILE" 2>/dev/null || true
    echo -e "${GREEN}✓ The active cascade is synced with upstream${NC}"
    return 0
  fi

  [[ "$had_active" == "true" ]] || rm -f "$CASCADE_ACTIVE_FILE"
  return 1
}

_cascade_validate_upstream_fields() {
  local address=$1 port=$2 uuid=$3 public_key=$4 short_id=$5 sni=$6 fingerprint=${7:-$DEFAULT_CLIENT_FINGERPRINT} packet_encoding=${8:-}
  if [[ -z "$address" || "$address" =~ ^(localhost$|0\.0\.0\.0$|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[0-1])\.) ]]; then
    echo -e "${RED}✗ The upstream address must not be local/private${NC}"
    return 1
  fi
  if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
    echo -e "${RED}✗ Invalid port${NC}"
    return 1
  fi
  if [[ ! "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    echo -e "${RED}✗ Invalid UUID${NC}"
    return 1
  fi
  if [[ ! "$public_key" =~ ^[A-Za-z0-9_-]{40,}$ ]]; then
    echo -e "${RED}✗ Invalid Reality publicKey${NC}"
    return 1
  fi
  if [[ ! "$short_id" =~ ^[0-9a-fA-F]{0,16}$ ]]; then
    echo -e "${RED}✗ Invalid shortId${NC}"
    return 1
  fi
  if [[ -z "$sni" || ! "$sni" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo -e "${RED}✗ Invalid SNI${NC}"
    return 1
  fi
  if [[ ! "$fingerprint" =~ ^(chrome|firefox|safari|ios|android|edge|qq|random|randomized)$ ]]; then
    echo -e "${RED}✗ Invalid fingerprint${NC}"
    return 1
  fi
  if [[ -n "$packet_encoding" && "$packet_encoding" != "xudp" ]]; then
    echo -e "${RED}✗ packetEncoding supports only xudp or an empty value${NC}"
    return 1
  fi
}

configure_cascade_upstream() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}    FOREIGN UPSTREAM NODE SETUP        ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}\n"

  _cascade_ensure_dir

  local upstream_file previous cascade_was_enabled=false
  upstream_file=$(_cascade_config_file)
  previous=$(mktemp /tmp/xraytailscale-cascade-prev.XXXXXX) || return 1
  if [[ -f "$upstream_file" ]]; then
    cp "$upstream_file" "$previous"
  else
    : > "$previous"
  fi
  _cascade_enabled && cascade_was_enabled=true

  echo -n -e "${YELLOW}Ready-made VLESS URL of the foreign node [Enter=manual input]: ${NC}"
  local import_uri
  read -r import_uri
  if [[ -n "$import_uri" ]]; then
    local parsed_tmp
    parsed_tmp=$(mktemp /tmp/xraytailscale-cascade.XXXXXX) || {
      rm -f "$previous"
      return 1
    }
    if ! _cascade_parse_vless_uri "$import_uri" > "$parsed_tmp"; then
      rm -f "$parsed_tmp" "$previous"
      sleep 2
      return 1
    fi
    if ! _cascade_validate_upstream_file "$parsed_tmp"; then
      rm -f "$parsed_tmp" "$previous"
      sleep 2
      return 1
    fi
    mv "$parsed_tmp" "$upstream_file"
    chmod 600 "$upstream_file" 2>/dev/null
    chown xray:xray "$upstream_file" 2>/dev/null || true
    if [[ "$cascade_was_enabled" == "true" ]]; then
      echo -e "${CYAN}  → Cascade active: applying the new node...${NC}"
      if ! _cascade_apply_current_upstream "cascade_reconfigure"; then
        if [[ -s "$previous" ]]; then
          cp "$previous" "$upstream_file"
        else
          rm -f "$upstream_file"
        fi
        rm -f "$previous"
        echo -e "${RED}✗ The new node was not applied; the upstream file was restored${NC}"
        return 1
      fi
    fi
    rm -f "$previous"
    echo -e "${GREEN}✓ Upstream saved: $upstream_file${NC}"
    echo -n -e "${YELLOW}Press Enter to continue...${NC}"
    read -r _
    return 0
  fi

  local address port uuid public_key short_id sni fingerprint packet_encoding
  echo -n -e "${YELLOW}Foreign node host/IP: ${NC}"
  read -r address
  echo -n -e "${YELLOW}Port [443]: ${NC}"
  read -r port
  port=${port:-443}
  echo -n -e "${YELLOW}Client UUID on the foreign node: ${NC}"
  read -r uuid
  echo -n -e "${YELLOW}Foreign node Reality publicKey: ${NC}"
  read -r public_key
  echo -n -e "${YELLOW}Foreign node Reality shortId: ${NC}"
  read -r short_id
  echo -n -e "${YELLOW}Foreign node SNI: ${NC}"
  read -r sni
  echo -n -e "${YELLOW}Fingerprint [$DEFAULT_CLIENT_FINGERPRINT]: ${NC}"
  read -r fingerprint
  fingerprint=${fingerprint:-$DEFAULT_CLIENT_FINGERPRINT}
  echo -n -e "${YELLOW}packetEncoding [empty for plain tcp]: ${NC}"
  read -r packet_encoding

  _cascade_validate_upstream_fields "$address" "$port" "$uuid" "$public_key" "$short_id" "$sni" "$fingerprint" "$packet_encoding" || {
    sleep 2
    return 1
  }

  local tmp
  tmp=$(mktemp)
  if ! jq -n \
      --arg address "$address" \
      --argjson port "$port" \
      --arg uuid "$uuid" \
      --arg public_key "$public_key" \
      --arg short_id "$short_id" \
      --arg sni "$sni" \
      --arg fingerprint "$fingerprint" \
      --arg packet_encoding "$packet_encoding" \
      '{version:1,tag:"cascade-upstream",address:$address,port:$port,uuid:$uuid,transport:"tcp",sni:$sni,fingerprint:$fingerprint,public_key:$public_key,short_id:$short_id,flow:"xtls-rprx-vision"} + (if $packet_encoding == "" then {} else {packet_encoding:$packet_encoding} end)' \
      > "$tmp"; then
    rm -f "$tmp"
    echo -e "${RED}✗ Could not build the upstream JSON${NC}"
    return 1
  fi
  mv "$tmp" "$upstream_file"
  chmod 600 "$upstream_file" 2>/dev/null
  chown xray:xray "$upstream_file" 2>/dev/null || true

  if [[ "$cascade_was_enabled" == "true" ]]; then
    echo -e "${CYAN}  → Cascade active: applying the new node...${NC}"
    if ! _cascade_apply_current_upstream "cascade_reconfigure"; then
      if [[ -s "$previous" ]]; then
        cp "$previous" "$upstream_file"
      else
        rm -f "$upstream_file"
      fi
      rm -f "$previous"
      echo -e "${RED}✗ The new node was not applied; the upstream file was restored${NC}"
      return 1
    fi
  fi
  rm -f "$previous"

  echo -e "${GREEN}✓ Upstream saved: $upstream_file${NC}"
  echo -n -e "${YELLOW}Press Enter to continue...${NC}"
  read -r _
}

enable_cascade_mode() {
  local upstream_file
  upstream_file=$(_cascade_config_file)
  if [[ ! -f "$upstream_file" ]]; then
    echo -e "${RED}✗ Configure the upstream node first${NC}"
    sleep 2
    return 1
  fi

  echo -e "${YELLOW}Enable the cascade: route all default tcp/udp traffic through cascade-upstream? (y/N): ${NC}"
  local confirm
  read -r confirm
  [[ "$confirm" =~ ^[yYдД]$ ]] || return 1

  _cascade_apply_current_upstream "cascade_enable" || return 1
  echo -e "${GREEN}✓ Cascade enabled${NC}"
  echo -n -e "${YELLOW}Press Enter to continue...${NC}"
  read -r _
}

disable_cascade_mode() {
  echo -e "${YELLOW}Disable the cascade and return the default route to direct? (y/N): ${NC}"
  local confirm
  read -r confirm
  [[ "$confirm" =~ ^[yYдД]$ ]] || return 1

  local upstream_file address
  upstream_file=$(_cascade_config_file)
  address=""
  if [[ -f "$upstream_file" ]]; then
    address=$(jq -r '.address // ""' "$upstream_file" 2>/dev/null || echo "")
  fi

  local rollback_config=""
  backup_config "cascade_disable" rollback_config || return 1
  if ! safe_jq_write --arg address "$address" '
      def catch_all:
        (.type == "field" and (.network // "") == "tcp,udp"
         and (.domain // null) == null and (.ip // null) == null and (.port // null) == null);
      def cascade_upstream_direct_match:
        ($address != "" and .outboundTag == "direct" and (
          (((.domain // []) | index("domain:" + $address)) != null) or
          (((.ip // []) | index($address)) != null)
        ));
      .outbounds = ((.outbounds // []) | map(select(.tag != "cascade-upstream" and .tag != "cascade-fragment"))) |
      .routing.rules = [.routing.rules[]? | select(cascade_upstream_direct_match | not)] |
      if any(.routing.rules[]?; catch_all) then
        (.routing.rules[]? | select(catch_all) | .outboundTag) = "direct"
      else
        .routing.rules += [{"type":"field","network":"tcp,udp","outboundTag":"direct"}]
      end
    ' "$CONFIG_FILE"; then
    echo -e "${RED}✗ Could not disable the cascade${NC}"
    return 1
  fi
  fix_xray_permissions
  if safe_restart_xray "$rollback_config"; then
    rm -f "$CASCADE_ACTIVE_FILE"
    echo -e "${GREEN}✓ Cascade disabled${NC}"
  else
    return 1
  fi
  echo -n -e "${YELLOW}Press Enter to continue...${NC}"
  read -r _
}

cascade_mode_menu() {
  while true; do
    show_ascii
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}    CASCADE / UPSTREAM NODES                    ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${YELLOW} VPN bypass makes sense only when the cascade is enabled${NC}\n"
    _cascade_print_status
    echo ""
    echo -e "${CYAN} 1)${NC} Configure the foreign upstream node"
    echo -e "${CYAN} 2)${NC} Enable the cascade"
    echo -e "${CYAN} 3)${NC} Disable the cascade"
    echo -e "${CYAN} 4)${NC} VPN bypass (banks/gov services direct)"
    echo -e "${CYAN} 5)${NC} Deploy the outbound server (foreign node)"
    echo -e "${CYAN} 0)${NC} Back"
    echo ""
    echo -n -e "${YELLOW}Choice: ${NC}"
    local c
    if ! read -r c; then
      echo ""
      return 0
    fi
    case "$c" in
      1) configure_cascade_upstream ;;
      2) enable_cascade_mode ;;
      3) disable_cascade_mode ;;
      4) bypass_routing_menu ;;
      5) setup_outbound_server_menu ;;
      0) return ;;
      *) echo -e "${RED}Invalid choice${NC}"; sleep 1 ;;
    esac
  done
}

setup_outbound_server_menu() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}    DEPLOY OUTBOUND SERVER (FOREIGN NODE) ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}\n"
  echo -e "${CYAN}Run this option on the FOREIGN VPS.${NC}"
  echo -e "${CYAN}It deploys a TCP Reality Vision inbound — the cascade exit.${NC}"
  echo -e "${CYAN}Paste the parameters on the main server: Cascade → Configure upstream.${NC}\n"

  if [[ -z "${PRIVATE_KEY:-}" && -f "$PRIVATE_KEY_FILE" ]]; then
    PRIVATE_KEY=$(cat "$PRIVATE_KEY_FILE")
  fi
  if [[ -z "${PRIVATE_KEY:-}" || ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}✗ Reality keys or config not found. Install XrayTailscale on this node.${NC}"
    sleep 2
    return 1
  fi

  local default_sni port sni fingerprint
  default_sni=$(grep -v '^#' "$SNI_LIST" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n 1 | cut -d'|' -f1)
  [[ -z "$default_sni" ]] && default_sni="www.ozon.ru"

  echo -n -e "${YELLOW}Inbound port [443]: ${NC}"
  read -r port
  port=${port:-443}
  if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
    echo -e "${RED}✗ Invalid port${NC}"
    sleep 2
    return 1
  fi

  echo -n -e "${YELLOW}SNI (camouflage TLS domain) [${default_sni}]: ${NC}"
  read -r sni
  sni=${sni:-$default_sni}
  if [[ -z "$sni" ]] || [[ ! "$sni" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo -e "${RED}✗ Invalid SNI${NC}"
    sleep 2
    return 1
  fi

  echo -n -e "${YELLOW}Fingerprint [$DEFAULT_CLIENT_FINGERPRINT]: ${NC}"
  read -r fingerprint
  fingerprint=${fingerprint:-$DEFAULT_CLIENT_FINGERPRINT}
  if [[ ! "$fingerprint" =~ ^(chrome|firefox|safari|ios|android|edge|qq|random|randomized)$ ]]; then
    echo -e "${RED}✗ Invalid fingerprint${NC}"
    sleep 2
    return 1
  fi

  local uuid
  uuid=$(uuidgen)

  echo ""
  echo -n -e "${YELLOW}Deploy a TCP Reality Vision inbound on port $port (SNI $sni)? (y/N): ${NC}"
  local confirm
  read -r confirm
  [[ "$confirm" =~ ^[yYдД]$ ]] || return 1

  local rollback_config=""
  backup_config "outbound_server" rollback_config || return 1
  if ! add_inbound "$uuid" "tcp" "$port" "$sni" "$fingerprint" "" ""; then
    echo -e "${RED}✗ Could not create the foreign node inbound${NC}"
    return 1
  fi

  fix_xray_permissions
  if ! safe_restart_xray "$rollback_config"; then
    echo -e "${RED}✗ Xray rejected the config — auto-rollback done. The inbound was not deployed.${NC}"
    return 1
  fi

  local actual_sni actual_short_id actual_fp public_key address
  actual_sni=$(jq -r --argjson p "$port" '.inbounds[]? | select(.port == $p) | .streamSettings.realitySettings.serverNames[0] // empty' "$CONFIG_FILE" 2>/dev/null)
  actual_short_id=$(jq -r --argjson p "$port" '.inbounds[]? | select(.port == $p) | .streamSettings.realitySettings.shortIds[0] // empty' "$CONFIG_FILE" 2>/dev/null)
  actual_fp="$fingerprint"
  [[ -z "$actual_sni" ]] && actual_sni="$sni"
  [[ -z "$actual_fp" ]] && actual_fp="$fingerprint"
  public_key=$(cat "$PUBLIC_KEY_FILE" 2>/dev/null || true)
  address=$(get_server_ip)

  echo ""
  echo -e "${GREEN}✓ Foreign outbound server deployed (inbound-$port, TCP Reality Vision).${NC}"
  echo ""
  echo -e "${MAGENTA}═══════════════════════════════════════════════${NC}"
  echo -e "${MAGENTA} PARAMETERS FOR THE MAIN SERVER (Cascade → Configure upstream)${NC}"
  echo -e "${MAGENTA}═══════════════════════════════════════════════${NC}"
  echo -e "${CYAN}Host/IP:       ${NC}${address:-<enter this node IP manually>}"
  echo -e "${CYAN}Port:          ${NC}$port"
  echo -e "${CYAN}UUID:          ${NC}$uuid"
  echo -e "${CYAN}publicKey:     ${NC}${public_key:-<key not defined>}"
  echo -e "${CYAN}shortId:       ${NC}$actual_short_id"
  echo -e "${CYAN}SNI:           ${NC}$actual_sni"
  echo -e "${CYAN}Fingerprint:   ${NC}$actual_fp"
  echo -e "${CYAN}flow:          ${NC}xtls-rprx-vision"
  echo -e "${CYAN}packetEncoding:${NC} (leave empty)"
  echo -e "${MAGENTA}═══════════════════════════════════════════════${NC}"
  if [[ -z "$address" ]]; then
    echo -e "${YELLOW}⚠ The external IP was not detected automatically — enter Host/IP manually.${NC}"
  fi
  echo ""
  echo -n -e "${YELLOW}Press Enter to continue...${NC}"
  read -r _
}

# Главное меню
