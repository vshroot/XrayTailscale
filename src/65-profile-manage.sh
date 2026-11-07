delete_profile_menu() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}             УДАЛЕНИЕ ПРОФИЛЯ                 ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}\n"
  local profiles=($(_list_visible_profile_names))
  if [[ ${#profiles[@]} -eq 0 ]]; then
    echo -e "${RED}✗ Нет созданных профилей${NC}"
    echo ""
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read
    return
  fi
  echo -e "${YELLOW}Доступные профили:${NC}\n"
  local i=1
  for profile in "${profiles[@]}"; do
    local transport=$(jq -r '.transport' "$PROFILES_DIR/$profile.json" 2>/dev/null)
    local port=$(jq -r '.port' "$PROFILES_DIR/$profile.json" 2>/dev/null)
    echo -e "${CYAN} $i)${NC} $profile ${BLUE}[$transport:$port]${NC}"
    ((i++))
  done
  echo -e "${CYAN} 0)${NC} Назад в главное меню\n"
  echo -n -e "${YELLOW}Выберите профиль для удаления: ${NC}"
  read choice
  if [[ "$choice" == "0" ]]; then
    return
  fi
  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#profiles[@]} ]]; then
    local profile_name="${profiles[$((choice-1))]}"
    echo ""
    echo -n -e "${RED}Вы уверены, что хотите удалить профиль '$profile_name'? (y/N): ${NC}"
    read confirm
    if [[ "$confirm" =~ ^[yYдД]$ ]]; then
      local profile_file="$PROFILES_DIR/$profile_name.json"
      local uuid=$(jq -r '.uuid' "$profile_file")
      local route_count
      route_count=$(_profile_route_count "$profile_file")

      local rollback_config=""
      if ! backup_config "delete_profile_$profile_name" rollback_config; then
        echo ""
        echo -e "${RED}✗ Не удалось создать бэкап config.json — профиль НЕ удалён${NC}"
        echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
        read
        return
      fi

      if [[ "$route_count" =~ ^[0-9]+$ ]] && [[ "$route_count" -gt 0 ]]; then
        local config_ok=true
        local port clients_count
        local route_ports=()
        while IFS= read -r port; do
          [[ -z "$port" ]] && continue
          route_ports+=("$port")
          clients_count=$(jq -r --argjson port "$port" \
            '.inbounds[] | select(.port == $port) | .settings.clients | length' \
            "$CONFIG_FILE" 2>/dev/null)
          [[ -z "$clients_count" ]] && clients_count=0
          if [[ "$clients_count" -le 1 ]]; then
            safe_jq_write --argjson port "$port" 'del(.inbounds[] | select(.port == $port))' "$CONFIG_FILE" || config_ok=false
          else
            safe_jq_write --arg uuid "$uuid" --argjson port "$port" \
              '(.inbounds[] | select(.port == $port) | .settings.clients) |= map(select(.id != $uuid))' \
              "$CONFIG_FILE" || config_ok=false
          fi
        done < <(jq -r '.routes[].port' "$profile_file")

        if [[ "$config_ok" == "true" ]]; then
          if safe_restart_xray "$rollback_config"; then
            rm -f "$profile_file"
            local p
            for p in "${route_ports[@]}"; do
              close_firewall_port "$p"
            done
            fix_xray_permissions
            echo ""
            echo -e "${GREEN}✓ Multi-route профиль '$profile_name' успешно удален${NC}"
          else
            echo ""
            echo -e "${RED}✗ Xray не перезапустился — config.json откачен, профиль НЕ удалён${NC}"
          fi
        else
          echo ""
          echo -e "${RED}✗ Ошибка обновления конфига — профиль НЕ удалён${NC}"
        fi
        echo ""
        echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
        read
        return
      fi

      local port=$(jq -r '.port' "$profile_file")

      # Считаем клиентов через config.json (надёжнее чем файлы профилей)
      local clients_count=$(jq -r --argjson port "$port" \
        '.inbounds[] | select(.port == $port) | .settings.clients | length' \
        "$CONFIG_FILE" 2>/dev/null)
      [[ -z "$clients_count" ]] && clients_count=0

      local config_ok=false
      if [[ "$clients_count" -le 1 ]]; then
        # Единственный клиент (или inbound отсутствует) — удаляем весь inbound
        if safe_jq_write --argjson port "$port" 'del(.inbounds[] | select(.port == $port))' "$CONFIG_FILE"; then
          echo -e "${CYAN}  → Удаление inbound на порту $port${NC}"
          config_ok=true
        fi
      else
        # Есть другие клиенты — удаляем только этого (scoped по порту)
        if safe_jq_write --arg uuid "$uuid" --argjson port "$port" '
          (.inbounds[] | select(.port == $port) | .settings.clients) |= map(select(.id != $uuid))
        ' "$CONFIG_FILE"; then
          echo -e "${CYAN}  → Удаление клиента из inbound (порт $port используется другими профилями)${NC}"
          config_ok=true
        fi
      fi

      if [[ "$config_ok" == "true" ]]; then
        if safe_restart_xray "$rollback_config"; then
          rm -f "$PROFILES_DIR/$profile_name.json"

          # Close firewall port if not used by other profiles
          close_firewall_port "$port"

          fix_xray_permissions
          echo ""
          echo -e "${GREEN}✓ Профиль '$profile_name' успешно удален${NC}"
        else
          echo ""
          echo -e "${RED}✗ Xray не перезапустился — config.json откачен, профиль НЕ удалён${NC}"
        fi
      else
        echo ""
        echo -e "${RED}✗ Ошибка обновления конфига — профиль НЕ удалён${NC}"
      fi
    else
      echo -e "${YELLOW}⚠ Удаление отменено${NC}"
    fi
  else
    echo -e "${RED}✗ Неверный выбор${NC}"
  fi
  echo ""
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read
}

# Подключение к профилю
connect_profile_menu() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}          ПОДКЛЮЧЕНИЕ К ПРОФИЛЮ               ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}\n"
  local profiles=($(_list_visible_profile_names))
  if [[ ${#profiles[@]} -eq 0 ]]; then
    echo -e "${RED}✗ Нет созданных профилей${NC}"
    echo -e "${CYAN}Создайте профиль через меню 'Создать новый профиль'${NC}"
    echo ""
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read
    return
  fi
  echo -e "${YELLOW}Доступные профили:${NC}\n"
  local i=1
  for profile in "${profiles[@]}"; do
    local transport=$(jq -r '.transport' "$PROFILES_DIR/$profile.json" 2>/dev/null)
    local port=$(jq -r '.port' "$PROFILES_DIR/$profile.json" 2>/dev/null)
    echo -e "${CYAN} $i)${NC} $profile ${BLUE}[$transport:$port]${NC}"
    ((i++))
  done
  echo -e "${CYAN} 0)${NC} Назад в главное меню\n"
  echo -n -e "${YELLOW}Выберите профиль: ${NC}"
  read choice
  if [[ "$choice" == "0" ]]; then
    return
  fi
  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#profiles[@]} ]]; then
    local profile_name="${profiles[$((choice-1))]}"
    generate_connection "$profile_name"
  else
    echo -e "${RED}✗ Неверный выбор${NC}"
    sleep 2
  fi
}

manage_profile_menu() {
  while true; do
    show_ascii
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}         УПРАВЛЕНИЕ ПРОФИЛЕМ                  ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}\n"

    local profiles=($(_list_visible_profile_names))
    if [[ ${#profiles[@]} -eq 0 ]]; then
      echo -e "${RED}Нет созданных профилей${NC}"
      echo -e "${CYAN}Создайте профиль через главное меню 'Создать новый профиль'${NC}"
      echo ""
      echo -n -e "${YELLOW}Нажмите Enter для возврата...${NC}"
      read -r _
      return
    fi

    echo -e "${YELLOW}Выберите профиль для управления:${NC}\n"
    local i=1
    local profile
    for profile in "${profiles[@]}"; do
      local transport
      local port
      local sni
      transport=$(jq -r '.transport' "$PROFILES_DIR/$profile.json" 2>/dev/null)
      port=$(jq -r '.port' "$PROFILES_DIR/$profile.json" 2>/dev/null)
      sni=$(jq -r '.sni' "$PROFILES_DIR/$profile.json" 2>/dev/null)
      echo -e "${CYAN} $i)${NC} $profile ${BLUE}[$transport:$port sni=$sni]${NC}"
      ((i++))
    done
    echo -e "${CYAN} 0)${NC} Назад в главное меню\n"
    echo -n -e "${YELLOW}Выбор: ${NC}"
    local pchoice
    read -r pchoice

    [[ "$pchoice" == "0" ]] && return
    if [[ ! "$pchoice" =~ ^[0-9]+$ ]] || [[ $pchoice -lt 1 ]] || [[ $pchoice -gt ${#profiles[@]} ]]; then
      echo -e "${RED}Неверный выбор${NC}"
      sleep 1
      continue
    fi

    local selected="${profiles[$((pchoice-1))]}"

    while true; do
      show_ascii
      echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
      echo -e "${BLUE}    ДЕЙСТВИЯ С ПРОФИЛЕМ: $selected${NC}"
      echo -e "${BLUE}═══════════════════════════════════════════════${NC}\n"
      echo -e "${CYAN} 1)${NC} Изменить SNI (домен маскировки)"
      echo -e "${CYAN} 2)${NC} Изменить Fingerprint (браузер)"
      echo -e "${CYAN} 3)${NC} Изменить порт"
      echo -e "${CYAN} 4)${NC} Адванс настройки (experimental)"
      echo -e "${CYAN} 0)${NC} Назад (выбрать другой профиль)\n"
      echo -n -e "${YELLOW}Выбор: ${NC}"
      local achoice
      read -r achoice
      case "$achoice" in
        1) change_sni_menu ;;
        2) change_fingerprint_menu ;;
        3) change_port_menu ;;
        4) manage_profile_advanced_menu "$selected" ;;
        0) break ;;
        *) echo -e "${RED}Неверный выбор${NC}"; sleep 1 ;;
      esac
    done
  done
}

# Генерация данных подключения
generate_connection() {
  local profile_name=$1
  local profile_file="$PROFILES_DIR/$profile_name.json"
  local route_count
  route_count=$(_profile_route_count "$profile_file")
  if [[ "$route_count" =~ ^[0-9]+$ ]] && [[ "$route_count" -gt 0 ]]; then
    show_ascii
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
    echo -e "${GREEN}    ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ: $profile_name${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════${NC}\n"
    echo -e "${BLUE}Маршруты в профиле:${NC}"
    jq -r '.routes[] | "  - \(.label): \(.transport) :\(.port) sni=\(.sni)"' "$profile_file"
    echo ""

    if [[ -f /usr/local/etc/xray/.subscription_installed ]]; then
      local token base_url url
      token=$(jq -r '.sub_token // ""' "$profile_file")
      base_url=$(_subscription_base_url)
      url="${base_url}/sub/${token}"
      if _subscription_is_local_only; then
        echo -e "${YELLOW}Local-only debug subscription:${NC} ${url}"
        echo -e "${RED}QR не показываю: 127.0.0.1 не доступен внешнему клиенту.${NC}"
      else
        echo -e "${BLUE}Subscription URL:${NC} ${GREEN}${url}${NC}"
        echo ""
        qrencode -t ANSIUTF8 "$url"
      fi
    fi

    echo ""
    echo -e "${CYAN}Raw vless:// строки (advanced):${NC}"
    _generate_vless_urls_for_profile "$profile_file" | sed 's/^/  /'
    echo ""
    echo -e "${YELLOW}Для HAPP используйте subscription URL: он отдаёт все маршруты одной подпиской.${NC}"
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read -r _
    return 0
  fi

  local uuid=$(jq -r '.uuid' "$profile_file")
  local transport=$(jq -r '.transport' "$profile_file")
  local port=$(jq -r '.port' "$profile_file")
  local fingerprint=$(jq -r --arg default_fp "$DEFAULT_CLIENT_FINGERPRINT" '.fingerprint // $default_fp' "$profile_file")
  local current_sni=$(jq -r '.sni // "www.ozon.ru"' "$profile_file")
  local clean_public_key=$(cat "$PUBLIC_KEY_FILE")
  # Phase 7 REQ-C10: pq_enabled lookup ВВЕРХ — нужен блокам печати manual-параметров
  # независимо от того, какая ветка транспорта сработала.
  local pq_enabled
  pq_enabled=$(jq -r '.pq_enabled // false' "$profile_file" 2>/dev/null)
  local transport_metadata=""
  local grpc_service_name=""
  local xhttp_path=""
  local encoded_xhttp_path=""

  transport_metadata=$(read_profile_transport_metadata "$profile_file")
  IFS='|' read -r grpc_service_name xhttp_path <<< "$transport_metadata"
  encoded_xhttp_path=$(jq -nr --arg path "$xhttp_path" '$path|@uri')

  # Read shortId from config for this port's inbound
  local short_id=$(jq -r --argjson port "$port" \
    '.inbounds[] | select(.port == $port) | .streamSettings.realitySettings.shortIds[0]' \
    "$CONFIG_FILE" 2>/dev/null)
  [[ -z "$short_id" || "$short_id" == "null" ]] && short_id=""

  show_ascii
  echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}    ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ: $profile_name${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════${NC}\n"
  # Phase 7 REQ-C10: построение vless:// делегировано pure-функции _generate_vless_url_pure.
  # Все транспорты (tcp/tcp-utls/tcp-xudp/tcp-mux/grpc/xhttp legacy/xhttp PQ) обрабатываются там.
  local vless_link
  vless_link=$(_generate_vless_url_pure "$profile_file") || {
    echo -e "${RED}✗ Не удалось построить vless:// URL для профиля $profile_name${NC}"
    if [[ "$transport" == "xhttp" ]] && [[ "$pq_enabled" == "true" ]] && [[ ! -f "$VLESS_ENCRYPTION_FILE" ]]; then
      echo -e "${YELLOW}  Причина: $VLESS_ENCRYPTION_FILE отсутствует. Перезапустите xraytailscale (миграция .mlkem_keys_generated).${NC}"
    fi
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read -r
    return 1
  }
  echo -e "${BLUE}Ссылка для подключения:${NC}"
  echo -e "${YELLOW}${vless_link}${NC}\n"
  echo -e "${BLUE}QR-код:${NC}\n"
  qrencode -t ANSIUTF8 "$vless_link"
  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
  echo -e "${CYAN}Параметры для ручной настройки:${NC}"
  echo ""
  echo -e "${CYAN}Адрес:${NC} $SERVER_IP"
  echo -e "${CYAN}Порт:${NC} $port"
  echo -e "${CYAN}UUID:${NC} $uuid"
  case $transport in
    tcp|tcp-utls|tcp-xudp)
      echo -e "${CYAN}Flow:${NC} xtls-rprx-vision"
      ;;
    tcp-mux)
      echo -e "${CYAN}Flow:${NC} (пустой)"
      echo -e "${CYAN}Mux:${NC} включить на клиенте (sing-box: multiplex, v2rayN: mux)"
      ;;
    grpc|xhttp)
      echo -e "${CYAN}Flow:${NC} (пустой)"
      ;;
  esac
  # Phase 6: Encryption строка зависит от pq_enabled (только для XHTTP)
  if [[ "$transport" == "xhttp" ]] && [[ "${pq_enabled:-false}" == "true" ]]; then
    echo -e "${CYAN}Encryption:${NC} ${MAGENTA}mlkem768x25519plus.native${NC}"
  else
    echo -e "${CYAN}Encryption:${NC} none"
  fi
  echo -e "${CYAN}Transport:${NC} $transport"
  echo -e "${CYAN}Security:${NC} reality"
  echo -e "${CYAN}SNI:${NC} $current_sni"
  echo -e "${CYAN}Fingerprint:${NC} $fingerprint"
  echo -e "${CYAN}PublicKey:${NC} $clean_public_key"
  echo -e "${CYAN}ShortID:${NC} ${short_id:-(пустой)}"
  if [[ "$transport" == "tcp" ]] || [[ "$transport" == "tcp-utls" ]] || [[ "$transport" == "tcp-xudp" ]] || [[ "$transport" == "tcp-mux" ]]; then
    echo -e "${CYAN}SpiderX:${NC} /"
  elif [[ "$transport" == "grpc" ]]; then
    echo -e "${CYAN}serviceName:${NC} $grpc_service_name"
    echo -e "${YELLOW}ℹ gRPC:${NC} нужен SNI с живым HTTP/2; на части РУ-провайдеров капризнее XHTTP"
  elif [[ "$transport" == "xhttp" ]]; then
    echo -e "${CYAN}Path:${NC} $xhttp_path"
    echo -e "${CYAN}Host:${NC} $current_sni"
    if [[ "${pq_enabled:-false}" == "true" ]]; then
      echo ""
      echo -e "${MAGENTA}ℹ XHTTP + Post-Quantum (mlkem768x25519plus.native):${NC}"
      echo -e "${YELLOW}⚠ Клиенты должны поддерживать VLESS PQ encryption:${NC}"
      echo -e "  ${GREEN}✓${NC} HAPP 2.10+, v2rayNG 1.10+, v2rayN PR#7782+, Shadowrocket (новые версии)"
      echo -e "  ${RED}✗${NC} sing-box, NekoBox, Hiddify, mihomo (создайте отдельный legacy TCP+Vision профиль)"
    else
      echo ""
      echo -e "${YELLOW}ℹ XHTTP:${NC} текущий рекомендуемый вариант под ТСПУ-2026"
      echo -e "${YELLOW}⚠ XHTTP требует современные клиенты:${NC}"
      echo -e "  ${GREEN}✓${NC} sing-box 1.8+, v2rayN 6.x+, v2rayNG 1.8.x+"
      echo -e "  ${RED}✗${NC} Clash Meta, старые версии клиентов"
    fi
  fi
  echo -e "${GREEN}═══════════════════════════════════════════════${NC}\n"
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read
}

# Смена SNI
change_sni_menu() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}    ПОДМЕНА SNI ПРОФИЛЯ (МАСКИРОВКА)         ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}\n"

  local profiles=($(_list_visible_profile_names))
  if [[ ${#profiles[@]} -eq 0 ]]; then
    echo -e "${RED}✗ Нет созданных профилей${NC}"
    echo ""
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read
    return
  fi

  echo -e "${YELLOW}Выберите профиль для смены SNI:${NC}\n"
  local i=1
  for profile in "${profiles[@]}"; do
    local sni=$(jq -r '.sni // "не задан"' "$PROFILES_DIR/$profile.json" 2>/dev/null)
    local port=$(jq -r '.port' "$PROFILES_DIR/$profile.json" 2>/dev/null)
    echo -e "${CYAN} $i)${NC} $profile ${BLUE}[порт:$port]${NC} ${YELLOW}[SNI:$sni]${NC}"
    ((i++))
  done
  echo -e "${CYAN} 0)${NC} Назад в главное меню\n"

  echo -n -e "${YELLOW}Выберите профиль: ${NC}"
  read choice

  if [[ "$choice" == "0" ]]; then
    return
  fi

  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#profiles[@]} ]]; then
    echo -e "${RED}✗ Неверный выбор${NC}"
    sleep 2
    return
  fi

  local selected="${profiles[$((choice-1))]}"
  local profile_file="$PROFILES_DIR/$selected.json"
  local route_index=""
  local route_label=""
  local current_sni
  local transport
  local port
  local target_label="$selected"

  if profile_has_routes "$profile_file"; then
    select_route_for_profile "$profile_file" "смены SNI" || return
    route_index="$SELECTED_ROUTE_INDEX"
    route_label=$(jq -r --argjson i "$route_index" '.routes[$i].label // .routes[$i].transport // ("route-" + ($i|tostring))' "$profile_file")
    current_sni=$(jq -r --argjson i "$route_index" '.routes[$i].sni // .sni // "www.ozon.ru"' "$profile_file")
    transport=$(jq -r --argjson i "$route_index" '.routes[$i].transport // .transport // "tcp"' "$profile_file")
    port=$(jq -r --argjson i "$route_index" '.routes[$i].port // empty' "$profile_file")
    target_label="$selected/$route_label"
  else
    current_sni=$(jq -r '.sni // "www.ozon.ru"' "$profile_file")
    transport=$(jq -r '.transport // "tcp"' "$profile_file")
    port=$(jq -r '.port' "$profile_file")
  fi

  echo ""
  echo -e "${CYAN}Текущий SNI '${target_label}':${NC} ${GREEN}$current_sni${NC}"
  echo -e "${CYAN}Транспорт:${NC} ${YELLOW}$transport${NC}\n"

  # gRPC требует HTTP/2, российские сайты не поддерживают
  if [[ "$transport" == "grpc" ]]; then
    echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║     ⚠ gRPC ТРЕБУЕТ ЗАРУБЕЖНЫЕ SNI (HTTP/2)              ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}gRPC работает только с сайтами поддерживающими HTTP/2.${NC}"
    echo -e "${YELLOW}Российские сайты (Ozon, WB, Sber и др.) НЕ поддерживают HTTP/2.${NC}"
    echo ""
    echo -e "${GREEN}Рекомендуемые SNI для gRPC:${NC}"
    echo -e "  ${CYAN}1)${NC} www.cloudflare.com ${BLUE}(рекомендуется)${NC}"
    echo -e "  ${CYAN}2)${NC} github.com"
    echo -e "  ${CYAN}3)${NC} aws.amazon.com"
    echo -e "  ${CYAN}4)${NC} cdn.cloudflare.net"
    echo -e "  ${CYAN}0)${NC} Назад\n"
    echo -n -e "${YELLOW}Выберите SNI для gRPC: ${NC}"
    read grpc_choice

    case $grpc_choice in
      1) new_sni="www.cloudflare.com" ;;
      2) new_sni="github.com" ;;
      3) new_sni="aws.amazon.com" ;;
      4) new_sni="cdn.cloudflare.net" ;;
      0|*) return ;;
    esac

    if [[ "$new_sni" == "$current_sni" ]]; then
      echo -e "${YELLOW}⚠ Этот SNI уже используется${NC}"
      sleep 2
      return
    fi

    # Переходим к обновлению SNI (пропускаем общий список)
    local profiles_on_port=($(get_profiles_on_port "$port"))

    if [[ ${#profiles_on_port[@]} -gt 1 ]]; then
      echo ""
      echo -e "${RED}⚠ На порту $port есть другие профили:${NC}"
      for p in "${profiles_on_port[@]}"; do
        echo -e "  ${CYAN}•${NC} $p"
      done
      echo -e "${YELLOW}Все они будут обновлены на SNI: ${MAGENTA}$new_sni${NC}"
    fi

    echo ""
    echo -n -e "${YELLOW}Применить SNI '$new_sni'? (y/N): ${NC}"
    read confirm
    if [[ "$confirm" =~ ^[yYдД]$ ]]; then
      local rollback_config=""
      if ! backup_config "change_sni_$selected" rollback_config; then
        echo -e "${RED}✗ Не удалось создать бэкап config.json${NC}"
        sleep 2
        return
      fi

      # Update config
      if ! update_transport_settings_for_sni "$port" "$new_sni" "$CONFIG_FILE"; then
        echo -e "${RED}✗ Ошибка обновления config.json${NC}"
        sleep 2
        return
      fi

      fix_xray_permissions
      if ! safe_restart_xray "$rollback_config"; then
        echo -e "${RED}✗ Xray не перезапустился — config.json откачен, профили НЕ изменены${NC}"
        sleep 2
        return
      fi

      # Update all profile/route JSON entries tied to this inbound port
      if ! update_all_profiles_on_port "$port" "sni" "$new_sni"; then
        echo -e "${RED}✗ Ошибка обновления профиля${NC}"
        sleep 2
        return
      fi

      echo ""
      echo -e "${GREEN}✓ SNI '${target_label}' изменен на: ${YELLOW}$new_sni${NC}"
      echo ""
      echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
      read
    fi
    return
  fi

  if [[ ! -f "$SNI_LIST" ]]; then
    echo -e "${RED}✗ Файл списка SNI не найден${NC}"
    echo ""
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read
    return
  fi

  declare -A sni_desc
  sni_desc["www.ozon.ru"]="E-commerce, макс. устойчивость для мобильных"
  sni_desc["api.ozon.ru"]="Ozon API, хорошо в паре с основным"
  sni_desc["st.ozon.ru"]="Ozon CDN статика"
  sni_desc["ir.ozon.ru"]="Ozon CDN изображения"
  sni_desc["www.wildberries.ru"]="E-commerce, стабильно для Мегафон/Ростелеком"
  sni_desc["splitter.wb.ru"]="Wildberries CDN"
  sni_desc["www.sberbank.ru"]="Банк, оптимально для региональных сетей"
  sni_desc["www.tinkoff.ru"]="Банк, стабильный вариант"
  sni_desc["www.alfabank.ru"]="Банк, запасной вариант"
  sni_desc["www.nspk.ru"]="Нац. платёжная система, сложно блокировать"
  sni_desc["sbp.nspk.ru"]="СБП, идеально для МТС"
  sni_desc["stats.vk-portal.net"]="VK мониторинг, хорош для стационарных"
  sni_desc["queuev4.vk.com"]="VK CDN, часто работает на мобильных"
  sni_desc["www.kinopoisk.ru"]="Медиа, обычно стабильный"
  sni_desc["www.gosuslugi.ru"]="Госуслуги, для сложных регионов"
  sni_desc["www.mos.ru"]="Портал Москвы"
  sni_desc["speller.yandex.net"]="Яндекс CDN, универсальный вариант"
  sni_desc["api-maps.yandex.ru"]="Яндекс Карты API"
  sni_desc["mc.yandex.ru"]="Яндекс Метрика"
  sni_desc["suggest.yandex.ru"]="Яндекс подсказки"
  sni_desc["www.github.com"]="Только если российские не работают!"
  sni_desc["www.cloudflare.com"]="Для корпоративных каналов"
  sni_desc["aws.amazon.com"]="AWS CDN, запасной вариант для gRPC"

  echo -e "${YELLOW}ТОП-20 доменов для маскировки:${NC}\n"
  local idx=1
  local sni_array=()
  while IFS='|' read -r domain category priority || [[ -n "$domain" ]]; do
    # Skip comments and empty lines
    [[ "$domain" =~ ^#.*$ ]] && continue
    [[ "$domain" =~ ^[[:space:]]*$ ]] && continue
    [[ -z "$domain" ]] && continue

    sni_array[$idx]="$domain"
    local desc="${sni_desc[$domain]}"
    [[ -z "$desc" ]] && desc="Дополнительный вариант"
    if [[ "$domain" == "$current_sni" ]]; then
      printf "${CYAN}%2d)${NC} %-40s ${GREEN}[текущий]${NC}\n" $idx "$domain"
    else
      printf "${CYAN}%2d)${NC} %-40s ${BLUE}%s${NC}\n" $idx "$domain" "$desc"
    fi
    ((idx++))
    [[ $idx -gt 20 ]] && break
  done < "$SNI_LIST"

  echo ""
  echo -e "${MAGENTA}Полный актуальный список:${NC} ${GREEN}$SNI_LIST${NC}"
  echo -e "${YELLOW}Обновляйте минимум раз в месяц!${NC}\n"
  echo -e "${CYAN} 0)${NC} Назад\n"
  echo -n -e "${YELLOW}Выберите новый SNI: ${NC}"
  read sni_choice

  if [[ "$sni_choice" == "0" ]]; then
    return
  fi

  local new_sni="${sni_array[$sni_choice]}"
  if [[ -z "$new_sni" ]]; then
    echo -e "${RED}✗ Неверный выбор${NC}"
    sleep 2
    return
  fi

  if [[ "$new_sni" == "$current_sni" ]]; then
    echo -e "${YELLOW}⚠ Этот SNI уже используется${NC}"
    sleep 2
    return
  fi

  # Check for shared inbound
  local profiles_on_port=($(get_profiles_on_port "$port"))
  local shared_inbound=false

  if [[ ${#profiles_on_port[@]} -gt 1 ]]; then
    shared_inbound=true

    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║         ⚠ ВНИМАНИЕ: ОБЩИЙ INBOUND НА ПОРТУ $port        ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Следующие профили используют порт $port:${NC}"
    echo ""

    for p in "${profiles_on_port[@]}"; do
      local psni=$(jq -r '.sni' "$PROFILES_DIR/$p.json")
      echo -e "  ${CYAN}•${NC} ${YELLOW}$p${NC} (текущий SNI: $psni)"
    done

    echo ""
    echo -e "${MAGENTA}Смена SNI обновит ВСЕ эти профили!${NC}"
    echo -e "${YELLOW}Все профили на порту $port будут использовать SNI: ${MAGENTA}$new_sni${NC}"
    echo ""
    echo -e "${CYAN}Xray Reality: SNI привязан к порту, а не к профилю.${NC}"
    echo -e "${CYAN}Для разных SNI используйте разные порты.${NC}"
    echo ""
  fi

  echo ""
  echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║            ⚠ КРИТИЧЕСКОЕ ПРЕДУПРЕЖДЕНИЕ ⚠               ║${NC}"
  echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${YELLOW}Смена SNI обновит конфигурацию '${target_label}'.${NC}"
  echo ""
  echo -e "${RED}Активные подключения этого профиля будут разорваны!${NC}"
  echo ""
  echo -e "${CYAN}После смены необходимо:${NC}"
  echo -e "  ${BLUE}1.${NC} Получить НОВУЮ ссылку для профиля '$selected'"
  echo -e "  ${BLUE}2.${NC} Обновить конфигурацию в клиентах"
  echo ""
  echo -e "${MAGENTA}Новый SNI: ${YELLOW}$new_sni${NC}"
  echo ""
  echo -n -e "${YELLOW}Продолжить? (y/N): ${NC}"
  read confirm

  if [[ ! "$confirm" =~ ^[yYдД]$ ]]; then
    echo -e "${CYAN}✓ Отменено${NC}"
    sleep 1
    return
  fi

  local rollback_config=""
  if ! backup_config "change_sni_$selected" rollback_config; then
    echo -e "${RED}✗ Не удалось создать бэкап config.json${NC}"
    sleep 2
    return
  fi

  # Update config (transport-aware)
  if ! update_transport_settings_for_sni "$port" "$new_sni" "$CONFIG_FILE"; then
    echo -e "${RED}✗ Ошибка обновления config.json${NC}"
    sleep 2
    return
  fi

  fix_xray_permissions
  if ! safe_restart_xray "$rollback_config"; then
    echo -e "${RED}✗ Xray не перезапустился — config.json откачен, профили НЕ изменены${NC}"
    sleep 2
    return
  fi

  # Update all profile/route JSON entries tied to this inbound port
  if ! update_all_profiles_on_port "$port" "sni" "$new_sni"; then
    echo -e "${RED}✗ Ошибка обновления профиля${NC}"
    sleep 2
    return
  fi

  echo ""
  echo -e "${GREEN}✓ SNI '${target_label}' изменен на: ${YELLOW}$new_sni${NC}"
  echo ""
  echo -e "${MAGENTA}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}║     Теперь получите новую ссылку для этого профиля!     ║${NC}"
  echo -e "${MAGENTA}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read
}

# Смена Fingerprint
change_fingerprint_menu() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}   ПОДМЕНА FINGERPRINT (TLS БРАУЗЕР)         ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}\n"

  local profiles=($(_list_visible_profile_names))
  if [[ ${#profiles[@]} -eq 0 ]]; then
    echo -e "${RED}✗ Нет созданных профилей${NC}"
    echo ""
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read
    return
  fi

  echo -e "${YELLOW}Выберите профиль для смены fingerprint:${NC}\n"
  local i=1
  for profile in "${profiles[@]}"; do
    local fp=$(jq -r --arg default_fp "$DEFAULT_CLIENT_FINGERPRINT" '.fingerprint // $default_fp' "$PROFILES_DIR/$profile.json" 2>/dev/null)
    local port=$(jq -r '.port' "$PROFILES_DIR/$profile.json" 2>/dev/null)
    echo -e "${CYAN} $i)${NC} $profile ${BLUE}[порт:$port]${NC} ${YELLOW}[fp:$fp]${NC}"
    ((i++))
  done
  echo -e "${CYAN} 0)${NC} Назад в главное меню\n"

  echo -n -e "${YELLOW}Выберите профиль: ${NC}"
  read choice

  if [[ "$choice" == "0" ]]; then
    return
  fi

  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#profiles[@]} ]]; then
    echo -e "${RED}✗ Неверный выбор${NC}"
    sleep 2
    return
  fi

  local selected="${profiles[$((choice-1))]}"
  local profile_file="$PROFILES_DIR/$selected.json"
  local route_index=""
  local route_label=""
  local current_fp
  local port
  local target_label="$selected"

  if profile_has_routes "$profile_file"; then
    select_route_for_profile "$profile_file" "смены fingerprint" || return
    route_index="$SELECTED_ROUTE_INDEX"
    route_label=$(jq -r --argjson i "$route_index" '.routes[$i].label // .routes[$i].transport // ("route-" + ($i|tostring))' "$profile_file")
    current_fp=$(jq -r --argjson i "$route_index" --arg default_fp "$DEFAULT_CLIENT_FINGERPRINT" '.routes[$i].fingerprint // .fingerprint // $default_fp' "$profile_file")
    port=$(jq -r --argjson i "$route_index" '.routes[$i].port // empty' "$profile_file")
    target_label="$selected/$route_label"
  else
    current_fp=$(jq -r --arg default_fp "$DEFAULT_CLIENT_FINGERPRINT" '.fingerprint // $default_fp' "$profile_file")
    port=$(jq -r '.port' "$profile_file")
  fi

  echo ""
  echo -e "${CYAN}Текущий fingerprint '${target_label}':${NC} ${GREEN}$current_fp${NC}\n"
  echo -e "${YELLOW}Доступные fingerprint (эмуляция браузера):${NC}\n"
  echo -e "${CYAN} 1)${NC} chrome    ${YELLOW}(legacy, может блокироваться)${NC}"
  echo -e "${CYAN} 2)${NC} firefox   ${GREEN}(default, рекомендуется)${NC}"
  echo -e "${CYAN} 3)${NC} safari    ${BLUE}(для iOS/macOS клиентов)${NC}"
  echo -e "${CYAN} 4)${NC} edge      ${BLUE}(альтернатива chrome)${NC}"
  echo -e "${CYAN} 5)${NC} ios       ${BLUE}(для старых iOS устройств)${NC}"
  echo -e "${CYAN} 6)${NC} random    ${YELLOW}(случайный, экспериментально)${NC}"
  echo -e "${CYAN} 0)${NC} Назад\n"

  echo -n -e "${YELLOW}Выберите новый fingerprint: ${NC}"
  read fp_choice

  local new_fp=""
  case $fp_choice in
    1) new_fp="chrome" ;;
    2) new_fp="firefox" ;;
    3) new_fp="safari" ;;
    4) new_fp="edge" ;;
    5) new_fp="ios" ;;
    6) new_fp="random" ;;
    0) return ;;
    *) echo -e "${RED}✗ Неверный выбор${NC}"; sleep 2; return ;;
  esac

  if [[ "$new_fp" == "$current_fp" ]]; then
    echo -e "${YELLOW}⚠ Этот fingerprint уже используется${NC}"
    sleep 2
    return
  fi

  echo ""
  echo -e "${YELLOW}Смена fingerprint изменит TLS имитацию браузера.${NC}"
  echo ""
  echo -e "${CYAN}Xray перезапускаться не будет; другие маршруты и профили не изменятся.${NC}"
  echo -e "${CYAN}После смены принудительно обновите подписку в HAPP или переимпортируйте ссылку.${NC}"
  echo ""
  echo -e "${MAGENTA}Новый fingerprint: ${YELLOW}$new_fp${NC}"
  echo ""
  echo -n -e "${YELLOW}Продолжить? (y/N): ${NC}"
  read confirm

  if [[ ! "$confirm" =~ ^[yYдД]$ ]]; then
    echo -e "${CYAN}✓ Отменено${NC}"
    sleep 1
    return
  fi

  # Fingerprint is client-only state. The atomic profile write immediately
  # changes the dynamically generated subscription without restarting Xray.
  if ! update_profile_fingerprint "$profile_file" "$route_index" "$new_fp"; then
    echo -e "${RED}✗ Ошибка обновления профиля${NC}"
    sleep 2
    return
  fi

  echo ""
  echo -e "${GREEN}✓ Fingerprint '${target_label}' изменен на: ${YELLOW}$new_fp${NC}"
  echo ""
  echo -e "${GREEN}✓ Подписка на сервере уже содержит новый fp=${new_fp}.${NC}"
  echo ""
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read
}

# Смена порта профиля
change_port_menu() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}         ИЗМЕНЕНИЕ ПОРТА ПРОФИЛЯ              ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}\n"
  local profiles=($(_list_visible_profile_names))
  if [[ ${#profiles[@]} -eq 0 ]]; then
    echo -e "${RED}✗ Нет созданных профилей${NC}"
    echo ""
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read
    return
  fi
  echo -e "${YELLOW}Выберите профиль для изменения порта:${NC}\n"
  local i=1
  for profile in "${profiles[@]}"; do
    local transport=$(jq -r '.transport' "$PROFILES_DIR/$profile.json" 2>/dev/null)
    local port=$(jq -r '.port' "$PROFILES_DIR/$profile.json" 2>/dev/null)
    echo -e "${CYAN} $i)${NC} $profile ${BLUE}[$transport:$port]${NC}"
    ((i++))
  done
  echo -e "${CYAN} 0)${NC} Назад в главное меню\n"
  echo -n -e "${YELLOW}Выберите профиль: ${NC}"
  read choice
  if [[ "$choice" == "0" ]]; then
    return
  fi
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#profiles[@]} ]]; then
    echo -e "${RED}✗ Неверный выбор${NC}"
    sleep 2
    return
  fi
  local profile_name="${profiles[$((choice-1))]}"
  local profile_file="$PROFILES_DIR/$profile_name.json"
  local route_index=""
  local route_label=""
  local old_port
  local target_label="$profile_name"
  if profile_has_routes "$profile_file"; then
    select_route_for_profile "$profile_file" "смены порта" || return
    route_index="$SELECTED_ROUTE_INDEX"
    route_label=$(jq -r --argjson i "$route_index" '.routes[$i].label // .routes[$i].transport // ("route-" + ($i|tostring))' "$profile_file")
    old_port=$(jq -r --argjson i "$route_index" '.routes[$i].port // empty' "$profile_file")
    target_label="$profile_name/$route_label"
  else
    old_port=$(jq -r '.port' "$profile_file")
  fi
  echo ""
  echo -e "${CYAN}Текущий порт '${target_label}':${NC} ${GREEN}$old_port${NC}\n"
  echo -e "${YELLOW}Рекомендуемый сценарий для 2026:${NC}\n"
  echo -e "  ${GREEN}1)${NC} Случайный высокий порт 30000-60000 ${MAGENTA}- рекомендуется${NC}"
  echo -e "  ${CYAN}2)${NC} 443   ${YELLOW}- вручную / рискованно для Vision${NC}"
  echo -e "  ${CYAN}3)${NC} 8443  ${BLUE}- явный альтернативный HTTPS-порт${NC}"
  echo -e "  ${CYAN}4)${NC} 2053  ${BLUE}- ручной вариант, иногда удобен для gRPC${NC}"
  echo -e "  ${CYAN}5)${NC} 2083  ${BLUE}- Cloudflare альтернативный SSL${NC}"
  echo -e "  ${CYAN}6)${NC} 2087  ${BLUE}- Cloudflare альтернативный SSL${NC}"
  echo -e "  ${CYAN}7)${NC} 2096  ${BLUE}- Cloudflare альтернативный SSL${NC}"
  echo -e "  ${CYAN}8)${NC} 9443  ${BLUE}- ручной XHTTP-style вариант, не дефолт${NC}"
  echo -e "  ${CYAN}9)${NC} 8080  ${BLUE}- HTTP альтернативный прокси${NC}"
  echo -e "  ${CYAN}10)${NC} Свой порт (введу вручную)\n"
  echo -n -e "${YELLOW}Выберите порт: ${NC}"
  read port_choice
  local new_port=""
  case $port_choice in
    1)
      if ! new_port=$(find_available_random_port); then
        echo -n -e "${YELLOW}Нажмите Enter...${NC}"
        read
        return
      fi
      ;;
    2) new_port="443" ;;
    3) new_port="8443" ;;
    4) new_port="2053" ;;
    5) new_port="2083" ;;
    6) new_port="2087" ;;
    7) new_port="2096" ;;
    8) new_port="9443" ;;
    9) new_port="8080" ;;
    10)
      echo -n -e "${YELLOW}Введите номер порта (1-65535): ${NC}"
      read new_port
      ;;
    0) return ;;
    *) echo -e "${RED}✗ Неверный выбор${NC}"; sleep 2; return ;;
  esac
  if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [[ $new_port -lt 1 ]] || [[ $new_port -gt 65535 ]]; then
    echo -e "${RED}✗ Неверный порт. Используйте число от 1 до 65535${NC}"
    sleep 2
    return
  fi
  if [[ "$new_port" == "$old_port" ]]; then
    echo -e "${YELLOW}⚠ Профиль уже использует этот порт${NC}"
    sleep 2
    return
  fi
  if [[ -n "$route_index" ]] && jq -e --argjson i "$route_index" --argjson port "$new_port" '
    any((.routes // []) | to_entries[]; (.key != $i) and (.value.port == $port))
  ' "$profile_file" >/dev/null 2>&1; then
    echo -e "${RED}✗ Этот порт уже используется другим маршрутом этого же профиля${NC}"
    sleep 2
    return
  fi

  # Get profile transport and UUID
  local profile_transport
  local profile_uuid
  local profile_metadata=""
  local profile_grpc_service_name=""
  local profile_xhttp_path=""

  profile_uuid=$(jq -r '.uuid' "$profile_file")
  if [[ -n "$route_index" ]]; then
    profile_transport=$(jq -r --argjson i "$route_index" '.routes[$i].transport // empty' "$profile_file")
    profile_grpc_service_name=$(jq -r --argjson i "$route_index" '.routes[$i].grpc_service_name // ""' "$profile_file")
    profile_xhttp_path=$(jq -r --argjson i "$route_index" '.routes[$i].xhttp_path // ""' "$profile_file")
  else
    profile_transport=$(jq -r '.transport' "$profile_file")
    profile_metadata=$(read_profile_transport_metadata "$profile_file")
    IFS='|' read -r profile_grpc_service_name profile_xhttp_path <<< "$profile_metadata"
  fi

  if [[ "$new_port" == "443" ]] && [[ "$profile_transport" == "tcp" || "$profile_transport" == "tcp-utls" || "$profile_transport" == "tcp-xudp" ]]; then
    if ! confirm_vision_443_risk; then
      echo -e "${CYAN}✓ Смена порта отменена${NC}"
      sleep 1
      return
    fi
  fi

  # Check if target port is already in use
  local target_inbound_tag=$(jq -r --argjson port "$new_port" '.inbounds[] | select(.port == $port) | .tag' "$CONFIG_FILE" 2>/dev/null)
  local target_inbound_transport=""
  local target_inbound_sni=""
  local target_inbound_metadata=""
  local target_inbound_grpc_service_name=""
  local target_inbound_xhttp_path=""
  local move_to_existing=false

  if [[ -n "$target_inbound_tag" ]]; then
    # Port is in use - check transport compatibility
    target_inbound_transport=$(jq -r --argjson port "$new_port" '.inbounds[] | select(.port == $port) | .streamSettings.network' "$CONFIG_FILE")
    target_inbound_sni=$(jq -r --argjson port "$new_port" '.inbounds[] | select(.port == $port) | .streamSettings.realitySettings.serverNames[0]' "$CONFIG_FILE")
    target_inbound_metadata=$(read_inbound_transport_metadata "$new_port" "$profile_transport")
    IFS='|' read -r target_inbound_grpc_service_name target_inbound_xhttp_path <<< "$target_inbound_metadata"

    # Normalize transport for comparison (tcp-utls, tcp-xudp, tcp-mux use tcp network)
    local profile_network="$profile_transport"
    case "$profile_transport" in
      tcp|tcp-utls|tcp-xudp|tcp-mux) profile_network="tcp" ;;
    esac

    if [[ "$profile_network" != "$target_inbound_transport" ]]; then
      echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
      echo -e "${RED}║            ✗ НЕСОВМЕСТИМЫЙ ТРАНСПОРТ                     ║${NC}"
      echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
      echo ""
      echo -e "${YELLOW}Порт $new_port уже занят профилем с транспортом: ${MAGENTA}$target_inbound_transport${NC}"
      echo -e "${YELLOW}Ваш профиль использует транспорт: ${MAGENTA}$profile_transport${NC}"
      echo ""
      echo -e "${CYAN}Нельзя объединить разные транспорты на одном порту.${NC}"
      echo ""
      echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
      read
      return
    fi

    move_to_existing=true
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║           ПОРТ УЖЕ ИСПОЛЬЗУЕТСЯ                          ║${NC}"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Порт $new_port уже занят профилем с транспортом: ${GREEN}$target_inbound_transport${NC}"
    echo -e "${CYAN}SNI на этом порту: ${GREEN}$target_inbound_sni${NC}"
    echo ""
    echo -e "${MAGENTA}Профиль '$profile_name' будет перемещен на этот порт.${NC}"
    echo -e "${MAGENTA}SNI профиля изменится на: ${YELLOW}$target_inbound_sni${NC}"
    echo ""
  fi

  echo ""
  echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║            ⚠ КРИТИЧЕСКОЕ ПРЕДУПРЕЖДЕНИЕ ⚠               ║${NC}"
  echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${YELLOW}Смена порта изменит настройки подключения.${NC}"
  echo ""
  echo -e "${RED}ВСЕ активные подключения '${target_label}' будут разорваны!${NC}"
  echo ""
  echo -e "${CYAN}После смены необходимо:${NC}"
  echo -e "  ${BLUE}1.${NC} Получить НОВУЮ ссылку/QR-код для этого профиля"
  echo -e "  ${BLUE}2.${NC} Обновить конфигурацию в клиентах"
  echo -e "  ${BLUE}3.${NC} Убедиться, что порт открыт в firewall"
  echo ""
  echo -e "${MAGENTA}Порт изменится: ${YELLOW}$old_port → $new_port${NC}"
  echo ""
  echo -n -e "${YELLOW}Продолжить смену порта? (y/N): ${NC}"
  read confirm
  if [[ ! "$confirm" =~ ^[yYдД]$ ]]; then
    echo -e "${CYAN}✓ Отменено${NC}"
    sleep 1
    return
  fi

  local rollback_config=""
  if ! backup_config "change_port_$profile_name" rollback_config; then
    echo -e "${RED}✗ Не удалось создать бэкап config.json${NC}"
    sleep 2
    return
  fi

  local old_inbound_removed=false

  if [[ "$move_to_existing" == "true" ]]; then
    # Move client to existing inbound on target port
    echo -e "${CYAN}  → Перемещение клиента на порт $new_port...${NC}"

    # Определяем flow по типу транспорта профиля
    local target_flow=""
    case "$profile_transport" in
      tcp|tcp-utls|tcp-xudp) target_flow="xtls-rprx-vision" ;;
      tcp-mux|grpc|xhttp) target_flow="" ;;
    esac

    # Шаг 1: Добавить клиента на новый порт
    if ! safe_jq_write --arg uuid "$profile_uuid" --argjson port "$new_port" --arg flow "$target_flow" '
      (.inbounds[] | select(.port == $port) | .settings.clients) += [{"id": $uuid, "flow": $flow}]
    ' "$CONFIG_FILE"; then
      echo -e "${RED}  ✗ Ошибка добавления клиента на порт $new_port — операция отменена${NC}"
      echo -n -e "${YELLOW}Нажмите Enter...${NC}"; read
      return
    fi

    # Шаг 2: Удалить клиента со старого порта
    if ! safe_jq_write --arg uuid "$profile_uuid" --argjson port "$old_port" '
      (.inbounds[] | select(.port == $port) | .settings.clients) |= map(select(.id != $uuid))
    ' "$CONFIG_FILE"; then
      echo -e "${RED}  ✗ Ошибка удаления клиента с порта $old_port${NC}"
      echo -e "${YELLOW}  → Откат: удаление клиента с нового порта $new_port...${NC}"
      safe_jq_write --arg uuid "$profile_uuid" --argjson port "$new_port" '
        (.inbounds[] | select(.port == $port) | .settings.clients) |= map(select(.id != $uuid))
      ' "$CONFIG_FILE"
      echo -n -e "${YELLOW}Нажмите Enter...${NC}"; read
      return
    fi

    # Шаг 3: Если старый inbound пуст — удалить его
    local old_clients_count=$(jq -r --argjson port "$old_port" '.inbounds[] | select(.port == $port) | .settings.clients | length' "$CONFIG_FILE")
    if [[ "$old_clients_count" == "0" ]]; then
      echo -e "${CYAN}  → Удаление пустого inbound на порту $old_port...${NC}"
      if ! safe_jq_write --argjson port "$old_port" 'del(.inbounds[] | select(.port == $port))' "$CONFIG_FILE"; then
        echo -e "${RED}  ✗ Ошибка удаления пустого inbound на порту $old_port${NC}"
        echo -n -e "${YELLOW}Нажмите Enter...${NC}"; read
        return
      fi
      old_inbound_removed=true
    fi

  else
    # Move entire inbound to new port (original logic)
    if ! safe_jq_write --arg old_tag "inbound-$old_port" --argjson new_port "$new_port" '
      (.inbounds[] | select(.tag == $old_tag) | .port) |= $new_port |
      (.inbounds[] | select(.tag == $old_tag) | .tag) |= ("inbound-" + ($new_port | tostring))
    ' "$CONFIG_FILE"; then
      echo -e "${RED}  ✗ Ошибка смены порта в конфиге — операция отменена${NC}"
      echo -n -e "${YELLOW}Нажмите Enter...${NC}"; read
      return
    fi
  fi

  fix_xray_permissions
  if ! safe_restart_xray "$rollback_config"; then
    echo -e "${RED}✗ Xray не перезапустился — config.json откачен, профили и firewall НЕ изменены${NC}"
    echo -n -e "${YELLOW}Нажмите Enter...${NC}"; read
    return
  fi

  if [[ "$move_to_existing" == "true" ]]; then
    # Шаг 4: Обновить файл профиля/маршрута (port + sni целевого inbound).
    # Fingerprint client-only: сохраняем текущее значение профиля/route.
    local profile_update_ok=true
    if [[ -n "$route_index" ]]; then
      if ! safe_jq_write --argjson i "$route_index" --argjson port "$new_port" --arg sni "$target_inbound_sni" '
        .routes[$i].port = $port |
        .routes[$i].sni = $sni |
        if $i == 0 then .port = $port | .sni = $sni else . end
      ' "$profile_file"; then
        profile_update_ok=false
      fi
      if ! safe_jq_write --argjson i "$route_index" --arg grpc_service_name "$target_inbound_grpc_service_name" --arg xhttp_path "$target_inbound_xhttp_path" '
        if .routes[$i].transport == "grpc" then
          .routes[$i].grpc_service_name = $grpc_service_name |
          if $i == 0 then .grpc_service_name = $grpc_service_name else . end
        elif .routes[$i].transport == "xhttp" then
          .routes[$i].xhttp_path = $xhttp_path |
          if $i == 0 then .xhttp_path = $xhttp_path else . end
        else
          .
        end
      ' "$profile_file"; then
        profile_update_ok=false
      fi
    else
      if ! safe_jq_write --argjson port "$new_port" --arg sni "$target_inbound_sni" \
        '.port = $port | .sni = $sni' "$profile_file"; then
        profile_update_ok=false
      fi
      if ! write_profile_transport_metadata "$profile_file" "$target_inbound_grpc_service_name" "$target_inbound_xhttp_path"; then
        profile_update_ok=false
      fi
    fi

    if [[ "$profile_update_ok" != "true" ]]; then
      echo -e "${RED}✗ Xray уже перезапущен, но profile JSON не удалось синхронизировать${NC}"
      echo -n -e "${YELLOW}Нажмите Enter...${NC}"; read
      return
    fi

    if [[ "$old_inbound_removed" == "true" ]]; then
      close_firewall_port "$old_port"
    fi
  else
    # Обновить ВСЕ профили/маршруты на старом порту (inbound перенесён целиком)
    if ! update_all_profiles_port_reference "$old_port" "$new_port"; then
      echo -e "${RED}✗ Xray уже перезапущен, но profile JSON не удалось синхронизировать${NC}"
      echo -n -e "${YELLOW}Нажмите Enter...${NC}"; read
      return
    fi

    # Update firewall after the new config is live.
    open_firewall_port "$new_port" || \
      echo -e "${YELLOW}  ⚠ Порт $new_port не был открыт через UFW — проверьте firewall вручную${NC}"
    close_firewall_port "$old_port"
  fi

  echo ""
  echo -e "${GREEN}✓ Порт '${target_label}' изменен: ${YELLOW}$old_port → $new_port${NC}"
  echo ""
  echo -e "${MAGENTA}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}║        Теперь ОБЯЗАТЕЛЬНО получите новую ссылку!        ║${NC}"
  echo -e "${MAGENTA}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read
}

manage_profile_advanced_menu() {
  local profile_name="$1"
  local profile_file="$PROFILES_DIR/$profile_name.json"

  if [[ ! -f "$profile_file" ]]; then
    echo -e "${RED}Профиль не найден: $profile_name${NC}"
    sleep 2
    return
  fi

  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}    АДВАНС НАСТРОЙКИ ПРОФИЛЯ (EXPERIMENTAL)   ${NC}"
  echo -e "${BLUE}    Профиль: $profile_name${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  EXPERIMENTAL — VISION SEED                              ║${NC}"
  echo -e "${RED}╠═══════════════════════════════════════════════════════════╣${NC}"
  echo -e "${RED}║  Эти поля (testpre/testseed) появились в Xray-core       ║${NC}"
  echo -e "${RED}║  v1.251201.0 (декабрь 2025). Могут сломать подключения  ║${NC}"
  echo -e "${RED}║  клиентов на старых версиях Xray. Не тестировалось на   ║${NC}"
  echo -e "${RED}║  реальных конфигах.                                     ║${NC}"
  echo -e "${RED}║                                                           ║${NC}"
  echo -e "${RED}║  testpre на серверной стороне parsed-but-not-used:       ║${NC}"
  echo -e "${RED}║  pre-connect логика работает только в outbound клиента.  ║${NC}"
  echo -e "${RED}║  Чтобы testpre дал эффект, клиенту нужно установить      ║${NC}"
  echo -e "${RED}║  то же значение в своем VLESS outbound.                  ║${NC}"
  echo -e "${RED}║  testseed работает на обеих сторонах.                    ║${NC}"
  echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -n -e "${YELLOW}Продолжить? [y/N]: ${NC}"
  local ans
  read -r ans
  [[ "$ans" =~ ^[yYдД]$ ]] || return

  local xray_ver
  xray_ver=$(xray version 2>/dev/null | head -1 | awk '{print $2}')
  if [[ -n "$xray_ver" ]]; then
    local major minor
    major=$(echo "$xray_ver" | cut -d'.' -f1)
    minor=$(echo "$xray_ver" | cut -d'.' -f2)
    if [[ "$major" == "1" && "$minor" =~ ^[0-9]+$ && "$minor" -lt 251201 ]]; then
      echo -e "${YELLOW}Xray-core версия $xray_ver — testpre/testseed появились в v1.251201.0+${NC}"
      echo -e "${YELLOW}  Поля будут добавлены в config, но эффекта не дадут. Рекомендуется sudo xraytailscale update.${NC}"
      echo -n -e "${YELLOW}Продолжить все равно? [y/N]: ${NC}"
      read -r ans
      [[ "$ans" =~ ^[yYдД]$ ]] || return
    fi
  fi

  local cur_pre cur_seed
  cur_pre=$(jq -r '.testpre // "не задано"' "$profile_file" 2>/dev/null)
  cur_seed=$(jq -c '.testseed // []' "$profile_file" 2>/dev/null)
  echo -e "${CYAN}Текущие значения: testpre=${cur_pre}, testseed=${cur_seed}${NC}"
  echo ""

  echo -n -e "${YELLOW}testpre (uint32, 0=off, эффект только на клиенте) [0]: ${NC}"
  local testpre_val
  read -r testpre_val
  testpre_val=${testpre_val:-0}
  if [[ ! "$testpre_val" =~ ^[0-9]+$ ]]; then
    echo -e "${YELLOW}Некорректный testpre — будет использован 0${NC}"
    testpre_val=0
  fi

  echo -n -e "${YELLOW}testseed (uint32 через пробел, пусто=off) []: ${NC}"
  local testseed_input
  read -r testseed_input
  local -a testseed_values=()
  local seed
  for seed in $testseed_input; do
    if [[ "$seed" =~ ^[0-9]+$ ]]; then
      testseed_values+=("$seed")
    else
      echo -e "${RED}✗ Некорректный testseed элемент: $seed${NC}"
      sleep 2
      return
    fi
  done

  local testseed_json="[]"
  if [[ ${#testseed_values[@]} -gt 0 ]]; then
    testseed_json=$(printf '%s\n' "${testseed_values[@]}" | jq -R 'select(length > 0) | tonumber' | jq -s '.')
  fi

  echo ""
  echo -e "${CYAN}Будет применено:${NC}"
  echo -e "  ${YELLOW}testpre${NC} = $testpre_val"
  echo -e "  ${YELLOW}testseed${NC} = $testseed_json"
  echo -n -e "${YELLOW}Применить? [y/N]: ${NC}"
  local confirm
  read -r confirm
  [[ "$confirm" =~ ^[yYдД]$ ]] || { echo -e "${CYAN}✓ Отменено${NC}"; sleep 1; return; }

  local port uuid
  port=$(jq -r '.port' "$profile_file" 2>/dev/null)
  uuid=$(jq -r '.uuid' "$profile_file" 2>/dev/null)
  if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ -z "$uuid" || "$uuid" == "null" ]]; then
    echo -e "${RED}✗ В профиле нет корректного port/uuid${NC}"
    sleep 2
    return
  fi

  local rollback_config="" profiles_snapshot=""
  _snapshot_profiles profiles_snapshot || {
    echo -e "${RED}✗ Не удалось создать снимок profile JSON${NC}"
    sleep 2
    return
  }

  if ! safe_jq_write \
      --argjson testpre "$testpre_val" \
      --argjson testseed "$testseed_json" \
      '. + {testpre: $testpre, testseed: $testseed}' \
      "$profile_file"; then
    _discard_profiles_snapshot "$profiles_snapshot"
    echo -e "${RED}✗ Ошибка записи profile JSON${NC}"
    sleep 2
    return
  fi

  backup_config "vision_seed" rollback_config || {
    _restore_profiles_snapshot "$profiles_snapshot" >/dev/null 2>&1 || true
    sleep 2
    return
  }
  if ! safe_jq_write \
      --argjson port "$port" \
      --arg uuid "$uuid" \
      --argjson testpre "$testpre_val" \
      --argjson testseed "$testseed_json" \
      '(.inbounds[] | select(.port == $port) | .settings.clients[] | select(.id == $uuid)) |= (. + {testpre: $testpre, testseed: $testseed})' \
      "$CONFIG_FILE"; then
    _restore_profiles_snapshot "$profiles_snapshot" >/dev/null 2>&1 || true
    echo -e "${RED}✗ Ошибка записи config.json${NC}"
    sleep 2
    return
  fi

  fix_xray_permissions
  if ! safe_restart_xray "$rollback_config"; then
    _restore_profiles_snapshot "$profiles_snapshot" >/dev/null 2>&1 || true
    echo -e "${RED}✗ Xray не перезапустился — profile JSON восстановлен${NC}"
    sleep 2
    return
  fi
  _discard_profiles_snapshot "$profiles_snapshot"
  echo -e "${GREEN}Vision Seed применен. testpre=${testpre_val}, testseed=${testseed_json}${NC}"
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read -r _
}

