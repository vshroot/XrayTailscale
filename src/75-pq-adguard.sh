# Перевод одного single-route профиля на XHTTP+PQ без интерактивного UI.
# Используется и ручным меню, и автоматической миграцией.
# Возврат: 0 — профиль (и все профили на его порту) обновлён, 1 — ошибка.
_pq_upgrade_one_profile() {
  local name="$1"
  local pfile="$PROFILES_DIR/$name.json"

  if [[ ! -f "$pfile" ]]; then
    echo -e "${RED}✗ Profile not found: $name${NC}"
    return 1
  fi
  if profile_has_routes "$pfile"; then
    echo -e "${RED}✗ Multi-route profile '$name' cannot be converted wholesale via the PQ upgrade${NC}"
    return 1
  fi
  if _profile_is_bulk_seed_file "$pfile"; then
    echo -e "${RED}✗ Service bulk-seed profile '$name' skipped${NC}"
    return 1
  fi
  if [[ "$(jq -r '.pq_enabled // false' "$pfile" 2>/dev/null)" == "true" ]]; then
    echo -e "${CYAN}  → Profile '$name' already uses PQ${NC}"
    return 0
  fi

  # Бэкап нужен до любой мутации config.json; точный путь используется для отката.
  local rollback_config=""
  if ! backup_config "upgrade_profile_pq_$name" rollback_config; then
    echo -e "${RED}✗ Could not back up before the PQ upgrade of profile '$name'${NC}"
    return 1
  fi

  local port uuid
  port=$(jq -r '.port // empty' "$pfile" 2>/dev/null)
  uuid=$(jq -r '.uuid // empty' "$pfile" 2>/dev/null)
  if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ -z "$uuid" || "$uuid" == "null" ]]; then
    echo -e "${RED}✗ Profile '$name' has no valid port/uuid${NC}"
    return 1
  fi

  # UUID выбранного клиента сопоставляем с текущим inbound; SNI и short_id берём
  # только из config.json, чтобы не разойтись с фактическими Reality-настройками.
  local current_inbound
  current_inbound=$(jq -c --argjson p "$port" --arg uuid "$uuid" '
    first(.inbounds[]?
      | select(.port == $p)
      | select(any(.settings.clients[]?; (.id // "") == $uuid)))
  ' "$CONFIG_FILE" 2>/dev/null)
  if [[ -z "$current_inbound" || "$current_inbound" == "null" ]]; then
    echo -e "${RED}✗ Current inbound of profile '$name' not found on port $port${NC}"
    return 1
  fi

  local sni short_id
  sni=$(jq -r '.streamSettings.realitySettings.serverNames[0] // empty' <<< "$current_inbound")
  short_id=$(jq -r '.streamSettings.realitySettings.shortIds[0] // empty' <<< "$current_inbound")
  if [[ -z "$sni" ]]; then
    echo -e "${RED}✗ The inbound on port $port has no Reality SNI${NC}"
    return 1
  fi
  if [[ -z "$short_id" ]]; then
    # Fallback для повреждённого legacy inbound без shortIds.
    short_id=$(openssl rand -hex 8)
  fi

  local VLESS_DECRYPTION
  VLESS_DECRYPTION=$(cat "$VLESS_DECRYPTION_FILE" 2>/dev/null)
  if [[ -z "$VLESS_DECRYPTION" ]]; then
    echo -e "${RED}✗ $VLESS_DECRYPTION_FILE is empty or missing — upgrade aborted${NC}"
    return 1
  fi

  local xhttp_path="/$(openssl rand -hex 8)"
  local PRIVATE_KEY
  PRIVATE_KEY=$(cat "$PRIVATE_KEY_FILE" 2>/dev/null)
  if [[ -z "$PRIVATE_KEY" ]]; then
    echo -e "${RED}✗ Reality private key is empty or missing: $PRIVATE_KEY_FILE${NC}"
    return 1
  fi

  local profiles_on_port=($(get_profiles_on_port "$port"))
  if [[ ${#profiles_on_port[@]} -eq 0 ]]; then
    profiles_on_port=("$name")
  fi

  # REPLACE inbound с port=$port на XHTTP+PQ с сохранёнными UUID, портом и SNI.
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

  # На общем inbound сохраняем UUID всех профилей этого порта.
  if [[ ${#profiles_on_port[@]} -gt 1 ]]; then
    local clients_json="["
    local first=1
    local p pu
    for p in "${profiles_on_port[@]}"; do
      pu=$(jq -r '.uuid // empty' "$PROFILES_DIR/$p.json" 2>/dev/null)
      if [[ -z "$pu" ]]; then
        echo -e "${RED}✗ Could not obtain the UUID of profile '$p' on port $port${NC}"
        return 1
      fi
      if [[ $first -eq 1 ]]; then first=0; else clients_json+=","; fi
      clients_json+="{\"id\":\"$pu\",\"flow\":\"\"}"
    done
    clients_json+="]"
    new_inbound=$(jq --argjson c "$clients_json" '.settings.clients = $c' <<< "$new_inbound")
    if [[ -z "$new_inbound" ]]; then
      echo -e "${RED}✗ Could not build the client list for port $port${NC}"
      return 1
    fi
  fi

  # Атомарная замена: удаление по порту + append нового inbound.
  if ! safe_jq_write --argjson port "$port" --argjson new_in "$new_inbound" \
    '(.inbounds |= map(select(.port != $port))) | .inbounds += [$new_in]' \
    "$CONFIG_FILE"; then
    echo -e "${RED}✗ Error updating config.json for profile '$name'${NC}"
    _restore_config_backup "$rollback_config" >/dev/null 2>&1 || true
    return 1
  fi

  # Сначала применяем config.json, затем синхронизируем profile JSON.
  fix_xray_permissions
  if ! safe_restart_xray "$rollback_config"; then
    echo -e "${RED}✗ safe_restart_xray failed — config rolled back to backup upgrade_profile_pq_$name${NC}"
    echo -e "${YELLOW}  Profile JSON unchanged — profile state preserved.${NC}"
    _restore_config_backup "$rollback_config" >/dev/null 2>&1 || true
    return 1
  fi

  # short_id остаётся только в config.json — единственном источнике истины.
  local profile_failed=0
  local p
  for p in "${profiles_on_port[@]}"; do
    if ! safe_jq_write --arg path "$xhttp_path" \
      '.transport = "xhttp" | .schema_version = 2 | .pq_enabled = true | .xhttp_path = $path' \
      "$PROFILES_DIR/$p.json"; then
      echo -e "${RED}  ✗ Error updating profile JSON: $p${NC}"
      ((profile_failed += 1))
    else
      echo -e "${CYAN}  → Updated: ${YELLOW}$p${NC}"
    fi
  done

  if [[ $profile_failed -gt 0 ]]; then
    echo -e "${RED}✗ PQ upgrade '$name': config.json applied, but $profile_failed profile JSON need a re-migration${NC}"
    return 1
  fi

  echo -e "${GREEN}✓ Profile '$name' successfully switched to XHTTP+PQ${NC}"
  return 0
}

upgrade_profile_to_pq_menu() {
  # === Phase 1a: UI / VALIDATION ===
  # Цель: собрать и провалидировать все входные данные ДО любых мутаций.
  # Если оператор прерывает (Ctrl+C / выбор 0 / "n" в подтверждении) — НИЧЕГО не изменено.
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}   UPGRADE PROFILE TO POST-QUANTUM         ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}\n"

  # Pre-check: ключи vlessenc должны существовать (Plan 6.1 marker .mlkem_keys_generated)
  if [[ ! -f "$VLESS_DECRYPTION_FILE" ]] || [[ ! -f "$VLESS_ENCRYPTION_FILE" ]]; then
    echo -e "${RED}✗ ML-KEM keys not found ($VLESS_DECRYPTION_FILE).${NC}"
    echo -e "${YELLOW}  Run xraytailscale update — the .mlkem_keys_generated migration should generate the keys.${NC}"
    echo -n -e "${YELLOW}Press Enter to return...${NC}"; read
    return
  fi

  # Список ВСЕХ профилей с пометкой PQ-статуса
  local profiles=($(_list_visible_profile_names))
  if [[ ${#profiles[@]} -eq 0 ]]; then
    echo -e "${RED}✗ No profiles created${NC}"
    echo -n -e "${YELLOW}Press Enter to continue...${NC}"; read
    return
  fi

  echo -e "${YELLOW}Choose a profile to switch to post-quantum:${NC}\n"
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
        echo -e "${CYAN} —)${NC} $profile ${BLUE}[multi-route: ${route_count} routes]${NC} ${GREEN}[PQ route already present]${NC}"
      else
        echo -e "${CYAN} —)${NC} $profile ${BLUE}[multi-route: ${route_count} routes]${NC} ${YELLOW}[upgrade is done per-route manually]${NC}"
      fi
      continue
    fi

    local pq=$(jq -r '.pq_enabled // false' "$pfile" 2>/dev/null)
    if [[ "$pq" == "true" ]]; then
      echo -e "${CYAN} —)${NC} $profile ${BLUE}[port:$port,$transport]${NC} ${GREEN}[already PQ]${NC}"
    else
      echo -e "${CYAN} $i)${NC} $profile ${BLUE}[port:$port,$transport]${NC} ${YELLOW}[legacy]${NC}"
      upgradeable+=("$profile")
      ((i++))
    fi
  done
  echo -e "${CYAN} 0)${NC} Back\n"

  if [[ ${#upgradeable[@]} -eq 0 ]]; then
    echo -e "${GREEN}✓ No single-route legacy profiles for in-place PQ upgrade.${NC}"
    echo -e "${CYAN}Multi-route profiles already contain separate legacy/PQ routes.${NC}"
    echo -n -e "${YELLOW}Press Enter to return...${NC}"; read
    return
  fi

  echo -n -e "${YELLOW}Choose a profile (1-${#upgradeable[@]}, 0 — back): ${NC}"
  read choice
  if [[ "$choice" == "0" ]]; then return; fi
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#upgradeable[@]} ]]; then
    echo -e "${RED}✗ Invalid choice${NC}"; sleep 2; return
  fi

  local selected="${upgradeable[$((choice-1))]}"
  local pfile="$PROFILES_DIR/$selected.json"
  if profile_has_routes "$pfile"; then
    echo -e "${RED}✗ A multi-route profile is not converted wholesale via this menu.${NC}"
    echo -e "${YELLOW}  It already has separate legacy/PQ routes. Use a raw route or create a separate legacy/PQ profile.${NC}"
    sleep 3
    return
  fi
  local port=$(jq -r '.port' "$pfile")
  local uuid=$(jq -r '.uuid' "$pfile")
  local sni
  sni=$(jq -r --argjson p "$port" \
    '.inbounds[] | select(.port == $p) | .streamSettings.realitySettings.serverNames[0] // "www.ozon.ru"' \
    "$CONFIG_FILE" 2>/dev/null)
  local old_transport=$(jq -r '.transport // "tcp"' "$pfile")

  # CRITICAL: проверка shared inbound — если на порту другие профили, ВСЕ они уйдут в PQ
  local profiles_on_port=($(get_profiles_on_port "$port"))
  echo ""
  echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║                  ⚠ WARNING                                  ║${NC}"
  echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${YELLOW}Profile: ${MAGENTA}$selected${NC} ${BLUE}(port $port, transport $old_transport → xhttp+pq)${NC}"
  echo ""
  echo -e "${YELLOW}After the upgrade:${NC}"
  echo -e "  ${RED}• The old vless:// link STOPS WORKING immediately${NC}"
  echo -e "  ${RED}• All clients connected to this profile lose connectivity${NC}"
  echo -e "  ${RED}• They must be re-imported with the new vless:// (or create a separate legacy profile via 'Create profile')${NC}"
  echo -e "  ${YELLOW}• Affected clients (only these support PQ): HAPP 2.10+, v2rayNG 1.10+, v2rayN (PR #7782), Shadowrocket${NC}"
  echo -e "  ${YELLOW}• NOT compatible: sing-box, mihomo, NekoBox, Hiddify — they need a separate legacy profile${NC}"
  echo -e "  ${GREEN}• UUID preserved: $uuid${NC}"
  echo -e "  ${GREEN}• Port preserved: $port${NC}"
  echo -e "  ${GREEN}• SNI preserved (read from the existing inbound): $sni${NC}"
  echo ""
  if [[ ${#profiles_on_port[@]} -gt 1 ]]; then
    echo -e "${RED}⚠ Port $port hosts a SHARED inbound — the operation is MASS and IRREVERSIBLE:${NC}"
    echo -e "  ${RED}• ALL profiles listed below will be switched to XHTTP+PQ${NC}"
    echo -e "  ${RED}• TCP+Vision profiles on this port lose flow=xtls-rprx-vision${NC}"
    echo -e "  ${RED}• Transport is forcibly changed tcp/grpc → xhttp in the profile JSON${NC}"
    echo -e "  ${RED}• Each of these profiles needs its client re-imported with the NEW vless:// link${NC}"
    echo -e "  ${RED}• The way back (XHTTP+PQ → TCP+Vision) is ONLY via manual profile recreation${NC}"
    echo ""
    echo -e "${YELLOW}Affected profiles on port $port:${NC}"
    for p in "${profiles_on_port[@]}"; do
      echo -e "  ${CYAN}•${NC} $p"
    done
    echo ""
  fi
  echo -n -e "${YELLOW}Confirm the upgrade (y/N): ${NC}"
  read confirm
  if [[ ! "$confirm" =~ ^[yYдД]$ ]]; then
    echo -e "${YELLOW}Upgrade cancelled.${NC}"; sleep 2; return
  fi

  # === Phase 1b/1c: общая мутация config.json и profile JSON ===
  echo -e "${CYAN}→ Switching the profile to XHTTP+PQ${NC}"
  if ! _pq_upgrade_one_profile "$selected"; then
    echo -e "${RED}✗ PQ upgrade of profile '$selected' did not finish${NC}"
    echo -n -e "${YELLOW}Press Enter to return to the menu...${NC}"
    read -r _ || true
    return
  fi

  echo ""
  echo -e "${CYAN}New vless:// link:${NC}"
  generate_connection "$selected"
  echo ""
  echo -n -e "${YELLOW}Press Enter to return to the menu...${NC}"
  read
}

# ═══════════════════════════════════════════════════════════
# ADGUARD HOME
# ═══════════════════════════════════════════════════════════

# Удаление AdGuard Home
uninstall_adguard_home() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}        REMOVE ADGUARD HOME                 ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""

  # Шаг 1: Проверка — установлен?
  if [[ ! -f /opt/AdGuardHome/AdGuardHome ]]; then
    echo -e "${YELLOW}⚠ AdGuard Home is not installed${NC}"
    echo ""
    echo -n -e "${YELLOW}Press Enter to continue...${NC}"
    read
    return
  fi

  # Шаг 2: Подтверждение
  echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║            ⚠ REMOVE ADGUARD HOME ⚠                   ║${NC}"
  echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${YELLOW}Will be removed:${NC}"
  echo -e "  ${CYAN}•${NC} AdGuard Home and all its settings"
  echo -e "  ${CYAN}•${NC} Filters and statistics"
  echo -e "  ${CYAN}•${NC} Integration with Xray DNS"
  echo ""
  echo -e "${CYAN}Xray DNS will be restored to Local DoH (1.1.1.1).${NC}"
  echo ""
  echo -n -e "${RED}Are you sure? (y/N): ${NC}"
  read confirm
  if [[ ! "$confirm" =~ ^[yYдД]$ ]]; then
    echo -e "${CYAN}✓ Cancelled${NC}"
    sleep 1
    return
  fi

  echo ""

  local rollback_config=""

  # Шаг 3: Остановка службы
  echo -e "${CYAN}Step 1/6: Stopping AdGuard Home...${NC}"
  systemctl stop AdGuardHome 2>/dev/null || true
  systemctl disable AdGuardHome 2>/dev/null || true
  echo -e "${GREEN}  ✓ Service stopped${NC}"

  # Шаг 4: Удаление
  echo -e "${CYAN}Step 2/6: Removing files...${NC}"
  /opt/AdGuardHome/AdGuardHome -s uninstall 2>/dev/null || true
  rm -rf /opt/AdGuardHome/
  echo -e "${GREEN}  ✓ AdGuard Home removed${NC}"

  # Шаг 5: Восстановление Xray DNS
  echo -e "${CYAN}Step 3/6: Restoring Xray DNS...${NC}"
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
      echo -e "${RED}  ✗ Error restoring Xray DNS${NC}"
    fi
  fi

  # Шаг 6: Восстановление systemd-resolved
  echo -e "${CYAN}Step 4/6: Restoring systemd-resolved...${NC}"
  if [[ -f /etc/systemd/resolved.conf.d/adguardhome.conf ]]; then
    rm -f /etc/systemd/resolved.conf.d/adguardhome.conf
    # Восстанавливаем resolv.conf на стандартный stub
    if [[ -L /etc/resolv.conf ]] || [[ -f /etc/resolv.conf ]]; then
      ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
    fi
    systemctl restart systemd-resolved 2>/dev/null || true
    echo -e "${GREEN}  ✓ systemd-resolved restored${NC}"
  else
    echo -e "${GREEN}  ✓ systemd-resolved was not changed${NC}"
  fi

  # Закрытие портов
  echo -e "${CYAN}Step 5/6: Closing ports...${NC}"
  if command -v ufw &>/dev/null; then
    ufw delete allow 53/tcp >/dev/null 2>&1
    ufw delete allow 53/udp >/dev/null 2>&1
    ufw delete allow 3000/tcp >/dev/null 2>&1  # На случай если открывали вручную
    ufw reload >/dev/null 2>&1
  fi
  echo -e "${GREEN}  ✓ Ports checked${NC}"

  # Перезапуск Xray
  echo -e "${CYAN}Step 6/6: Restarting Xray...${NC}"
  safe_restart_xray "$rollback_config"

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║         ✓ ADGUARD HOME REMOVED SUCCESSFULLY                   ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${CYAN}Xray DNS restored to Local DoH (1.1.1.1).${NC}"
  echo ""
  echo -n -e "${YELLOW}Press Enter to continue...${NC}"
  read
}

