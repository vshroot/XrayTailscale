update_transport_settings_for_sni() {
  local port=$1
  local new_sni=$2
  local config_file=$3

  # Convert port to number for jq
  local port_num=$((port))

  # Detect transport type
  local transport=$(jq -r --argjson port "$port_num" \
    '.inbounds[] | select(.port == $port) | .streamSettings.network' \
    "$config_file")

  echo -e "${CYAN}  → Обновление SNI на порту $port (транспорт: $transport)...${NC}"

  # Base updates (ALL transports) - search by port number, not tag
  if ! safe_jq_write --argjson port "$port_num" --arg sni "$new_sni" '
    (.inbounds[] | select(.port == $port) | .streamSettings.realitySettings.dest) |= ($sni + ":443") |
    (.inbounds[] | select(.port == $port) | .streamSettings.realitySettings.serverNames) |= [$sni]
  ' "$config_file"; then
    echo -e "${RED}  ✗ Ошибка обновления SNI${NC}"
    return 1
  fi
  echo -e "${GREEN}  ✓ Reality SNI обновлен → $new_sni${NC}"

  if [[ "$transport" == "xhttp" ]]; then
    safe_jq_write --argjson port "$port_num" '
      (.inbounds[] | select(.port == $port) | .streamSettings.xhttpSettings) |= del(.host)
    ' "$config_file" >/dev/null 2>&1 || true
    echo -e "${GREEN}  ✓ XHTTP Host header не форсируется${NC}"
  fi
}

find_profile_file_by_uuid() {
  local uuid=$1
  local profile_file

  for profile_file in "$PROFILES_DIR"/*.json; do
    [[ ! -f "$profile_file" ]] && continue
    if [[ "$(jq -r '.uuid // ""' "$profile_file" 2>/dev/null)" == "$uuid" ]]; then
      echo "$profile_file"
      return 0
    fi
  done

  return 1
}

_profile_is_bulk_seed_file() {
  local profile_file="$1"
  jq -e '.bulk_seed == true' "$profile_file" >/dev/null 2>&1
}

_list_visible_profile_names() {
  local profile_file profile_name
  for profile_file in "$PROFILES_DIR"/*.json; do
    [[ -f "$profile_file" ]] || continue
    _profile_is_bulk_seed_file "$profile_file" && continue
    profile_name=$(basename "$profile_file" .json)
    echo "$profile_name"
  done | sort
}

find_available_random_port() {
  local min_port=30000
  local max_port=60000
  local attempts=0
  local port

  while [[ $attempts -lt 200 ]]; do
    port=$((min_port + ((RANDOM << 15 | RANDOM) % (max_port - min_port + 1))))
    # Проверяем и конфиг Xray, и реально слушающие порты
    if ! jq -e --argjson port "$port" '.inbounds[] | select(.port == $port)' \
      "$CONFIG_FILE" >/dev/null 2>&1 && \
      ! ss -tuln 2>/dev/null | grep -q ":${port} "; then
      echo "$port"
      return 0
    fi
    ((attempts++))
  done

  echo -e "${RED}✗ Не удалось подобрать свободный случайный порт 30000-60000${NC}" >&2
  return 1
}

generate_transport_token() {
  local prefix=$1
  local bytes=${2:-4}
  echo "${prefix}-$(openssl rand -hex "$bytes")"
}

build_transport_defaults() {
  local transport=$1
  local port
  local grpc_service_name=""
  local xhttp_path=""

  if ! port=$(find_available_random_port); then
    return 1
  fi

  case "$transport" in
    grpc)
      grpc_service_name=$(generate_transport_token "grpc")
      ;;
    xhttp)
      xhttp_path="/$(generate_transport_token "xhttp")"
      ;;
  esac

  printf '%s|%s|%s\n' "$port" "$grpc_service_name" "$xhttp_path"
}

read_inbound_transport_metadata() {
  local port=$1
  local transport=$2
  local grpc_service_name=""
  local xhttp_path=""

  case "$transport" in
    grpc)
      grpc_service_name=$(jq -r --argjson port "$port" \
        '.inbounds[] | select(.port == $port) | .streamSettings.grpcSettings.serviceName // "grpc"' \
        "$CONFIG_FILE" 2>/dev/null)
      [[ -z "$grpc_service_name" || "$grpc_service_name" == "null" ]] && grpc_service_name="grpc"
      ;;
    xhttp)
      xhttp_path=$(jq -r --argjson port "$port" \
        '.inbounds[] | select(.port == $port) | .streamSettings.xhttpSettings.path // "/xhttp"' \
        "$CONFIG_FILE" 2>/dev/null)
      [[ -z "$xhttp_path" || "$xhttp_path" == "null" ]] && xhttp_path="/xhttp"
      ;;
  esac

  printf '%s|%s\n' "$grpc_service_name" "$xhttp_path"
}

read_profile_transport_metadata() {
  local profile_file=$1
  local transport
  local grpc_service_name=""
  local xhttp_path=""

  transport=$(jq -r '.transport // "tcp"' "$profile_file" 2>/dev/null)

  case "$transport" in
    grpc)
      grpc_service_name=$(jq -r '.grpc_service_name // "grpc"' "$profile_file" 2>/dev/null)
      [[ -z "$grpc_service_name" || "$grpc_service_name" == "null" ]] && grpc_service_name="grpc"
      ;;
    xhttp)
      xhttp_path=$(jq -r '.xhttp_path // "/xhttp"' "$profile_file" 2>/dev/null)
      [[ -z "$xhttp_path" || "$xhttp_path" == "null" ]] && xhttp_path="/xhttp"
      ;;
  esac

  printf '%s|%s\n' "$grpc_service_name" "$xhttp_path"
}

# ═══════════════════════════════════════════════════════════
# Pure VLESS URL builder (Phase 7, REQ-C10)
# ═══════════════════════════════════════════════════════════
# НЕ печатает цветной TUI, НЕ читает stdin, НЕ пишет файлы, НЕ зовёт qrencode.
# stdout: ровно одна vless:// строка (без trailing newline) на success.
# return: 0 на успех; 1 если profile_file не существует / транспорт неизвестен /
#         PQ-профиль без $VLESS_ENCRYPTION_FILE.
# Args: $1 = absolute path к profile JSON.
# Используется generate_connection() в интерактиве и subhttp.sh в Plan 7.2.
_route_expected_network() {
  case "$1" in
    tcp|tcp-utls|tcp-xudp|tcp-mux) echo "tcp" ;;
    grpc) echo "grpc" ;;
    xhttp) echo "xhttp" ;;
    *) return 1 ;;
  esac
}

_route_expected_flow() {
  case "$1" in
    tcp|tcp-utls|tcp-xudp) echo "xtls-rprx-vision" ;;
    tcp-mux|grpc|xhttp) echo "" ;;
    *) return 1 ;;
  esac
}

_live_route_metadata_for_client() {
  local uuid="$1"
  local transport="$2"
  local port="$3"
  [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ && "$port" =~ ^[0-9]+$ ]] || return 1

  local expected_network expected_flow
  expected_network=$(_route_expected_network "$transport") || return 1
  expected_flow=$(_route_expected_flow "$transport") || return 1

  jq -er \
    --argjson p "$port" \
    --arg uuid "$uuid" \
    --arg network "$expected_network" \
    --arg flow "$expected_flow" \
    --arg transport "$transport" '
      first(
        .inbounds[]? as $in
        | select($in.port == $p)
        | select(($in.streamSettings.network // "") == $network)
        | select(if $transport == "xhttp" then (($in.streamSettings.xhttpSettings.path // "") | startswith("/")) else true end)
        | select(any($in.settings.clients[]?; (.id // "") == $uuid and ((.flow // "") == $flow)))
        | [
            ($in.streamSettings.realitySettings.serverNames[0] // ""),
            (if $transport == "grpc" then ($in.streamSettings.grpcSettings.serviceName // "") else "" end),
            (if $transport == "xhttp" then ($in.streamSettings.xhttpSettings.path // "") else "" end),
            ($in.settings.decryption // "none")
          ]
      ) // empty
      | join("|")
    ' "$CONFIG_FILE" 2>/dev/null
}

_profile_route_live_metadata() {
  local profile_file="$1"
  local route_index="${2:-}"
  [[ -f "$profile_file" ]] || return 1

  local uuid transport port
  uuid=$(jq -r '.uuid // ""' "$profile_file") || return 1
  if [[ -n "$route_index" ]]; then
    transport=$(jq -r --argjson i "$route_index" '.routes[$i].transport // empty' "$profile_file") || return 1
    port=$(jq -r --argjson i "$route_index" '.routes[$i].port // empty' "$profile_file") || return 1
  else
    transport=$(jq -r '.transport // empty' "$profile_file") || return 1
    port=$(jq -r '.port // empty' "$profile_file") || return 1
  fi

  _live_route_metadata_for_client "$uuid" "$transport" "$port"
}

_generate_vless_url_pure() {
  local profile_file="$1"
  local route_index="${2:-}"
  [[ -f "$profile_file" ]] || return 1

  local profile_name uuid transport port fingerprint sni
  profile_name=$(basename "$profile_file" .json)
  uuid=$(jq -r '.uuid' "$profile_file") || return 1
  if [[ -z "$route_index" ]] && jq -e '(.routes // []) | length > 0' "$profile_file" >/dev/null 2>&1; then
    route_index=0
  fi

  local route_label=""
  if [[ -n "$route_index" ]]; then
    transport=$(jq -r --argjson i "$route_index" '.routes[$i].transport // empty' "$profile_file") || return 1
    port=$(jq -r --argjson i "$route_index" '.routes[$i].port // empty' "$profile_file") || return 1
    fingerprint=$(jq -r --argjson i "$route_index" --arg default_fp "$DEFAULT_CLIENT_FINGERPRINT" '.routes[$i].fingerprint // .fingerprint // $default_fp' "$profile_file")
    sni=$(jq -r --argjson i "$route_index" '.routes[$i].sni // .sni // "www.ozon.ru"' "$profile_file")
    route_label=$(jq -r --argjson i "$route_index" '.routes[$i].label // .routes[$i].transport // empty' "$profile_file")
  else
    transport=$(jq -r '.transport' "$profile_file") || return 1
    port=$(jq -r '.port' "$profile_file") || return 1
    fingerprint=$(jq -r --arg default_fp "$DEFAULT_CLIENT_FINGERPRINT" '.fingerprint // $default_fp' "$profile_file")
    sni=$(jq -r '.sni // "www.ozon.ru"' "$profile_file")
  fi
  [[ -n "$route_label" && "$route_label" != "null" ]] && profile_name="${profile_name}-${route_label}"

  local server_ip clean_public_key
  # Per-profile server_address (self-steal: клиент подключается по собственному
  # домену — адрес/SNI/сертификат совпадают). Пусто = глобальная логика адреса.
  local profile_server_addr
  profile_server_addr=$(jq -r '.server_address // ""' "$profile_file" 2>/dev/null)
  if [[ -n "$profile_server_addr" && "$profile_server_addr" != "null" ]]; then
    server_ip="$profile_server_addr"
  else
    server_ip=$(_connection_server_address)
  fi
  [[ -n "$server_ip" ]] || return 1
  clean_public_key=$(cat "$PUBLIC_KEY_FILE" 2>/dev/null) || return 1

  # Transport metadata (grpc service name / xhttp path) и url-encoded path
  local transport_metadata grpc_service_name xhttp_path encoded_xhttp_path
  if [[ -n "$route_index" ]]; then
    grpc_service_name=$(jq -r --argjson i "$route_index" '.routes[$i].grpc_service_name // ""' "$profile_file")
    xhttp_path=$(jq -r --argjson i "$route_index" '.routes[$i].xhttp_path // "/xhttp"' "$profile_file")
  else
    transport_metadata=$(read_profile_transport_metadata "$profile_file")
    IFS='|' read -r grpc_service_name xhttp_path <<< "$transport_metadata"
  fi
  encoded_xhttp_path=$(jq -nr --arg path "$xhttp_path" '$path|@uri')

  # Live-config guard: route usable only when the inbound has this profile UUID with
  # the expected flow. Server-side metadata repairs SNI/path/decryption, but client
  # TLS fingerprint stays profile-owned and is emitted only in URLs/subscriptions.
  local live_metadata live_sni live_grpc_service_name live_xhttp_path live_decryption
  live_metadata=$(_live_route_metadata_for_client "$uuid" "$transport" "$port") || return 1
  IFS='|' read -r live_sni live_grpc_service_name live_xhttp_path live_decryption <<< "$live_metadata"
  [[ -n "$live_sni" && "$live_sni" != "null" ]] && sni="$live_sni"
  case "$transport" in
    grpc)
      [[ -n "$live_grpc_service_name" && "$live_grpc_service_name" != "null" ]] && grpc_service_name="$live_grpc_service_name"
      ;;
    xhttp)
      [[ "$live_xhttp_path" == "null" ]] && live_xhttp_path=""
      xhttp_path="$live_xhttp_path"
      encoded_xhttp_path=$(jq -nr --arg path "$xhttp_path" '$path|@uri')
      ;;
  esac

  # short_id — читаем из config.json по порту (зеркало логики generate_connection)
  local short_id
  short_id=$(jq -r --argjson p "$port" \
    '.inbounds[] | select(.port == $p) | .streamSettings.realitySettings.shortIds[0]' \
    "$CONFIG_FILE" 2>/dev/null)
  [[ -z "$short_id" || "$short_id" == "null" ]] && short_id=""

  case "$transport" in
    tcp|tcp-utls|tcp-xudp)
      printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
        "$uuid" "$server_ip" "$port" "$sni" "$fingerprint" "$clean_public_key" "$short_id" "$profile_name"
      ;;
    tcp-mux)
      printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
        "$uuid" "$server_ip" "$port" "$sni" "$fingerprint" "$clean_public_key" "$short_id" "$profile_name"
      ;;
    grpc)
      printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=grpc&serviceName=%s&mode=gun#%s' \
        "$uuid" "$server_ip" "$port" "$sni" "$fingerprint" "$clean_public_key" "$short_id" "$grpc_service_name" "$profile_name"
      ;;
    xhttp)
      local pq_enabled
      if [[ -n "$route_index" ]]; then
        pq_enabled=$(jq -r --argjson i "$route_index" '.routes[$i].pq_enabled // false' "$profile_file" 2>/dev/null)
      else
        pq_enabled=$(jq -r '.pq_enabled // false' "$profile_file" 2>/dev/null)
      fi
      if [[ -n "$live_decryption" && "$live_decryption" != "none" && "$live_decryption" != "null" ]]; then
        pq_enabled=true
      else
        pq_enabled=false
      fi
      if [[ "$pq_enabled" == "true" ]]; then
        [[ -f "$VLESS_ENCRYPTION_FILE" ]] || return 1
        local raw_encryption encoded_encryption
        raw_encryption=$(cat "$VLESS_ENCRYPTION_FILE")
        encoded_encryption=$(jq -nr --arg enc "$raw_encryption" '$enc|@uri')
        printf 'vless://%s@%s:%s?encryption=%s&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=xhttp&path=%s&mode=stream-one#%s' \
          "$uuid" "$server_ip" "$port" "$encoded_encryption" "$sni" "$fingerprint" "$clean_public_key" "$short_id" "$encoded_xhttp_path" "$profile_name"
      else
        printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=xhttp&path=%s&mode=stream-one#%s' \
          "$uuid" "$server_ip" "$port" "$sni" "$fingerprint" "$clean_public_key" "$short_id" "$encoded_xhttp_path" "$profile_name"
      fi
      ;;
    *)
      return 1
      ;;
  esac

  return 0
}

_profile_route_count() {
  local profile_file="$1"
  jq -r '(.routes // []) | length' "$profile_file" 2>/dev/null || echo 0
}

_generate_vless_urls_for_profile() {
  local profile_file="$1"
  [[ -f "$profile_file" ]] || return 1

  local old_addr_override="${XRAYTAILSCALE_SERVER_ADDR_OVERRIDE-}"
  local had_addr_override=0
  if [[ -n "${XRAYTAILSCALE_SERVER_ADDR_OVERRIDE+x}" ]]; then
    had_addr_override=1
  fi
  if [[ -z "${XRAYTAILSCALE_SERVER_ADDR_OVERRIDE:-}" ]]; then
    local resolved_addr
    resolved_addr=$(_connection_server_address) || return 1
    [[ -n "$resolved_addr" ]] || return 1
    XRAYTAILSCALE_SERVER_ADDR_OVERRIDE="$resolved_addr"
  fi

  local route_count
  route_count=$(_profile_route_count "$profile_file")
  local emitted=0
  if [[ "$route_count" =~ ^[0-9]+$ ]] && [[ "$route_count" -gt 0 ]]; then
    local i url
    for ((i=0; i<route_count; i++)); do
      if url=$(_generate_vless_url_pure "$profile_file" "$i"); then
        printf '%s\n' "$url"
        emitted=1
      fi
    done
  else
    local url
    if url=$(_generate_vless_url_pure "$profile_file"); then
      printf '%s\n' "$url"
      emitted=1
    fi
  fi

  if [[ "$had_addr_override" -eq 1 ]]; then
    XRAYTAILSCALE_SERVER_ADDR_OVERRIDE="$old_addr_override"
  else
    unset XRAYTAILSCALE_SERVER_ADDR_OVERRIDE
  fi

  [[ "$emitted" -eq 1 ]] || return 1
}

_profile_has_pq_route() {
  local profile_file="$1"
  jq -e '(.pq_enabled == true) or any((.routes // [])[]; .pq_enabled == true)' "$profile_file" >/dev/null 2>&1
}

_profile_live_route_count() {
  local profile_file="$1"
  [[ -f "$profile_file" ]] || { echo 0; return 1; }

  local route_count
  route_count=$(_profile_route_count "$profile_file")
  if [[ "$route_count" =~ ^[0-9]+$ ]] && [[ "$route_count" -gt 0 ]]; then
    local live=0
    local i
    for ((i=0; i<route_count; i++)); do
      if _profile_route_live_metadata "$profile_file" "$i" >/dev/null 2>&1; then
        ((live++))
      fi
    done
    echo "$live"
    [[ "$live" -gt 0 ]]
    return
  fi

  if _profile_route_live_metadata "$profile_file" >/dev/null 2>&1; then
    echo 1
    return 0
  fi

  echo 0
  return 1
}

# ═══════════════════════════════════════════════════════════
# Subscription base URL builder (Phase 7, Plan 7.2 / REQ-C03)
# ═══════════════════════════════════════════════════════════
# Читает /usr/local/etc/xray/.subscription_domain и .subscription_port (создаются Plan 7.3
# после установки публичного TLS). Возвращает на stdout канонично-сформированный base URL
# (без trailing slash, без /sub/<token>). Контракт:
#   - "http://127.0.0.1:8080"   — если domain == "127.0.0.1" (local-only fallback);
#   - "https://<domain>"        — если port == "443" (без явного указания порта в URL);
#   - "https://<domain>:<port>" — иначе (public TLS на 8443 и пр.).
# return: 0 всегда (даже при отсутствии маркеров — отдаёт default http://127.0.0.1:8080).
# Единственный источник истины для Plan 7.3 (manage_subscription_menu / create_profile
# success-screen / happ_subscription_menu status-line) и для subhttp.sh self-test.
_subscription_base_url() {
  local domain port
  domain=$(cat /usr/local/etc/xray/.subscription_domain 2>/dev/null || echo "127.0.0.1")
  port=$(cat /usr/local/etc/xray/.subscription_port 2>/dev/null || echo "8080")
  local host="$domain"
  if [[ "$host" == *:* && "$host" != \[* ]]; then
    host="[$host]"
  fi
  if [[ "$domain" == "127.0.0.1" ]]; then
    echo "http://${host}:${port}"
  elif [[ "$port" == "443" ]]; then
    echo "https://${host}"
  else
    echo "https://${host}:${port}"
  fi
  return 0
}

_subscription_is_local_only() {
  local domain port
  domain=$(cat /usr/local/etc/xray/.subscription_domain 2>/dev/null || echo "127.0.0.1")
  port=$(cat /usr/local/etc/xray/.subscription_port 2>/dev/null || echo "8080")
  [[ "$domain" == "127.0.0.1" || "$domain" == "localhost" || "$port" == "8080" ]]
}

_connection_server_address() {
  if [[ -n "${XRAYTAILSCALE_SERVER_ADDR_OVERRIDE:-}" ]]; then
    echo "$XRAYTAILSCALE_SERVER_ADDR_OVERRIDE"
    return 0
  fi

  if [[ -n "${SERVER_IP:-}" ]]; then
    echo "$SERVER_IP"
    return 0
  fi

  local saved_addr mode domain
  saved_addr=$(cat /usr/local/etc/xray/.subscription_server_addr 2>/dev/null || true)
  if [[ -n "$saved_addr" && "$saved_addr" != "127.0.0.1" && "$saved_addr" != "localhost" ]]; then
    echo "$saved_addr"
    return 0
  fi

  mode=$(cat /usr/local/etc/xray/.subscription_mode 2>/dev/null || true)
  domain=$(cat /usr/local/etc/xray/.subscription_domain 2>/dev/null || true)
  if [[ "$mode" == "ip_tls" && "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$domain"
    return 0
  fi

  get_server_ip
}

_certbot_supports_ip_address() {
  local certbot_bin="${1:-certbot}"
  "$certbot_bin" --help all 2>/dev/null | grep -q -- '--ip-address'
}

_ensure_certbot_ip_tls() {
  CERTBOT_IP_BIN=""

  local candidate
  for candidate in /snap/bin/certbot "$(command -v certbot 2>/dev/null || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if _certbot_supports_ip_address "$candidate"; then
      CERTBOT_IP_BIN="$candidate"
      return 0
    fi
  done

  echo -e "${YELLOW}  → Системный certbot не поддерживает IP certificates; ставлю актуальный certbot через snap...${NC}"
  if ! apt-get install -y snapd >/dev/null 2>&1; then
    echo -e "${RED}✗ Не удалось установить snapd для Certbot 5.4+${NC}"
    return 1
  fi

  systemctl enable --now snapd.socket >/dev/null 2>&1 || true
  export PATH="/snap/bin:$PATH"

  if command -v snap >/dev/null 2>&1; then
    if snap list core >/dev/null 2>&1; then
      snap refresh core >/tmp/snap-core.log 2>&1 || true
    elif ! snap install core >/tmp/snap-core.log 2>&1; then
      echo -e "${RED}✗ snap install core не удался. Лог: /tmp/snap-core.log${NC}"
      tail -20 /tmp/snap-core.log
      return 1
    fi

    if snap list certbot >/dev/null 2>&1; then
      snap refresh certbot >/tmp/snap-certbot.log 2>&1 || true
    elif ! snap install --classic certbot >/tmp/snap-certbot.log 2>&1; then
      echo -e "${RED}✗ snap install certbot не удался. Лог: /tmp/snap-certbot.log${NC}"
      tail -20 /tmp/snap-certbot.log
      return 1
    fi
  else
    echo -e "${RED}✗ snap command не найден после установки snapd${NC}"
    return 1
  fi

  for candidate in /snap/bin/certbot "$(command -v certbot 2>/dev/null || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if _certbot_supports_ip_address "$candidate"; then
      CERTBOT_IP_BIN="$candidate"
      return 0
    fi
  done

  echo -e "${RED}✗ Не найден Certbot 5.4+ с поддержкой --ip-address${NC}"
  return 1
}

write_profile_transport_metadata() {
  local profile_file=$1
  local grpc_service_name=$2
  local xhttp_path=$3

  if ! safe_jq_write --arg grpc_service_name "$grpc_service_name" --arg xhttp_path "$xhttp_path" '
    if .transport == "grpc" then
      .grpc_service_name = ($grpc_service_name | select(length > 0))
    elif .transport == "xhttp" then
      .xhttp_path = ($xhttp_path | select(length > 0))
    else
      .
    end
  ' "$profile_file"; then
    return 1
  fi

  return 0
}

confirm_vision_443_risk() {
  echo ""
  echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║         ⚠ VISION НА 443 — РУЧНОЙ РИСКОВЫЙ РЕЖИМ         ║${NC}"
  echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo -e "${YELLOW}В 2026 году ТСПУ часто режет Vision на 443, особенно на мобильных сетях.${NC}"
  echo -e "${YELLOW}Используйте 443 только осознанно, если случайный высокий порт/XHTTP не подходят.${NC}"
  echo -n -e "${YELLOW}Продолжить несмотря на риск? (y/N): ${NC}"
  read confirm
  [[ "$confirm" =~ ^[yYдД]$ ]]
}

# Безопасная запись через jq — проверяет результат перед перезаписью
# Использование: safe_jq_write "выражение_jq" [аргументы_jq...] "$входной_файл" "$выходной_файл"
# Или для записи в тот же файл: safe_jq_write "выражение_jq" [аргументы_jq...] "$файл"
# Последний аргумент — целевой файл (куда записать), предпоследний — исходный
# Если целевой == исходный, делает mktemp+mv
