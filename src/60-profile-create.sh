create_profile_menu() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}        СОЗДАНИЕ НОВОГО ПРОФИЛЯ               ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}\n"
  echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║              ВЫБЕРИТЕ ТИП ПРОФИЛЯ                         ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${CYAN} 1)${NC} Multi-route профиль ${YELLOW}(ручной режим, как готовая HAPP-подписка)${NC}"
  echo -e "    ${GREEN}✓${NC} Семь маршрутов в одном профиле: xhttp-legacy, xhttp-pq, TCP, gRPC"
  echo -e "    ${BLUE}ℹ${NC} Обычному HAPP-пользователю проще выбрать пункт 9 в главном меню"
  echo ""
  echo -e "${CYAN} 2)${NC} VLESS + TCP + Reality + Vision ${YELLOW}(legacy, отдельный профиль)${NC}"
  echo -e "    ${GREEN}✓${NC} Для sing-box, Hiddify, NekoBox, mihomo и старых клиентов без PQ"
  echo -e "    ${YELLOW}⚠${NC} На мобильных сетях режется чаще, чем XHTTP/Mux"
  echo ""
  echo -e "${CYAN} 3)${NC} VLESS + XHTTP + Reality + ${MAGENTA}Post-Quantum (mlkem768x25519plus.native)${NC}"
  echo -e "    ${GREEN}✓${NC} ML-KEM-768 защита от harvest-now-decrypt-later атак"
  echo -e "    ${GREEN}✓${NC} Самый ровный вариант под ТСПУ-2026: мобильные сети и домашние ISP"
  echo -e "    ${GREEN}✓${NC} Path и порт генерируются случайно, host берётся из текущего SNI"
  echo -e "    ${YELLOW}⚠${NC} Клиент должен поддерживать VLESS PQ encryption:"
  echo -e "       ${GREEN}✓${NC} HAPP 2.10+, v2rayNG 1.10+, v2rayN PR#7782+, Shadowrocket (последние версии)"
  echo -e "       ${RED}✗${NC} sing-box, NekoBox, Hiddify, mihomo — для них выберите пункт 2"
  echo ""
  echo -e "${CYAN} 4)${NC} VLESS + TCP + Reality + Mux ${GREEN}(случайный высокий порт)${NC}"
  echo -e "    ${GREEN}✓${NC} Хороший запасной вариант, если XHTTP-клиента нет"
  echo -e "    ${GREEN}✓${NC} Часто ведёт себя лучше Vision на мобильных сетях"
  echo -e "    ${BLUE}ℹ${NC} Mux включается на клиенте, без Vision-flow"
  echo ""
  echo -e "${CYAN} 5)${NC} VLESS + gRPC + Reality ${YELLOW}(случайный высокий порт)${NC}"
  echo -e "    ${YELLOW}⚠${NC} Работает только с SNI, где стабилен HTTP/2"
  echo -e "    ${YELLOW}⚠${NC} На части РУ-провайдеров и старых клиентов совместимость хуже"
  echo -e "    ${BLUE}ℹ${NC} serviceName генерируется случайно и сохраняется в профиле"
  echo ""
  echo -e "${CYAN} 6)${NC} VLESS + TCP + Reality + Vision + uTLS ${MAGENTA}(случайный высокий порт, Firefox)${NC}"
  echo -e "    ${GREEN}✓${NC} Подменяет TLS fingerprint под Firefox"
  echo -e "    ${BLUE}ℹ${NC} Имеет смысл на проводных линиях, где обычный Vision режется по fingerprint"
  echo -e "    ${YELLOW}⚠${NC} На мобильных сетях всё равно лучше сначала пробовать XHTTP"
  echo ""
  echo -e "${CYAN} 7)${NC} VLESS + TCP + Reality + Vision + XUDP ${YELLOW}(случайный высокий порт, anti-Tele2)${NC}"
  echo -e "    ${GREEN}✓${NC} Может помочь на самых жёстких мобильных фильтрах"
  echo -e "    ${GREEN}✓${NC} xtls-rprx-vision + xudp"
  echo -e "    ${GREEN}✓${NC} SNI: api-maps.yandex.ru по умолчанию"
  echo -e "    ${YELLOW}⚠${NC} Узкий сценарий, не базовый дефолт"
  echo ""
  echo -e "${CYAN} 8)${NC} Tailscale exit node не VLESS-профиль"
  echo -e "    ${BLUE}ℹ${NC} Устанавливает Tailscale и объявляет VPS как exit node"
  echo -e "    ${BLUE}ℹ${NC} Не создаёт Xray/VLESS profile JSON"
  echo ""
  echo -e "${CYAN} 0)${NC} Назад в главное меню"
  echo ""
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo -n -e "${YELLOW}Ваш выбор: ${NC}"
  read -r route_choice
  case $route_choice in
    1|2|3|4|5|6|7|xorpub) ;;
    8) tailscale_exit_node_menu; return ;;
    0) return ;;
    *) echo -e "${RED}Неверный выбор${NC}"; sleep 2; return ;;
  esac

  echo ""
  echo -n -e "${YELLOW}Введите имя профиля (или 0 для отмены): ${NC}"
  read -r profile_name
  if [[ "$profile_name" == "0" ]]; then
    return
  fi
  if [[ -z "$profile_name" ]]; then
    echo -e "${RED}✗ Имя не может быть пустым${NC}"
    sleep 2
    return
  fi
  if [[ ! "$profile_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo -e "${RED}✗ Используйте только буквы, цифры, дефис и подчеркивание${NC}"
    sleep 2
    return
  fi
  if [[ -f "$PROFILES_DIR/$profile_name.json" ]]; then
    echo -e "${RED}✗ Профиль с таким именем уже существует${NC}"
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
      echo -e "${MAGENTA}[ADVANCED] xorpub режим выбран${NC}"
      echo -e "${YELLOW}⚠ xorpub = security theater для Reality. Только для отладки/тестирования.${NC}"
      echo -e "${YELLOW}  Plan 6.2 не реализует отдельный xorpub-параметр vlessenc — профиль будет создан${NC}"
      echo -e "${YELLOW}  с дефолтным native ключом. xorpub-генерация — backlog (defer to v2.1).${NC}"
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
    echo -e "${RED}✗ Не удалось сгенерировать sub_token (openssl?)${NC}"
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
      echo -e "${RED}✗ Не удалось собрать JSON маршрута ${route_label}${NC}"
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
    echo -e "${RED}✗ Не удалось собрать JSON маршрутов${NC}"
    return 1
  }
  rm -f "$routes_tmp"

  local route_count
  route_count=$(jq 'length' <<< "$routes_json") || {
    echo -e "${RED}✗ Не удалось проверить количество маршрутов${NC}"
    return 1
  }
  if [[ "$route_count" != "7" ]]; then
    echo -e "${RED}✗ Multi-route профиль собран некорректно: маршрутов ${route_count}, ожидалось 7${NC}"
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
    echo -e "${RED}✗ Не удалось создать JSON профиля${NC}"
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
      echo -e "${RED}✗ XHTTP route ${label} собран без path; профиль удалён${NC}"
      return 1
    fi

    echo -e "${CYAN} → Маршрут ${label}: ${transport} :${port}${NC}"
    if ! add_inbound "$uuid" "$transport" "$port" "$sni" "$fingerprint" "$grpc" "$xhttp" "$pq"; then
      _restore_config_backup "$rollback_config" >/dev/null 2>&1 || true
      rm -f "$PROFILES_DIR/$name.json"
      local p
      for p in "${created_ports[@]}"; do
        close_firewall_port "$p"
      done
      echo -e "${RED}✗ Не удалось создать маршрут ${label}; профиль удалён, config.json откатан${NC}"
      if [[ "$pause_after" != "no_pause" ]]; then
        echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
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
    echo -e "${RED}         ✗ ПРОФИЛЬ НЕ АКТИВИРОВАН             ${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${RED}Xray не принял multi-route конфигурацию. Профиль удалён, config.json откатан.${NC}"
    if [[ "$pause_after" != "no_pause" ]]; then
      echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
      read -r _
    fi
    return 1
  fi

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}         ✓ ПРОФИЛЬ УСПЕШНО СОЗДАН!            ${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${BLUE}Имя профиля:${NC} ${GREEN}$name${NC}"
  echo -e "${BLUE}UUID:${NC} $uuid"
  echo -e "${BLUE}Маршрутов:${NC} $(jq 'length' <<< "$routes_json")"
  jq -r '.[] | "  - \(.label): \(.transport) :\(.port) sni=\(.sni)"' <<< "$routes_json"

  if [[ "$subscription_output" != "hide_subscription" ]]; then
    if [[ -f /usr/local/etc/xray/.subscription_installed ]]; then
      _happ_print_subscription_url_for_profile "$name"
    else
      echo ""
      echo -e "${YELLOW}ℹ HAPP-подписка ещё не установлена. Включите через 'Главное меню → Подписка HAPP'.${NC}"
    fi
  fi

  echo ""
  echo -e "${CYAN}Одна подписка этого профиля отдаёт все маршруты.${NC}"
  echo ""
  fix_xray_permissions
  if [[ "$pause_after" != "no_pause" ]]; then
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
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
  local uuid=$(uuidgen)

  # Phase 7 REQ-C04: sub_token (32 hex-символа) для HAPP subscription URL.
  # Один профиль = одна subscription URL; sub_token хранится в profile JSON.
  local sub_token
  sub_token=$(openssl rand -hex 16)
  if [[ ! "$sub_token" =~ ^[a-f0-9]{32}$ ]]; then
    echo -e "${RED}✗ Не удалось сгенерировать sub_token (openssl?)${NC}"
    return 1
  fi

  local default_sni=""
  local defaults=""

  if [[ -z "$port" ]]; then
    if ! defaults=$(build_transport_defaults "$transport"); then
      echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
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
    echo -e "${YELLOW}⚠ gRPC: используется SNI ${CYAN}$default_sni${YELLOW} (требуется HTTP/2)${NC}"
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

  if [[ "$port" == "443" ]] && [[ "$transport" == "tcp" || "$transport" == "tcp-utls" || "$transport" == "tcp-xudp" ]]; then
    if ! confirm_vision_443_risk; then
      echo -e "${CYAN}✓ Создание профиля отменено${NC}"
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
    echo -e "${RED}✗ Не удалось создать JSON профиля${NC}"
    return 1
  fi

  local rollback_config=""
  if ! backup_config "create_profile_$name" rollback_config; then
    rm -f "$PROFILES_DIR/$name.json"
    return 1
  fi
  if ! add_inbound "$uuid" "$transport" "$port" "$default_sni" "$fingerprint" "$grpc_service_name" "$xhttp_path"; then
    rm -f "$PROFILES_DIR/$name.json"
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════${NC}"
    echo -e "${RED}         ✗ ОШИБКА СОЗДАНИЯ ПРОФИЛЯ            ${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${RED}Inbound не создан — файл профиля удалён.${NC}"
    echo -e "${YELLOW}Попробуйте другой порт или транспорт.${NC}"
    echo ""
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read
    return 1
  fi

  if ! safe_restart_xray "$rollback_config"; then
    rm -f "$PROFILES_DIR/$name.json"
    close_firewall_port "$port"
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════${NC}"
    echo -e "${RED}         ✗ ПРОФИЛЬ НЕ АКТИВИРОВАН             ${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${RED}Xray не принял новую конфигурацию. Профиль удалён, config.json откатан.${NC}"
    echo -e "${YELLOW}Проверьте последний бэкап в /usr/local/etc/xray/backups/.${NC}"
    echo ""
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read
    return 1
  fi

  # Читаем актуальный SNI из файла (мог измениться при SNI-конфликте)
  local actual_sni=$(jq -r '.sni' "$PROFILES_DIR/$name.json" 2>/dev/null)
  [[ -z "$actual_sni" ]] && actual_sni="$default_sni"

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}         ✓ ПРОФИЛЬ УСПЕШНО СОЗДАН!            ${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${BLUE}Имя профиля:${NC} ${GREEN}$name${NC}"
  echo -e "${BLUE}UUID:${NC} $uuid"
  echo -e "${BLUE}Транспорт:${NC} $transport"
  echo -e "${BLUE}Порт:${NC} $port"
  echo -e "${BLUE}Fingerprint:${NC} $fingerprint"
  echo -e "${BLUE}SNI:${NC} $actual_sni"

  # Phase 7: subscription URL/QR — primary output если подписка установлена.
  # B1: URL строится через _subscription_base_url (Plan 7.2 helper) — никакого инлайна!
  if [[ -f /usr/local/etc/xray/.subscription_installed ]]; then
    _happ_print_subscription_url_for_profile "$name"
  else
    echo ""
    echo -e "${YELLOW}ℹ HAPP-подписка ещё не установлена. Включите через 'Главное меню → Подписка HAPP'.${NC}"
  fi

  echo ""
  echo -e "${CYAN}Используйте меню 'Подключиться по профилю' для получения ссылки${NC}"
  echo ""
  fix_xray_permissions
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
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
  local short_id=$(openssl rand -hex 4)
  [[ -z "$pq_enabled" && "$transport" == "xhttp" ]] && pq_enabled=true

  # Phase 6 REQ-A04: для PQ XHTTP-инбаундов читаем decryption из файла.
  # HAPP fallback XHTTP использует decryption=none, иначе это не fallback.
  # Файл создан Plan 6.1 (install.sh при свежей установке ИЛИ миграция .mlkem_keys_generated).
  # Если файл отсутствует — это runtime-ошибка: миграция должна была сработать.
  local vless_decryption="none"
  if [[ "$transport" == "xhttp" && "$pq_enabled" == "true" ]]; then
    if [[ ! -f "$VLESS_DECRYPTION_FILE" ]]; then
      echo -e "${RED}✗ PQ ключи отсутствуют: $VLESS_DECRYPTION_FILE${NC}"
      echo -e "${YELLOW}  Перезапустите xraytailscale — миграция .mlkem_keys_generated должна сгенерировать ключи${NC}"
      echo -e "${YELLOW}  Если миграция падает — проверьте: sudo /usr/local/bin/xray version (нужен ≥ 25.9.5)${NC}"
      return 1
    fi
    vless_decryption=$(cat "$VLESS_DECRYPTION_FILE")
    if [[ ! "$vless_decryption" =~ ^mlkem768x25519plus\. ]]; then
      echo -e "${RED}✗ $VLESS_DECRYPTION_FILE содержит невалидную PQ строку${NC}"
      echo -e "${YELLOW}  Удалите файл и перезапустите xraytailscale для регенерации${NC}"
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
      echo -e "${RED}✗ Порт $port уже используется с транспортом '$existing_transport' (несовместимо с '$transport')${NC}"
      echo -e "${YELLOW}Используйте другой порт для транспорта '$transport'${NC}"
      return 1
    fi

    # Check existing inbound's SNI
    local existing_sni=$(jq -r --argjson port "$port" \
      '.inbounds[] | select(.port == $port) | .streamSettings.realitySettings.serverNames[0]' \
      "$CONFIG_FILE" 2>/dev/null)

    if [[ -n "$existing_sni" ]] && [[ "$existing_sni" != "$sni" ]]; then
      echo ""
      echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
      echo -e "${RED}║         ⚠ КОНФЛИКТ SNI НА ПОРТУ $port                    ║${NC}"
      echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
      echo ""
      echo -e "${YELLOW}Порт $port уже используется с SNI: ${MAGENTA}$existing_sni${NC}"
      echo -e "${YELLOW}Новый профиль пытается использовать SNI: ${MAGENTA}$sni${NC}"
      echo ""
      echo -e "${CYAN}Xray Reality не поддерживает разные SNI на одном порту.${NC}"
      echo -e "${CYAN}Профиль будет создан с SNI: ${YELLOW}$existing_sni${NC}"
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
            echo -e "${YELLOW}  ⚠ Не удалось обновить SNI в профиле$(basename "$pf")${NC}"
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
        echo -e "${YELLOW}  ⚠ Не удалось синхронизировать transport metadata профиля $(basename "$profile_file")${NC}"
    fi

    echo -e "${CYAN} → Добавление клиента в существующий inbound на порту $port${NC}"
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
      echo -e "${RED}  ✗ Не удалось добавить клиента в inbound${NC}"
      return 1
    fi
    return
  fi

  echo -e "${CYAN} → Создание нового inbound на порту $port${NC}"
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
      "dest": "$sni:443",
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
      "dest": "$sni:443",
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
      "dest": "$sni:443",
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
      "dest": "$sni:443",
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
    echo -e "${RED}  ✗ Не удалось создать inbound в конфиге${NC}"
    return 1
  fi

  # Open firewall port. Не считаем неактивный UFW ошибкой создания профиля:
  # config.json уже валиден, а часть VPS управляет firewall вне ufw.
  open_firewall_port "$port" || \
    echo -e "${YELLOW}  ⚠ Порт $port не был открыт через UFW — проверьте firewall вручную${NC}"
  return 0
}

# Удаление профиля
