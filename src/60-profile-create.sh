create_profile_menu() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}        CREATE NEW PROFILE               ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}\n"
  echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║              CHOOSE PROFILE TYPE                         ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${CYAN} 1)${NC} Multi-route profile ${YELLOW}(manual mode, like a ready HAPP subscription)${NC}"
  echo -e "    ${GREEN}✓${NC} Seven routes in one profile: xhttp-legacy, xhttp-pq, TCP, gRPC"
  echo -e "    ${BLUE}ℹ${NC} A regular HAPP user should pick More → HAPP subscription instead"
  echo ""
  echo -e "${CYAN} 2)${NC} VLESS + TCP + Reality + Vision ${YELLOW}(legacy, separate profile)${NC}"
  echo -e "    ${GREEN}✓${NC} For sing-box, Hiddify, NekoBox, mihomo and older clients without PQ"
  echo -e "    ${YELLOW}⚠${NC} Throttled more often than XHTTP/Mux on mobile networks"
  echo ""
  echo -e "${CYAN} 3)${NC} VLESS + XHTTP + Reality + ${MAGENTA}Post-Quantum (mlkem768x25519plus.native)${NC}"
  echo -e "    ${GREEN}✓${NC} ML-KEM-768 protection against harvest-now-decrypt-later attacks"
  echo -e "    ${GREEN}✓${NC} The smoothest option for TSPU-2026: mobile networks and home ISPs"
  echo -e "    ${GREEN}✓${NC} Path and port are generated randomly, host comes from the current SNI"
  echo -e "    ${YELLOW}⚠${NC} The client must support VLESS PQ encryption:"
  echo -e "       ${GREEN}✓${NC} HAPP 2.10+, v2rayNG 1.10+, v2rayN PR#7782+, Shadowrocket (последние версии)"
  echo -e "       ${RED}✗${NC} sing-box, NekoBox, Hiddify, mihomo — choose option 2 for them"
  echo ""
  echo -e "${CYAN} 4)${NC} VLESS + TCP + Reality + Mux ${GREEN}(random high port)${NC}"
  echo -e "    ${GREEN}✓${NC} A good fallback if there is no XHTTP client"
  echo -e "    ${GREEN}✓${NC} Often behaves better than Vision on mobile networks"
  echo -e "    ${BLUE}ℹ${NC} Mux is enabled on the client, without Vision-flow"
  echo ""
  echo -e "${CYAN} 5)${NC} VLESS + gRPC + Reality ${YELLOW}(random high port)${NC}"
  echo -e "    ${YELLOW}⚠${NC} Only works with SNI where HTTP/2 is stable"
  echo -e "    ${YELLOW}⚠${NC} Worse compatibility on some RU providers and older clients"
  echo -e "    ${BLUE}ℹ${NC} serviceName is generated randomly and saved in the profile"
  echo ""
  echo -e "${CYAN} 6)${NC} VLESS + TCP + Reality + Vision + uTLS ${MAGENTA}(random high port, Firefox)${NC}"
  echo -e "    ${GREEN}✓${NC} Spoofs the TLS fingerprint to Firefox"
  echo -e "    ${BLUE}ℹ${NC} Makes sense on wired lines where plain Vision is throttled by fingerprint"
  echo -e "    ${YELLOW}⚠${NC} On mobile networks it is still better to try XHTTP first"
  echo ""
  echo -e "${CYAN} 7)${NC} VLESS + TCP + Reality + Vision + XUDP ${YELLOW}(random high port, anti-Tele2)${NC}"
  echo -e "    ${GREEN}✓${NC} May help on the strictest mobile filters"
  echo -e "    ${GREEN}✓${NC} xtls-rprx-vision + xudp"
  echo -e "    ${GREEN}✓${NC} SNI: api-maps.yandex.ru by default"
  echo -e "    ${YELLOW}⚠${NC} A narrow scenario, not the base default"
  echo ""
  echo -e "${CYAN} 8)${NC} Tailscale exit node is not a VLESS profile"
  echo -e "    ${BLUE}ℹ${NC} Installs Tailscale and advertises the VPS as an exit node"
  echo -e "    ${BLUE}ℹ${NC} Does not create an Xray/VLESS profile JSON"
  echo ""
  echo -e "${CYAN} 0)${NC} Back to main menu"
  echo ""
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo -n -e "${YELLOW}Your choice: ${NC}"
  read -r route_choice
  case $route_choice in
    1|2|3|4|5|6|7|xorpub) ;;
    8) tailscale_exit_node_menu; return ;;
    0) return ;;
    *) echo -e "${RED}Invalid choice${NC}"; sleep 2; return ;;
  esac

  echo ""
  echo -n -e "${YELLOW}Enter a profile name (or 0 to cancel): ${NC}"
  read -r profile_name
  if [[ "$profile_name" == "0" ]]; then
    return
  fi
  if [[ -z "$profile_name" ]]; then
    echo -e "${RED}✗ The name cannot be empty${NC}"
    sleep 2
    return
  fi
  if [[ ! "$profile_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo -e "${RED}✗ Use only letters, digits, hyphen and underscore${NC}"
    sleep 2
    return
  fi
  if [[ -f "$PROFILES_DIR/$profile_name.json" ]]; then
    echo -e "${RED}✗ A profile with this name already exists${NC}"
    sleep 2
    return
  fi

  case $route_choice in
    1) create_profile_all_routes "$profile_name" ;;
    2) create_profile "$profile_name" "tcp" "" "$DEFAULT_CLIENT_FINGERPRINT" ;;
    3) create_profile "$profile_name" "xhttp" "" "$DEFAULT_CLIENT_FINGERPRINT" ;;
    4) create_profile "$profile_name" "tcp-mux" "" "$DEFAULT_CLIENT_FINGERPRINT" ;;
    5) create_profile "$profile_name" "grpc" "" "$DEFAULT_CLIENT_FINGERPRINT" ;;
    6) create_profile "$profile_name" "tcp-utls" "" "firefox" ;;
    7) create_profile "$profile_name" "tcp-xudp" "" "$DEFAULT_CLIENT_FINGERPRINT" "api-maps.yandex.ru" ;;
    xorpub)
      # Hidden advanced opt-in (research §«Code Examples» #8 / D1 second-opinion).
      # xorpub mode = security theater в контексте Reality (codex+kimi подтвердили 2026-05-09).
      # Доступен ТОЛЬКО через ввод буквенного "xorpub" в TUI (обычный юзер не наберёт).
      echo -e "${MAGENTA}[ADVANCED] xorpub mode selected${NC}"
      echo -e "${YELLOW}⚠ xorpub = security theater for Reality. For debugging/testing only.${NC}"
      echo -e "${YELLOW}  Plan 6.2 does not implement a separate xorpub vlessenc parameter — the profile will be created${NC}"
      echo -e "${YELLOW}  with the default native key. xorpub generation is backlog (defer to v2.1).${NC}"
      sleep 3
      create_profile "$profile_name" "xhttp" "" "$DEFAULT_CLIENT_FINGERPRINT"
      ;;
  esac
}

create_profile_all_routes() {
  local name="$1"
  local pause_after="${2:-pause}"
  local subscription_output="${3:-show_subscription}"
  local uuid
  uuid=$(uuidgen)

  local sub_token
  sub_token=$(openssl rand -hex 16)
  if [[ ! "$sub_token" =~ ^[a-f0-9]{32}$ ]]; then
    echo -e "${RED}✗ Could not generate sub_token (openssl?)${NC}"
    return 1
  fi

  local default_sni
  default_sni=$(grep -v '^#' "$SNI_LIST" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n 1 | cut -d'|' -f1)
  [[ -z "$default_sni" ]] && default_sni="www.ozon.ru"

  local routes_tmp
  routes_tmp=$(mktemp /tmp/xraytailscale-routes.XXXXXX) || {
    echo -e "${RED}✗ mktemp failed${NC}"
    return 1
  }

  _append_route_json() {
    local route_label="$1" transport="$2" port="$3" sni="$4" fingerprint="$5" pq_enabled="$6" grpc_service_name="$7" xhttp_path="$8"
    if ! jq -n \
      --arg route_label "$route_label" \
      --arg transport "$transport" \
      --argjson port "$port" \
      --arg sni "$sni" \
      --arg fingerprint "$fingerprint" \
      --argjson pq_enabled "$pq_enabled" \
      --arg grpc_service_name "$grpc_service_name" \
      --arg xhttp_path "$xhttp_path" \
      '{
        "label": $route_label,
        transport: $transport,
        port: $port,
        sni: $sni,
        fingerprint: $fingerprint
      }
      + (if $pq_enabled then {pq_enabled: true, schema_version: 2} else {} end)
      + (if $grpc_service_name != "" then {grpc_service_name: $grpc_service_name} else {} end)
      + (if $xhttp_path != "" then {xhttp_path: $xhttp_path} else {} end)' >> "$routes_tmp"; then
      echo -e "${RED}✗ Could not build the JSON for route ${route_label}${NC}"
      return 1
    fi
  }

  local defaults port grpc_service_name xhttp_path

  defaults=$(build_transport_defaults "xhttp") || { rm -f "$routes_tmp"; return 1; }
  IFS='|' read -r port _ xhttp_path <<< "$defaults"
  _append_route_json "xhttp-legacy" "xhttp" "$port" "$default_sni" "$DEFAULT_CLIENT_FINGERPRINT" false "" "$xhttp_path" || { rm -f "$routes_tmp"; return 1; }

  defaults=$(build_transport_defaults "xhttp") || { rm -f "$routes_tmp"; return 1; }
  IFS='|' read -r port _ xhttp_path <<< "$defaults"
  _append_route_json "xhttp-pq" "xhttp" "$port" "$default_sni" "$DEFAULT_CLIENT_FINGERPRINT" true "" "$xhttp_path" || { rm -f "$routes_tmp"; return 1; }

  defaults=$(build_transport_defaults "tcp-mux") || { rm -f "$routes_tmp"; return 1; }
  IFS='|' read -r port _ _ <<< "$defaults"
  _append_route_json "tcp-mux" "tcp-mux" "$port" "$default_sni" "$DEFAULT_CLIENT_FINGERPRINT" false "" "" || { rm -f "$routes_tmp"; return 1; }

  defaults=$(build_transport_defaults "grpc") || { rm -f "$routes_tmp"; return 1; }
  IFS='|' read -r port grpc_service_name _ <<< "$defaults"
  _append_route_json "grpc" "grpc" "$port" "www.cloudflare.com" "$DEFAULT_CLIENT_FINGERPRINT" false "$grpc_service_name" "" || { rm -f "$routes_tmp"; return 1; }

  defaults=$(build_transport_defaults "tcp") || { rm -f "$routes_tmp"; return 1; }
  IFS='|' read -r port _ _ <<< "$defaults"
  _append_route_json "tcp-vision" "tcp" "$port" "$default_sni" "$DEFAULT_CLIENT_FINGERPRINT" false "" "" || { rm -f "$routes_tmp"; return 1; }

  defaults=$(build_transport_defaults "tcp-utls") || { rm -f "$routes_tmp"; return 1; }
  IFS='|' read -r port _ _ <<< "$defaults"
  _append_route_json "tcp-utls-firefox" "tcp-utls" "$port" "$default_sni" "firefox" false "" "" || { rm -f "$routes_tmp"; return 1; }

  defaults=$(build_transport_defaults "tcp-xudp") || { rm -f "$routes_tmp"; return 1; }
  IFS='|' read -r port _ _ <<< "$defaults"
  _append_route_json "tcp-xudp" "tcp-xudp" "$port" "api-maps.yandex.ru" "$DEFAULT_CLIENT_FINGERPRINT" false "" "" || { rm -f "$routes_tmp"; return 1; }

  local routes_json
  routes_json=$(jq -s '.' "$routes_tmp") || {
    rm -f "$routes_tmp"
    echo -e "${RED}✗ Could not build the routes JSON${NC}"
    return 1
  }
  rm -f "$routes_tmp"

  local route_count
  route_count=$(jq 'length' <<< "$routes_json") || {
    echo -e "${RED}✗ Could not verify the route count${NC}"
    return 1
  }
  if [[ "$route_count" != "7" ]]; then
    echo -e "${RED}✗ Multi-route profile built incorrectly: ${route_count} routes, expected 7${NC}"
    return 1
  fi

  if ! jq -n \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg sub_token "$sub_token" \
      --arg created "$(date +%Y-%m-%d\ %H:%M:%S)" \
      --argjson routes "$routes_json" \
      '{
        name: $name,
        uuid: $uuid,
        schema_version: 3,
        multi_route: true,
        primary_route: "xhttp-legacy",
        sub_token: $sub_token,
        created: $created,
        routes: $routes
      }
      + {
        transport: $routes[0].transport,
        port: $routes[0].port,
        fingerprint: $routes[0].fingerprint,
        sni: $routes[0].sni,
        xhttp_path: $routes[0].xhttp_path,
        pq_enabled: ($routes[0].pq_enabled // false)
      }' > "$PROFILES_DIR/$name.json"; then
    rm -f "$PROFILES_DIR/$name.json"
    echo -e "${RED}✗ Could not create the profile JSON${NC}"
    return 1
  fi

  local rollback_config=""
  if ! backup_config "create_profile_$name" rollback_config; then
    rm -f "$PROFILES_DIR/$name.json"
    return 1
  fi

  local created_ports=()
  local route_json label transport sni fingerprint pq grpc xhttp
  while IFS= read -r route_json; do
    label=$(jq -r '.label // ""' <<< "$route_json")
    transport=$(jq -r '.transport // ""' <<< "$route_json")
    port=$(jq -r '.port // empty' <<< "$route_json")
    sni=$(jq -r '.sni // ""' <<< "$route_json")
    fingerprint=$(jq -r --arg default_fp "$DEFAULT_CLIENT_FINGERPRINT" '.fingerprint // $default_fp' <<< "$route_json")
    pq=$(jq -r '.pq_enabled // false' <<< "$route_json")
    grpc=$(jq -r '.grpc_service_name // ""' <<< "$route_json")
    xhttp=$(jq -r '.xhttp_path // ""' <<< "$route_json")

    if [[ "$transport" == "xhttp" && "$xhttp" != /* ]]; then
      _restore_config_backup "$rollback_config" >/dev/null 2>&1 || true
      rm -f "$PROFILES_DIR/$name.json"
      echo -e "${RED}✗ XHTTP route ${label} built without a path; profile removed${NC}"
      return 1
    fi

    echo -e "${CYAN} → Route ${label}: ${transport} :${port}${NC}"
    if ! add_inbound "$uuid" "$transport" "$port" "$sni" "$fingerprint" "$grpc" "$xhttp" "$pq"; then
      _restore_config_backup "$rollback_config" >/dev/null 2>&1 || true
      rm -f "$PROFILES_DIR/$name.json"
      local p
      for p in "${created_ports[@]}"; do
        close_firewall_port "$p"
      done
      echo -e "${RED}✗ Could not create route ${label}; profile removed, config.json rolled back${NC}"
      if [[ "$pause_after" != "no_pause" ]]; then
        echo -n -e "${YELLOW}Press Enter to continue...${NC}"
        read -r _
      fi
      return 1
    fi
    created_ports+=("$port")
  done < <(jq -c '.[]' <<< "$routes_json")

  if ! safe_restart_xray "$rollback_config"; then
    rm -f "$PROFILES_DIR/$name.json"
    local p
    for p in "${created_ports[@]}"; do
      close_firewall_port "$p"
    done
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════${NC}"
    echo -e "${RED}         ✗ PROFILE NOT ACTIVATED             ${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${RED}Xray rejected the multi-route config. Profile removed, config.json rolled back.${NC}"
    if [[ "$pause_after" != "no_pause" ]]; then
      echo -n -e "${YELLOW}Press Enter to continue...${NC}"
      read -r _
    fi
    return 1
  fi

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}         ✓ PROFILE CREATED SUCCESSFULLY!            ${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${BLUE}Profile name:${NC} ${GREEN}$name${NC}"
  echo -e "${BLUE}UUID:${NC} $uuid"
  echo -e "${BLUE}Routes:${NC} $(jq 'length' <<< "$routes_json")"
  jq -r '.[] | "  - \(.label): \(.transport) :\(.port) sni=\(.sni)"' <<< "$routes_json"

  if [[ "$subscription_output" != "hide_subscription" ]]; then
    if [[ -f /usr/local/etc/xray/.subscription_installed ]]; then
      _happ_print_subscription_url_for_profile "$name"
    else
      echo ""
      echo -e "${YELLOW}ℹ HAPP subscription is not installed yet. Enable it via Main menu → HAPP subscription.${NC}"
    fi
  fi

  echo ""
  echo -e "${CYAN}One subscription for this profile serves all routes.${NC}"
  echo ""
  fix_xray_permissions
  if [[ "$pause_after" != "no_pause" ]]; then
    echo -n -e "${YELLOW}Press Enter to continue...${NC}"
    read -r _
  fi
}

# Создание профиля
create_profile() {
  local name=$1
  local transport=$2
  local port=$3
  local fingerprint=$4
  local custom_sni=$5  # Опциональный кастомный SNI
  local grpc_service_name=$6
  local xhttp_path=$7
  # Self-steal: необязательный явный Reality dest (8-й аргумент).
  # Задан → подтверждение риска Vision:443 не требуется (свой сайт снимает риск).
  local reality_dest=${8:-}
  local uuid=$(uuidgen)

  # Phase 7 REQ-C04: sub_token (32 hex-символа) для HAPP subscription URL.
  # Один профиль = одна subscription URL; sub_token хранится в profile JSON.
  local sub_token
  sub_token=$(openssl rand -hex 16)
  if [[ ! "$sub_token" =~ ^[a-f0-9]{32}$ ]]; then
    echo -e "${RED}✗ Could not generate sub_token (openssl?)${NC}"
    return 1
  fi

  local default_sni=""
  local defaults=""

  if [[ -z "$port" ]]; then
    if ! defaults=$(build_transport_defaults "$transport"); then
      echo -n -e "${YELLOW}Press Enter to continue...${NC}"
      read
      return 1
    fi
    IFS='|' read -r port generated_grpc_service_name generated_xhttp_path <<< "$defaults"
    [[ -z "$grpc_service_name" ]] && grpc_service_name="$generated_grpc_service_name"
    [[ -z "$xhttp_path" ]] && xhttp_path="$generated_xhttp_path"
  fi

  # gRPC требует SNI с поддержкой HTTP/2 (только зарубежные!)
  if [[ "$transport" == "grpc" ]]; then
    default_sni="www.cloudflare.com"
    echo -e "${YELLOW}⚠ gRPC: using SNI ${CYAN}$default_sni${YELLOW} (HTTP/2 required)${NC}"
  else
    # Read first valid SNI (skip comments and empty lines)
    default_sni=$(grep -v '^#' "$SNI_LIST" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n 1 | cut -d'|' -f1)
    [[ -z "$default_sni" ]] && default_sni="www.ozon.ru"
  fi

  # Используем кастомный SNI если передан
  [[ -n "$custom_sni" ]] && default_sni="$custom_sni"

  case "$transport" in
    grpc)
      [[ -z "$grpc_service_name" ]] && grpc_service_name="grpc"
      ;;
    xhttp)
      [[ -z "$xhttp_path" ]] && xhttp_path="/xhttp"
      ;;
  esac

  if [[ "$port" == "443" ]] && [[ "$transport" == "tcp" || "$transport" == "tcp-utls" || "$transport" == "tcp-xudp" ]] && [[ -z "$reality_dest" ]]; then
    if ! confirm_vision_443_risk; then
      echo -e "${CYAN}✓ Profile creation cancelled${NC}"
      sleep 1
      return 0
    fi
  fi

  local jq_args=(
    --arg name "$name"
    --arg uuid "$uuid"
    --arg transport "$transport"
    --argjson port "$port"
    --arg fingerprint "$fingerprint"
    --arg sni "$default_sni"
    --arg sub_token "$sub_token"
    --arg created "$(date +%Y-%m-%d\ %H:%M:%S)"
  )
  local jq_expr='{name: $name, uuid: $uuid, transport: $transport, port: $port, fingerprint: $fingerprint, sni: $sni'
  if [[ "$transport" == "grpc" ]]; then
    jq_args+=(--arg grpc_service_name "$grpc_service_name")
    jq_expr+=', grpc_service_name: $grpc_service_name'
  elif [[ "$transport" == "xhttp" ]]; then
    jq_args+=(--arg xhttp_path "$xhttp_path")
    jq_expr+=', xhttp_path: $xhttp_path'
    # Phase 6 REQ-A04/A05: новый XHTTP-профиль = PQ.
    # schema_version: 2 + pq_enabled: true — generate_connection и upgrade_button (Plan 6.3) различают это.
    jq_args+=(--argjson schema_v 2 --argjson pq_enabled true)
    jq_expr+=', schema_version: $schema_v, pq_enabled: $pq_enabled'
  fi
  # Phase 7 REQ-C04: sub_token присутствует во всех профилях независимо от транспорта.
  jq_expr+=', sub_token: $sub_token, created: $created}'
  if ! jq -n "${jq_args[@]}" "$jq_expr" > "$PROFILES_DIR/$name.json"; then
    rm -f "$PROFILES_DIR/$name.json"
    echo -e "${RED}✗ Could not create the profile JSON${NC}"
    return 1
  fi

  local rollback_config=""
  if ! backup_config "create_profile_$name" rollback_config; then
    rm -f "$PROFILES_DIR/$name.json"
    return 1
  fi
  if ! add_inbound "$uuid" "$transport" "$port" "$default_sni" "$fingerprint" "$grpc_service_name" "$xhttp_path" "" "$reality_dest"; then
    rm -f "$PROFILES_DIR/$name.json"
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════${NC}"
    echo -e "${RED}         ✗ PROFILE CREATION ERROR            ${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${RED}Inbound not created — the profile file was removed.${NC}"
    echo -e "${YELLOW}Try a different port or transport.${NC}"
    echo ""
    echo -n -e "${YELLOW}Press Enter to continue...${NC}"
    read
    return 1
  fi

  if ! safe_restart_xray "$rollback_config"; then
    rm -f "$PROFILES_DIR/$name.json"
    close_firewall_port "$port"
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════${NC}"
    echo -e "${RED}         ✗ PROFILE NOT ACTIVATED             ${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${RED}Xray rejected the new config. Profile removed, config.json rolled back.${NC}"
    echo -e "${YELLOW}Check the latest backup in /usr/local/etc/xray/backups/.${NC}"
    echo ""
    echo -n -e "${YELLOW}Press Enter to continue...${NC}"
    read
    return 1
  fi

  # Читаем актуальный SNI из файла (мог измениться при SNI-конфликте)
  local actual_sni=$(jq -r '.sni' "$PROFILES_DIR/$name.json" 2>/dev/null)
  [[ -z "$actual_sni" ]] && actual_sni="$default_sni"

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}         ✓ PROFILE CREATED SUCCESSFULLY!            ${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${BLUE}Profile name:${NC} ${GREEN}$name${NC}"
  echo -e "${BLUE}UUID:${NC} $uuid"
  echo -e "${BLUE}Transport:${NC} $transport"
  echo -e "${BLUE}Port:${NC} $port"
  echo -e "${BLUE}Fingerprint:${NC} $fingerprint"
  echo -e "${BLUE}SNI:${NC} $actual_sni"

  # Phase 7: subscription URL/QR — primary output если подписка установлена.
  # B1: URL строится через _subscription_base_url (Plan 7.2 helper) — никакого инлайна!
  if [[ -f /usr/local/etc/xray/.subscription_installed ]]; then
    _happ_print_subscription_url_for_profile "$name"
  else
    echo ""
    echo -e "${YELLOW}ℹ HAPP subscription is not installed yet. Enable it via Main menu → HAPP subscription.${NC}"
  fi

  echo ""
  echo -e "${CYAN}Use the 'Connect to profile' menu to get the link${NC}"
  echo ""
  fix_xray_permissions
  echo -n -e "${YELLOW}Press Enter to continue...${NC}"
  read
}

# Добавление inbound
add_inbound() {
  local uuid=$1
  local transport=$2
  local port=$3
  local sni=$4
  local fingerprint=${5:-$DEFAULT_CLIENT_FINGERPRINT}
  local grpc_service_name=$6
  local xhttp_path=$7
  local pq_enabled=${8:-}
  # Self-steal: явный Reality dest (например 127.0.0.1:8443 — локальный nginx
  # с сертификатом собственного домена). Пусто = прежнее поведение "$sni:443".
  local reality_dest=${9:-}
  [[ -z "$reality_dest" ]] && reality_dest="$sni:443"
  local short_id=$(openssl rand -hex 4)
  [[ -z "$pq_enabled" && "$transport" == "xhttp" ]] && pq_enabled=true

  # Phase 6 REQ-A04: для PQ XHTTP-инбаундов читаем decryption из файла.
  # HAPP fallback XHTTP использует decryption=none, иначе это не fallback.
  # Файл создан Plan 6.1 (install.sh при свежей установке ИЛИ миграция .mlkem_keys_generated).
  # Если файл отсутствует — это runtime-ошибка: миграция должна была сработать.
  local vless_decryption="none"
  if [[ "$transport" == "xhttp" && "$pq_enabled" == "true" ]]; then
    if [[ ! -f "$VLESS_DECRYPTION_FILE" ]]; then
      echo -e "${RED}✗ PQ keys are missing: $VLESS_DECRYPTION_FILE${NC}"
      echo -e "${YELLOW}  Restart xraytailscale — the .mlkem_keys_generated migration should generate the keys${NC}"
      echo -e "${YELLOW}  If the migration fails, check: sudo /usr/local/bin/xray version (need ≥ 25.9.5)${NC}"
      return 1
    fi
    vless_decryption=$(cat "$VLESS_DECRYPTION_FILE")
    if [[ ! "$vless_decryption" =~ ^mlkem768x25519plus\. ]]; then
      echo -e "${RED}✗ $VLESS_DECRYPTION_FILE contains an invalid PQ string${NC}"
      echo -e "${YELLOW}  Delete the file and restart xraytailscale to regenerate${NC}"
      return 1
    fi
  fi

  local existing_tag=$(jq -r --argjson port "$port" '.inbounds[] | select(.port == $port) | .tag' "$CONFIG_FILE" 2>/dev/null)
  if [[ -n "$existing_tag" ]]; then
    # Check transport compatibility
    local existing_transport=$(jq -r --argjson port "$port" \
      '.inbounds[] | select(.port == $port) | .streamSettings.network' \
      "$CONFIG_FILE" 2>/dev/null)

    local expected_network="$transport"
    case "$transport" in
      tcp|tcp-utls|tcp-xudp|tcp-mux) expected_network="tcp" ;;
    esac

    if [[ -n "$existing_transport" ]] && [[ "$expected_network" != "$existing_transport" ]]; then
      echo ""
      echo -e "${RED}✗ Port $port is already used with transport '$existing_transport' (incompatible with '$transport')${NC}"
      echo -e "${YELLOW}Use a different port for transport '$transport'${NC}"
      return 1
    fi

    # Check existing inbound's SNI
    local existing_sni=$(jq -r --argjson port "$port" \
      '.inbounds[] | select(.port == $port) | .streamSettings.realitySettings.serverNames[0]' \
      "$CONFIG_FILE" 2>/dev/null)

    if [[ -n "$existing_sni" ]] && [[ "$existing_sni" != "$sni" ]]; then
      echo ""
      echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
      echo -e "${RED}║         ⚠ SNI CONFLICT ON PORT $port                    ║${NC}"
      echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
      echo ""
      echo -e "${YELLOW}Port $port is already used with SNI: ${MAGENTA}$existing_sni${NC}"
      echo -e "${YELLOW}The new profile tries to use SNI: ${MAGENTA}$sni${NC}"
      echo ""
      echo -e "${CYAN}Xray Reality does not support different SNI on one port.${NC}"
      echo -e "${CYAN}The profile will be created with SNI: ${YELLOW}$existing_sni${NC}"
      echo ""
      sleep 3

      # Override sni to match existing inbound
      sni="$existing_sni"

      # Обновить SNI в только что созданном файле профиля
      local pf
      for pf in "$PROFILES_DIR"/*.json; do
        [[ ! -f "$pf" ]] && continue
        local pf_uuid=$(jq -r '.uuid' "$pf" 2>/dev/null)
        if [[ "$pf_uuid" == "$uuid" ]]; then
          safe_jq_write --arg sni "$existing_sni" '.sni = $sni' "$pf" || \
            echo -e "${YELLOW}  ⚠ Could not update SNI in profile $(basename "$pf")${NC}"
          break
        fi
      done
    fi

    local profile_file=""
    profile_file=$(find_profile_file_by_uuid "$uuid")
    if [[ -n "$profile_file" ]]; then
      local inbound_metadata=""
      local inbound_grpc_service_name=""
      local inbound_xhttp_path=""
      inbound_metadata=$(read_inbound_transport_metadata "$port" "$transport")
      IFS='|' read -r inbound_grpc_service_name inbound_xhttp_path <<< "$inbound_metadata"
      write_profile_transport_metadata "$profile_file" "$inbound_grpc_service_name" "$inbound_xhttp_path" || \
        echo -e "${YELLOW}  ⚠ Could not sync transport metadata for profile $(basename "$profile_file")${NC}"
    fi

    echo -e "${CYAN} → Adding a client to the existing inbound on port $port${NC}"
    # Phase 6 note: decryption инбаунда НЕ меняется здесь.
    # Если existing inbound имеет decryption: "none", а транспорт xhttp — новый клиент
    # технически добавится в clients[], но его vless:// URL без encryption= НЕ будет работать.
    # Plan 6.3 даёт кнопку "Upgrade to post-quantum" для переключения профиля на PQ.
    # REQ-A08: миграции НЕ трогают существующие inbound'ы автоматически.
    # Определяем flow по типу транспорта нового профиля (не копируем слепо от первого клиента)
    local client_flow=""
    case "$transport" in
      tcp|tcp-utls|tcp-xudp) client_flow="xtls-rprx-vision" ;;
      tcp-mux|grpc|xhttp) client_flow="" ;;
    esac
    if ! safe_jq_write --arg uuid "$uuid" --argjson port "$port" --arg flow "$client_flow" '
      (.inbounds[] | select(.port == $port) | .settings.clients) += [{
        "id": $uuid,
        "flow": $flow
      }]
    ' "$CONFIG_FILE"; then
      echo -e "${RED}  ✗ Could not add the client to the inbound${NC}"
      return 1
    fi
    return
  fi

  echo -e "${CYAN} → Creating a new inbound on port $port${NC}"
  local inbound=""
  case $transport in
    tcp-mux)
      inbound=$(cat << TCPMUXEOF
{
  "listen": "0.0.0.0",
  "port": $port,
  "protocol": "vless",
  "settings": {
    "clients": [{"id": "$uuid", "flow": ""}],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "$reality_dest",
      "xver": 0,
      "serverNames": ["$sni"],
      "privateKey": "$PRIVATE_KEY",
      "shortIds": ["$short_id"]
    }
  },
  "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true},
  "tag": "inbound-$port"
}
TCPMUXEOF
)
      ;;
    tcp|tcp-utls|tcp-xudp)
      inbound=$(cat << TCPEOF
{
  "listen": "0.0.0.0",
  "port": $port,
  "protocol": "vless",
  "settings": {
    "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "$reality_dest",
      "xver": 0,
      "serverNames": ["$sni"],
      "privateKey": "$PRIVATE_KEY",
      "shortIds": ["$short_id"]
    }
  },
  "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true},
  "tag": "inbound-$port"
}
TCPEOF
)
      ;;
    grpc)
      inbound=$(cat << GRPCEOF
{
  "listen": "0.0.0.0",
  "port": $port,
  "protocol": "vless",
  "settings": {
    "clients": [{"id": "$uuid", "flow": ""}],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "grpc",
    "security": "reality",
    "grpcSettings": {"serviceName": "$grpc_service_name"},
    "realitySettings": {
      "show": false,
      "dest": "$reality_dest",
      "xver": 0,
      "serverNames": ["$sni"],
      "privateKey": "$PRIVATE_KEY",
      "shortIds": ["$short_id"]
    }
  },
  "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true},
  "tag": "inbound-$port"
}
GRPCEOF
)
      ;;
    xhttp)
      inbound=$(cat << XHTTPEOF
{
  "listen": "0.0.0.0",
  "port": $port,
  "protocol": "vless",
  "settings": {
    "clients": [{"id": "$uuid", "flow": ""}],
    "decryption": "$vless_decryption"
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "xhttpSettings": {
      "mode": "stream-one",
      "path": "$xhttp_path",
      "extra": {
        "xPaddingBytes": "100-1000",
        "xmux": {
          "maxConcurrency": "16-32",
          "hMaxRequestTimes": "600-900",
          "hMaxReusableSecs": "1800-3000",
          "hKeepAlivePeriod": 0
        },
        "noSSEHeader": true,
        "scMaxEachPostBytes": "1000000-2000000",
        "scMinPostsIntervalMs": "10-50"
      }
    },
    "realitySettings": {
      "show": false,
      "dest": "$reality_dest",
      "xver": 0,
      "serverNames": ["$sni"],
      "privateKey": "$PRIVATE_KEY",
      "shortIds": ["$short_id"]
    }
  },
  "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true},
  "tag": "inbound-$port"
}
XHTTPEOF
)
      ;;
  esac

  if ! safe_jq_write ".inbounds += [$inbound]" "$CONFIG_FILE"; then
    echo -e "${RED}  ✗ Could not create the inbound in the config${NC}"
    return 1
  fi

  # Open firewall port. Не считаем неактивный UFW ошибкой создания профиля:
  # config.json уже валиден, а часть VPS управляет firewall вне ufw.
  open_firewall_port "$port" || \
    echo -e "${YELLOW}  ⚠ Port $port was not opened via UFW — check the firewall manually${NC}"
  return 0
}

# Удаление профиля
