upgrade_profile_to_pq_menu() {
  # === Phase 1a: UI / VALIDATION ===
  # Цель: собрать и провалидировать все входные данные ДО любых мутаций.
  # Если оператор прерывает (Ctrl+C / выбор 0 / "n" в подтверждении) — НИЧЕГО не изменено.
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}   ОБНОВЛЕНИЕ ПРОФИЛЯ ДО POST-QUANTUM         ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}\n"

  # Pre-check: ключи vlessenc должны существовать (Plan 6.1 marker .mlkem_keys_generated)
  if [[ ! -f "$VLESS_DECRYPTION_FILE" ]] || [[ ! -f "$VLESS_ENCRYPTION_FILE" ]]; then
    echo -e "${RED}✗ ML-KEM ключи не найдены ($VLESS_DECRYPTION_FILE).${NC}"
    echo -e "${YELLOW}  Запустите xraytailscale update — миграция .mlkem_keys_generated должна сгенерировать ключи.${NC}"
    echo -n -e "${YELLOW}Нажмите Enter для возврата...${NC}"; read
    return
  fi

  # Список ВСЕХ профилей с пометкой PQ-статуса
  local profiles=($(_list_visible_profile_names))
  if [[ ${#profiles[@]} -eq 0 ]]; then
    echo -e "${RED}✗ Нет созданных профилей${NC}"
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"; read
    return
  fi

  echo -e "${YELLOW}Выберите профиль для перевода на post-quantum:${NC}\n"
  local i=1
  local upgradeable=()
  for profile in "${profiles[@]}"; do
    local pfile="$PROFILES_DIR/$profile.json"
    local transport=$(jq -r '.transport // "tcp"' "$pfile" 2>/dev/null)
    local port=$(jq -r '.port // "-"' "$pfile" 2>/dev/null)
    if profile_has_routes "$pfile"; then
      local route_count
      route_count=$(_profile_route_count "$pfile")
      if _profile_has_pq_route "$pfile"; then
        echo -e "${CYAN} —)${NC} $profile ${BLUE}[multi-route: ${route_count} routes]${NC} ${GREEN}[PQ route уже есть]${NC}"
      else
        echo -e "${CYAN} —)${NC} $profile ${BLUE}[multi-route: ${route_count} routes]${NC} ${YELLOW}[апгрейд делается по маршрутам вручную]${NC}"
      fi
      continue
    fi

    local pq=$(jq -r '.pq_enabled // false' "$pfile" 2>/dev/null)
    if [[ "$pq" == "true" ]]; then
      echo -e "${CYAN} —)${NC} $profile ${BLUE}[порт:$port,$transport]${NC} ${GREEN}[уже PQ]${NC}"
    else
      echo -e "${CYAN} $i)${NC} $profile ${BLUE}[порт:$port,$transport]${NC} ${YELLOW}[legacy]${NC}"
      upgradeable+=("$profile")
      ((i++))
    fi
  done
  echo -e "${CYAN} 0)${NC} Назад\n"

  if [[ ${#upgradeable[@]} -eq 0 ]]; then
    echo -e "${GREEN}✓ Нет single-route legacy профилей для in-place PQ upgrade.${NC}"
    echo -e "${CYAN}Multi-route профили уже содержат отдельные legacy/PQ маршруты.${NC}"
    echo -n -e "${YELLOW}Нажмите Enter для возврата...${NC}"; read
    return
  fi

  echo -n -e "${YELLOW}Выберите профиль (1-${#upgradeable[@]}, 0 — назад): ${NC}"
  read choice
  if [[ "$choice" == "0" ]]; then return; fi
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#upgradeable[@]} ]]; then
    echo -e "${RED}✗ Неверный выбор${NC}"; sleep 2; return
  fi

  local selected="${upgradeable[$((choice-1))]}"
  local pfile="$PROFILES_DIR/$selected.json"
  if profile_has_routes "$pfile"; then
    echo -e "${RED}✗ Multi-route профиль не переводится целиком через это меню.${NC}"
    echo -e "${YELLOW}  В нем уже есть отдельные legacy/PQ маршруты. Используйте raw route или создайте отдельный legacy/PQ профиль.${NC}"
    sleep 3
    return
  fi
  local port=$(jq -r '.port' "$pfile")
  local uuid=$(jq -r '.uuid' "$pfile")
  local sni=$(jq -r '.sni // "www.ozon.ru"' "$pfile")
  local fingerprint=$(jq -r --arg default_fp "$DEFAULT_CLIENT_FINGERPRINT" '.fingerprint // $default_fp' "$pfile")
  local old_transport=$(jq -r '.transport // "tcp"' "$pfile")

  # H1 fix: short_id ЧИТАЕМ ИЗ СУЩЕСТВУЮЩЕГО INBOUND (config.json), НЕ из profile JSON.
  # create_profile() в xraytailscale НИКОГДА не сохраняет short_id в profile JSON.
  # Если на shared inbound сгенерировать новый short_id — Reality порвёт ВСЕ остальные клиенты на порту.
  # Зеркалим логику generate_connection() (xraytailscale:2217-2220): берём первый shortIds[0] из инбаунда.
  local short_id
  short_id=$(jq -r --argjson p "$port" \
    '.inbounds[] | select(.port == $p) | .streamSettings.realitySettings.shortIds[0]' \
    "$CONFIG_FILE" 2>/dev/null)
  if [[ -z "$short_id" || "$short_id" == "null" ]]; then
    # Inbound не содержит shortIds (corrupted/legacy без Reality?) — генерируем как last resort.
    # На shared inbound этот fallback ОБЫЧНО НЕ срабатывает: install.sh всегда пишет shortIds.
    short_id=$(openssl rand -hex 8)
  fi

  # CRITICAL: проверка shared inbound — если на порту другие профили, ВСЕ они уйдут в PQ
  local profiles_on_port=($(get_profiles_on_port "$port"))
  echo ""
  echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║                  ⚠ ВНИМАНИЕ                                  ║${NC}"
  echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${YELLOW}Профиль: ${MAGENTA}$selected${NC} ${BLUE}(порт $port, транспорт $old_transport → xhttp+pq)${NC}"
  echo ""
  echo -e "${YELLOW}После апгрейда:${NC}"
  echo -e "  ${RED}• Старая vless:// ссылка ПЕРЕСТАНЕТ РАБОТАТЬ немедленно${NC}"
  echo -e "  ${RED}• Все клиенты, подключённые к этому профилю, потеряют связь${NC}"
  echo -e "  ${RED}• Их нужно переимпортировать с новой vless:// (или создать отдельный legacy-профиль через 'Создать профиль')${NC}"
  echo -e "  ${YELLOW}• Затронутые клиенты (только эти умеют PQ): HAPP 2.10+, v2rayNG 1.10+, v2rayN (PR #7782), Shadowrocket${NC}"
  echo -e "  ${YELLOW}• НЕ совместимые: sing-box, mihomo, NekoBox, Hiddify — для них нужен отдельный legacy профиль${NC}"
  echo -e "  ${GREEN}• UUID сохраняется: $uuid${NC}"
  echo -e "  ${GREEN}• Порт сохраняется: $port${NC}"
  echo -e "  ${GREEN}• SNI сохраняется (читается из существующего инбаунда): $sni${NC}"
  echo ""
  if [[ ${#profiles_on_port[@]} -gt 1 ]]; then
    echo -e "${RED}⚠ На порту $port размещён ОБЩИЙ inbound — операция МАССОВАЯ и НЕОБРАТИМАЯ:${NC}"
    echo -e "  ${RED}• ВСЕ перечисленные ниже профили будут переведены на XHTTP+PQ${NC}"
    echo -e "  ${RED}• TCP+Vision профили на этом порту потеряют flow=xtls-rprx-vision${NC}"
    echo -e "  ${RED}• Транспорт принудительно меняется tcp/grpc → xhttp в profile JSON${NC}"
    echo -e "  ${RED}• Каждому из этих профилей нужно переимпортировать клиента с НОВОЙ vless:// ссылкой${NC}"
    echo -e "  ${RED}• Путь обратно (XHTTP+PQ → TCP+Vision) ТОЛЬКО через ручное пересоздание профиля${NC}"
    echo ""
    echo -e "${YELLOW}Затронутые профили на порту $port:${NC}"
    for p in "${profiles_on_port[@]}"; do
      echo -e "  ${CYAN}•${NC} $p"
    done
    echo ""
  fi
  echo -n -e "${YELLOW}Подтвердите апгрейд (y/N): ${NC}"
  read confirm
  if [[ ! "$confirm" =~ ^[yYдД]$ ]]; then
    echo -e "${YELLOW}Апгрейд отменён.${NC}"; sleep 2; return
  fi

  # === Phase 1b: MUTATION ===
  # Цель: атомарно заменить inbound на XHTTP+PQ + рестартнуть Xray.
  # Все мутации защищены backup + safe_jq_write + safe_restart_xray (auto-rollback).
  # Если safe_restart_xray fails — config откачен, Xray работает на старой конфигурации,
  # profile JSON ещё НЕ менялся (Phase 1c не достигнута) — состояние согласовано.
  echo -e "${CYAN}→ Phase 1b: бэкап и замена inbound в config.json${NC}"

  # Шаг A: бэкап (на случай ошибки)
  local rollback_config=""
  backup_config "upgrade_profile_pq_$selected" rollback_config || return

  # Шаг B: читаем содержимое decryption ОДИН раз
  local VLESS_DECRYPTION
  VLESS_DECRYPTION=$(cat "$VLESS_DECRYPTION_FILE")
  if [[ -z "$VLESS_DECRYPTION" ]]; then
    echo -e "${RED}✗ $VLESS_DECRYPTION_FILE пуст — апгрейд прерван${NC}"; sleep 2; return
  fi

  # Шаг C: сгенерировать XHTTP path (как делает add_inbound) — простой случайный
  local xhttp_path="/$(openssl rand -hex 8)"
  local PRIVATE_KEY=$(cat "$PRIVATE_KEY_FILE")

  # Шаг D: REPLACE inbound с port=$port на новый XHTTP+pq shape (с СОХРАНЁННЫМ uuid)
  # Стратегия: del-by-port + append (НЕ object merge — иначе clobber freedom outbound и т.п.)
  local new_inbound
  new_inbound=$(cat << UPGEOF
{
  "listen": "0.0.0.0",
  "port": $port,
  "protocol": "vless",
  "settings": {
    "clients": [{"id": "$uuid", "flow": ""}],
    "decryption": "$VLESS_DECRYPTION"
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
UPGEOF
)

  # ВАЖНО: если на порту были другие профили, их UUID должны быть в clients[]. Собираем их.
  if [[ ${#profiles_on_port[@]} -gt 1 ]]; then
    # Собрать массив clients из всех profile JSON на этом порту
    local clients_json="["
    local first=1
    for p in "${profiles_on_port[@]}"; do
      local pu=$(jq -r '.uuid' "$PROFILES_DIR/$p.json")
      if [[ $first -eq 1 ]]; then first=0; else clients_json+=","; fi
      clients_json+="{\"id\":\"$pu\",\"flow\":\"\"}"
    done
    clients_json+="]"
    # Подменить settings.clients в new_inbound через jq
    new_inbound=$(echo "$new_inbound" | jq --argjson c "$clients_json" '.settings.clients = $c')
  fi

  # Шаг E: атомарная замена — del-by-port + append
  if ! safe_jq_write --argjson port "$port" --argjson new_in "$new_inbound" \
    '(.inbounds |= map(select(.port != $port))) | .inbounds += [$new_in]' \
    "$CONFIG_FILE"; then
    echo -e "${RED}✗ Ошибка обновления config.json${NC}"; sleep 2; return
  fi

  # Шаг F: восстановить permissions и рестарт с auto-rollback ДО profile JSON.
  fix_xray_permissions
  if ! safe_restart_xray "$rollback_config"; then
    echo -e "${RED}✗ safe_restart_xray failed — config откачен на бэкап upgrade_profile_pq_$selected${NC}"
    echo -e "${YELLOW}  Profile JSON не менялся — состояние профилей сохранено.${NC}"
    sleep 3; return
  fi

  # === Phase 1c: POST-MUTATION ===
  # Цель: синхронизировать profile JSON со state'ом config.json + показать новую ссылку.
  # Достигается ТОЛЬКО если Phase 1b прошла полностью (config.json обновлён + Xray рестартнул).
  # Если safe_jq_write на profile JSON фейлится — config.json уже на новом inbound, оператор
  # увидит ошибку и сможет исправить profile JSON вручную (jq + safe_jq_write helper).
  echo -e "${CYAN}→ Phase 1c: синхронизация profile JSON и вывод новой vless:// ссылки${NC}"

  # Шаг F: обновить profile JSON (selected И всех на порту, если shared)
  # H1 fix: НЕ записываем short_id в profile JSON. Schema v1 не имела этого поля,
  # schema v2 НЕ должна вводить новое поле без явного решения. short_id живёт в
  # config.json:.inbounds[].streamSettings.realitySettings.shortIds[0] — один источник истины.
  for p in "${profiles_on_port[@]}"; do
    if ! safe_jq_write --arg path "$xhttp_path" \
      '.transport = "xhttp" | .schema_version = 2 | .pq_enabled = true | .xhttp_path = $path' \
      "$PROFILES_DIR/$p.json"; then
      echo -e "${RED}  ✗ Ошибка обновления profile JSON: $p${NC}"
    else
      echo -e "${CYAN}  → Обновлен: ${YELLOW}$p${NC}"
    fi
  done

  echo ""
  echo -e "${GREEN}✓ Профиль '$selected' успешно переведён на XHTTP+PQ${NC}"
  echo -e "${CYAN}Новая vless:// ссылка:${NC}"
  generate_connection "$selected"
  echo ""
  echo -n -e "${YELLOW}Нажмите Enter для возврата в меню...${NC}"
  read
}

# ═══════════════════════════════════════════════════════════
# ADGUARD HOME
# ═══════════════════════════════════════════════════════════

# Удаление AdGuard Home
uninstall_adguard_home() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}        УДАЛЕНИЕ ADGUARD HOME                 ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""

  # Шаг 1: Проверка — установлен?
  if [[ ! -f /opt/AdGuardHome/AdGuardHome ]]; then
    echo -e "${YELLOW}⚠ AdGuard Home не установлен${NC}"
    echo ""
    echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
    read
    return
  fi

  # Шаг 2: Подтверждение
  echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║            ⚠ УДАЛЕНИЕ ADGUARD HOME ⚠                   ║${NC}"
  echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${YELLOW}Будут удалены:${NC}"
  echo -e "  ${CYAN}•${NC} AdGuard Home и все его настройки"
  echo -e "  ${CYAN}•${NC} Фильтры и статистика"
  echo -e "  ${CYAN}•${NC} Интеграция с Xray DNS"
  echo ""
  echo -e "${CYAN}Xray DNS будет восстановлен на DoH Local (1.1.1.1).${NC}"
  echo ""
  echo -n -e "${RED}Вы уверены? (y/N): ${NC}"
  read confirm
  if [[ ! "$confirm" =~ ^[yYдД]$ ]]; then
    echo -e "${CYAN}✓ Отменено${NC}"
    sleep 1
    return
  fi

  echo ""

  local rollback_config=""

  # Шаг 3: Остановка службы
  echo -e "${CYAN}Шаг 1/6: Остановка AdGuard Home...${NC}"
  systemctl stop AdGuardHome 2>/dev/null || true
  systemctl disable AdGuardHome 2>/dev/null || true
  echo -e "${GREEN}  ✓ Служба остановлена${NC}"

  # Шаг 4: Удаление
  echo -e "${CYAN}Шаг 2/6: Удаление файлов...${NC}"
  /opt/AdGuardHome/AdGuardHome -s uninstall 2>/dev/null || true
  rm -rf /opt/AdGuardHome/
  echo -e "${GREEN}  ✓ AdGuard Home удалён${NC}"

  # Шаг 5: Восстановление Xray DNS
  echo -e "${CYAN}Шаг 3/6: Восстановление Xray DNS...${NC}"
  if [[ -f "$CONFIG_FILE" ]]; then
    backup_config "adguard_dns_restore" rollback_config || true
    if safe_jq_write '.dns = {
      "servers": [
        "https+local://1.1.1.1/dns-query",
        "localhost"
      ],
      "queryStrategy": "UseIPv4",
      "disableCache": false
    }' "$CONFIG_FILE"; then
      echo -e "${GREEN}  ✓ Xray DNS → DoH Local${NC}"
    else
      echo -e "${RED}  ✗ Ошибка восстановления Xray DNS${NC}"
    fi
  fi

  # Шаг 6: Восстановление systemd-resolved
  echo -e "${CYAN}Шаг 4/6: Восстановление systemd-resolved...${NC}"
  if [[ -f /etc/systemd/resolved.conf.d/adguardhome.conf ]]; then
    rm -f /etc/systemd/resolved.conf.d/adguardhome.conf
    # Восстанавливаем resolv.conf на стандартный stub
    if [[ -L /etc/resolv.conf ]] || [[ -f /etc/resolv.conf ]]; then
      ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
    fi
    systemctl restart systemd-resolved 2>/dev/null || true
    echo -e "${GREEN}  ✓ systemd-resolved восстановлен${NC}"
  else
    echo -e "${GREEN}  ✓ systemd-resolved не был изменён${NC}"
  fi

  # Закрытие портов
  echo -e "${CYAN}Шаг 5/6: Закрытие портов...${NC}"
  if command -v ufw &>/dev/null; then
    ufw delete allow 53/tcp >/dev/null 2>&1
    ufw delete allow 53/udp >/dev/null 2>&1
    ufw delete allow 3000/tcp >/dev/null 2>&1  # На случай если открывали вручную
    ufw reload >/dev/null 2>&1
  fi
  echo -e "${GREEN}  ✓ Порты проверены${NC}"

  # Перезапуск Xray
  echo -e "${CYAN}Шаг 6/6: Перезапуск Xray...${NC}"
  safe_restart_xray "$rollback_config"

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║         ✓ ADGUARD HOME УСПЕШНО УДАЛЁН                   ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${CYAN}Xray DNS восстановлен на DoH Local (1.1.1.1).${NC}"
  echo ""
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read
}

