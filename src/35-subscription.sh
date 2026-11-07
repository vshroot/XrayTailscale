_cleanup_legacy_subscription_artifacts() {
  local legacy_base="xrayeba""tor"
  local legacy_unit="${legacy_base}-sub.service"
  local legacy_site="${legacy_base}-sub"

  systemctl disable --now "$legacy_unit" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${legacy_unit}" 2>/dev/null || true
  rm -f "/etc/nginx/sites-enabled/${legacy_site}" "/etc/nginx/sites-available/${legacy_site}" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
}

install_subscription_server() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}     УСТАНОВКА HAPP SUBSCRIPTION SERVER       ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""

  if ! ensure_xray_runtime_user; then
    return 1
  fi
  chmod 755 /usr/local/bin/xraytailscale 2>/dev/null || true
  _cleanup_legacy_subscription_artifacts

  # Pre-flight: socat (handler bind), openssl/base64/jq уже гарантированы install.sh.
  if ! command -v socat &>/dev/null; then
    echo -e "${CYAN}  → Установка socat...${NC}"
    if ! apt-get install -y socat >/dev/null 2>&1; then
      echo -e "${RED}✗ Не удалось установить socat${NC}"
      echo -e "${YELLOW}Установите вручную: apt-get install -y socat${NC}"
      return 1
    fi
    echo -e "${GREEN}  ✓ socat установлен${NC}"
  fi

  # ── (1) subhttp.sh ────────────────────────────────────────
  # Heredoc маркер single-quoted — $-переменные внутри handler-а
  # НЕ интерполируются на момент генерации (это критично: $path/$token/$HAPP_*
  # должны раскрываться в runtime handler-а, не на этапе записи файла).
  cat > /usr/local/bin/subhttp.sh << 'SUBHTTP_EOF'
#!/bin/bash
# xraytailscale subhttp.sh — HAPP subscription handler (heredoc-generated from xraytailscale).
# socat fork-ит этот скрипт на каждый TCP-connect: stdin = HTTP request, stdout = HTTP response.
# REQ-C05 (strict regex), REQ-C06 (constant-time 404), REQ-C07 (HAPP metadata symmetry headers↔body).

set +u

emit_500() {
  local msg="${1:-Subscription handler error}"
  local body="XrayTailscale subscription handler error: ${msg}
"
  printf 'HTTP/1.1 500 Internal Server Error\r\n'
  printf 'content-type: text/plain; charset=utf-8\r\n'
  printf 'content-length: %s\r\n' "${#body}"
  printf 'connection: close\r\n'
  printf 'cache-control: no-store\r\n'
  printf '\r\n'
  printf '%s' "$body"
  exit 0
}

# Source xraytailscale для доступа к _generate_vless_url_pure() + констант (CONFIG_FILE,
# PROFILES_DIR, PUBLIC_KEY_FILE, VLESS_ENCRYPTION_FILE). Source-safety guard (Plan 7.1
# REQ-C10) гарантирует, что main_menu НЕ запустится при source.
if [[ ! -r /usr/local/bin/xraytailscale ]] || ! source /usr/local/bin/xraytailscale; then
  emit_500 "cannot source /usr/local/bin/xraytailscale"
fi

# Source HAPP defaults — на КАЖДЫЙ request (REQ-C13 prerequisite: Plan 7.3 TUI редактирование
# применяется без рестарта сервиса).
HAPP_DEFAULTS=/usr/local/etc/xray/.happ_defaults.env
if [[ -f "$HAPP_DEFAULTS" ]] && ! source "$HAPP_DEFAULTS"; then
  emit_500 "invalid HAPP defaults file"
fi

# Fallback-defaults если .happ_defaults.env отсутствует или не задаёт переменную.
HAPP_PROFILE_UPDATE_INTERVAL="${HAPP_PROFILE_UPDATE_INTERVAL:-24}"
HAPP_SERVER_NAME="${HAPP_SERVER_NAME:-}"
HAPP_SUPPORT_URL="${HAPP_SUPPORT_URL:-https://github.com/vshroot/XrayTailscale}"
HAPP_WEB_URL="${HAPP_WEB_URL:-https://github.com/vshroot/XrayTailscale}"
HAPP_ANNOUNCE_FILE="${HAPP_ANNOUNCE_FILE:-/usr/local/etc/xray/announce.txt}"
HAPP_ROUTING_JSON_FILE="${HAPP_ROUTING_JSON_FILE:-/usr/local/etc/xray/.happ_routing.json}"

# Parse HTTP request line: "GET /sub/<32hex> HTTP/1.1\r"
read -r request_line || true
method=$(printf '%s' "$request_line" | awk '{print $1}')
request_target=$(printf '%s' "$request_line" | awk '{print $2}')
path="${request_target%%\?*}"
query=""
if [[ "$request_target" == *\?* ]]; then
  query="${request_target#*\?}"
fi

# Drain remaining headers — нужны только чтобы socat не блокировал client.
# User-Agent нужен для совместимости: v2rayNG/v2rayN ждут обычный v2ray subscription,
# HAPP ждёт HAPP metadata + happ://routing.
user_agent=""
while IFS= read -r header_line; do
  header_line="${header_line%$'\r'}"
  [[ -z "$header_line" ]] && break
  case "$header_line" in
    [Uu][Ss][Ee][Rr]-[Aa][Gg][Ee][Nn][Tt]:*)
      user_agent="${header_line#*:}"
      user_agent="${user_agent#"${user_agent%%[![:space:]]*}"}"
      ;;
  esac
done

# Constant-time 404 (REQ-C06): идентичные body+headers, ВСЕГДА sleep 0.1 ПЕРЕД ответом.
# Защищает от token enumeration через timing side-channel.
emit_404() {
  sleep 0.1
  printf 'HTTP/1.1 404 Not Found\r\n'
  printf 'content-type: text/plain; charset=utf-8\r\n'
  printf 'content-length: 10\r\n'
  printf 'connection: close\r\n'
  printf '\r\n'
  printf 'Not Found\n'
  exit 0
}

emit_410_stale() {
  sleep 0.1
  printf 'HTTP/1.1 410 Gone\r\n'
  printf 'content-type: text/plain; charset=utf-8\r\n'
  printf 'content-length: 39\r\n'
  printf 'connection: close\r\n'
  printf 'cache-control: no-store\r\n'
  printf '\r\n'
  printf 'Profile has no live Xray inbound ports\n'
  exit 0
}

# Method check: только GET. Любой другой — 404 (НЕ 405: не раскрываем существование endpoint).
[[ "$method" == "GET" ]] || emit_404

# Strict regex (REQ-C05): /sub/<32-hex>. Любой иной path — 404.
if ! [[ "$path" =~ ^/sub/[a-f0-9]{32}$ ]]; then
  emit_404
fi

token="${path#/sub/}"

# Найти profile JSON с .sub_token == $token.
profile_file=""
for pf in "$PROFILES_DIR"/*.json; do
  [[ -f "$pf" ]] || continue
  if [[ "$(jq -r '.sub_token // ""' "$pf" 2>/dev/null)" == "$token" ]]; then
    profile_file="$pf"
    break
  fi
done

# Token не найден — constant-time 404 (защита от enumeration через timing).
[[ -n "$profile_file" ]] || emit_404

profile_name=$(basename "$profile_file" .json)
short_token="${token:0:8}"

# Построить все vless:// маршруты профиля через pure-функции из xraytailscale.
vless_urls=$(_generate_vless_urls_for_profile "$profile_file" 2>/dev/null) || emit_410_stale

query_lc=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')
ua_lc=$(printf '%s' "$user_agent" | tr '[:upper:]' '[:lower:]')
universal_sub=false
if [[ "$query_lc" == *"format=v2ray"* || "$query_lc" == *"format=base64"* || "$query_lc" == *"client=v2rayng"* || "$ua_lc" == *"v2rayng"* || "$ua_lc" == *"v2rayn"* ]]; then
  universal_sub=true
fi

prepare_happ_vless_urls() {
  local input line has_legacy_xhttp=false
  local -a tcp_vision=() tcp_xudp=() tcp_utls=() grpc_routes=() tcp_mux=() xhttp_legacy=() other=()
  input=$(cat)

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == vless://* && "$line" == *"encryption=none"* && "$line" == *"&type=xhttp&"* ]]; then
      has_legacy_xhttp=true
      break
    fi
  done <<< "$input"

  append_mode_param() {
    local uri="$1" param="$2"
    if [[ "$uri" == *"#"* ]]; then
      printf '%s&%s#%s' "${uri%%#*}" "$param" "${uri#*#}"
    else
      printf '%s&%s' "$uri" "$param"
    fi
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == vless://* && "$line" == *"&type=xhttp&"* && "$has_legacy_xhttp" == "true" && "$line" != *"encryption=none"* ]]; then
      continue
    fi
    if [[ "$line" == vless://* && "$line" == *"&type=xhttp&"* && "$line" != *"&mode="* ]]; then
      line=$(append_mode_param "$line" "mode=auto")
    elif [[ "$line" == vless://* && "$line" == *"&type=grpc&"* && "$line" != *"&mode="* ]]; then
      line=$(append_mode_param "$line" "mode=gun")
    fi

    case "$line" in
      *#*-tcp-vision) tcp_vision+=("$line") ;;
      *#*-tcp-xudp) tcp_xudp+=("$line") ;;
      *#*-tcp-utls-firefox) tcp_utls+=("$line") ;;
      *#*-grpc) grpc_routes+=("$line") ;;
      *#*-tcp-mux) tcp_mux+=("$line") ;;
      *#*-xhttp-legacy) xhttp_legacy+=("$line") ;;
      *) other+=("$line") ;;
    esac
  done <<< "$input"

  for line in \
    "${tcp_vision[@]}" \
    "${tcp_xudp[@]}" \
    "${tcp_utls[@]}" \
    "${grpc_routes[@]}" \
    "${tcp_mux[@]}" \
    "${xhttp_legacy[@]}" \
    "${other[@]}"; do
    printf '%s\n' "$line"
  done
}

# HAPP metadata: profile-title и announce — base64 UTF-8 без переносов (-w0).
subscription_title="${HAPP_SERVER_NAME:-}"
if [[ -z "$subscription_title" ]]; then
  subscription_title="$profile_name"
fi
profile_title_b64=$(printf '%s' "$subscription_title" | base64 -w0)
ANNOUNCE_FILE="$HAPP_ANNOUNCE_FILE"
ANNOUNCE_HEADER=""
ANNOUNCE_COMMENT=""
if [[ -s "$ANNOUNCE_FILE" ]]; then
  _ann_text=$(head -c 200 "$ANNOUNCE_FILE" | tr -d '\n\r')
  if [[ -n "$_ann_text" ]]; then
    _ann_b64=$(printf '%s' "$_ann_text" | base64 -w0)
    ANNOUNCE_HEADER="announce: base64:${_ann_b64}"
    ANNOUNCE_COMMENT="#announce: base64:${_ann_b64}"
  fi
fi

# HAPP routing import payload: только явный opt-in.
# Важно: это маршрутизация приложения HAPP, а не список XrayTailscale connection routes.
# Пустой fallback rules:[] опасен — он может перезаписать/активировать пустой routing
# profile в клиенте. Поэтому по умолчанию отдаём только VLESS-ноды.
routing_uri=""
if [[ -s "$HAPP_ROUTING_JSON_FILE" ]] && jq -e . "$HAPP_ROUTING_JSON_FILE" >/dev/null 2>&1; then
  routing_json=$(cat "$HAPP_ROUTING_JSON_FILE")
  # base64url (RFC 4648 §5): base64 → tr +/ -_ → strip padding =.
  routing_b64url=$(printf '%s' "$routing_json" | base64 -w0 | tr '+/' '-_' | tr -d '=')
  routing_uri="happ://routing/onadd/${routing_b64url}"
fi

# subscription-userinfo expire: jq override hook (.expire поле в profile JSON),
# fallback 4102444800 (год 2099 — placeholder для v2.0; real-time tracking deferred к post-v2.0).
expire_value=$(jq -r '.expire // 4102444800' "$profile_file" 2>/dev/null)
sub_userinfo="upload=0; download=0; total=0; expire=${expire_value}"

body_tmp="/tmp/subhttp_body.$$"
subscription_vless_urls=$(printf '%s' "$vless_urls" | prepare_happ_vless_urls)
if [[ "$universal_sub" == "true" ]]; then
  # v2rayNG сначала пытается Base64-decode subscription body. Даём ему
  # классический v2ray-sub: только proxy URI, без HAPP comments/routing,
  # но с тем же safe ordering/filtering, что у HAPP text-body.
  printf '%s' "$subscription_vless_urls" | base64 -w0 > "$body_tmp"
else
  # HAPP standard subscriptions are text-based server lists. Keep body conservative:
  # only vless:// rows by default; metadata stays in HTTP headers.
  {
    printf '%s\n' "$subscription_vless_urls"
    if [[ -n "$routing_uri" ]]; then
      printf '%s\n' "$routing_uri"
    fi
  } > "$body_tmp"
fi

body_size=$(stat -c%s "$body_tmp" 2>/dev/null || wc -c < "$body_tmp")

# Response: те же metadata-ключи дублируются как HTTP headers (REQ-C07 symmetry).
printf 'HTTP/1.1 200 OK\r\n'
printf 'content-type: text/plain; charset=utf-8\r\n'
printf 'content-disposition: attachment; filename="xraytailscale-%s.txt"\r\n' "$short_token"
printf 'content-length: %s\r\n' "$body_size"
printf 'connection: close\r\n'
printf 'cache-control: no-store\r\n'
if [[ "$universal_sub" != "true" ]]; then
  printf 'profile-update-interval: %s\r\n' "$HAPP_PROFILE_UPDATE_INTERVAL"
  printf 'profile-title: base64:%s\r\n' "$profile_title_b64"
  printf 'no-limit-xhttp-enabled: 1\r\n'
  if [[ -n "$ANNOUNCE_HEADER" ]]; then
    printf '%s\r\n' "$ANNOUNCE_HEADER"
  fi
  printf 'subscription-userinfo: %s\r\n' "$sub_userinfo"
  printf 'support-url: %s\r\n' "$HAPP_SUPPORT_URL"
  printf 'profile-web-page-url: %s\r\n' "$HAPP_WEB_URL"
  if [[ -n "$routing_uri" ]]; then
    printf 'routing: %s\r\n' "$routing_uri"
  fi
fi
printf '\r\n'
cat "$body_tmp"

rm -f "$body_tmp"
exit 0
SUBHTTP_EOF

  chmod 755 /usr/local/bin/subhttp.sh
  chown root:root /usr/local/bin/subhttp.sh
  if ! bash -n /usr/local/bin/subhttp.sh; then
    echo -e "${RED}✗ Сгенерированный /usr/local/bin/subhttp.sh не проходит bash -n${NC}"
    return 1
  fi
  echo -e "${GREEN}  ✓ /usr/local/bin/subhttp.sh создан${NC}"

  # ── (2) .happ_defaults.env (idempotent — не перетирать кастомизации оператора) ──
  if [[ ! -f /usr/local/etc/xray/.happ_defaults.env ]]; then
    cat > /usr/local/etc/xray/.happ_defaults.env << 'HAPP_DEFAULTS_EOF'
# xraytailscale HAPP subscription metadata defaults.
# Этот файл source-ится subhttp.sh на КАЖДЫЙ request — менять можно без рестарта сервиса.
# Plan 7.3 menu позволит редактировать через TUI; править руками тоже допустимо
# (синтаксис shell, любые BASH-совместимые конструкции).

# URL поддержки (HAPP импортирует, кликабельно у юзера в клиенте):
HAPP_SUPPORT_URL="https://github.com/vshroot/XrayTailscale"

# URL веб-страницы профиля (HAPP покажет в info клиента):
HAPP_WEB_URL="https://github.com/vshroot/XrayTailscale"

# Отображаемое имя subscription в HAPP. Пусто = использовать имя profile JSON.
HAPP_SERVER_NAME=""

# Интервал автообновления подписки в часах (HAPP читает как hint):
HAPP_PROFILE_UPDATE_INTERVAL=24

# Файл с announcement-сообщением (опционально). Plan 8 (REQ-E04) — TUI редактор.
# Если файл существует и не пуст — его содержимое попадёт в #announce: base64:... (UTF-8 safe).
HAPP_ANNOUNCE_FILE="/usr/local/etc/xray/announce.txt"

# Файл с кастомным HAPP routing JSON (опционально). Если отсутствует или пустой —
# routing profile НЕ отправляется, чтобы не сбрасывать маршрутизацию клиента.
# Важно: это routing приложения HAPP, не список XrayTailscale connection routes.
# Base64url-кодируется в happ://routing/onadd/<...>.
HAPP_ROUTING_JSON_FILE="/usr/local/etc/xray/.happ_routing.json"
HAPP_DEFAULTS_EOF
    chmod 644 /usr/local/etc/xray/.happ_defaults.env
    chown xray:xray /usr/local/etc/xray/.happ_defaults.env 2>/dev/null || true
    echo -e "${GREEN}  ✓ /usr/local/etc/xray/.happ_defaults.env создан${NC}"
  else
    echo -e "${YELLOW}  ⚠ /usr/local/etc/xray/.happ_defaults.env уже существует — не трогаем${NC}"
  fi

  # ── (3) systemd unit (REQ-C09 hardening; opt-in, НЕ enable/start здесь) ──
  cat > /etc/systemd/system/xraytailscale-sub.service << 'SUBUNIT_EOF'
[Unit]
Description=XrayTailscale HAPP subscription handler (socat + subhttp.sh)
Documentation=https://github.com/vshroot/XrayTailscale
After=network-online.target xray.service
Wants=network-online.target

[Service]
Type=simple
User=xray
Group=xray
ExecStart=/usr/bin/socat TCP-LISTEN:8080,reuseaddr,fork,bind=127.0.0.1 EXEC:/usr/local/bin/subhttp.sh

# REQ-C09 hardening:
ProtectSystem=strict
ReadOnlyPaths=/usr/local/etc/xray /usr/local/bin/xraytailscale /usr/local/bin/subhttp.sh
ReadWritePaths=/tmp
NoNewPrivileges=yes
MemoryDenyWriteExecute=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
PrivateDevices=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
LockPersonality=yes

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SUBUNIT_EOF

  chmod 644 /etc/systemd/system/xraytailscale-sub.service
  chown root:root /etc/systemd/system/xraytailscale-sub.service
  echo -e "${GREEN}  ✓ /etc/systemd/system/xraytailscale-sub.service создан${NC}"

  # daemon-reload — чтобы systemctl увидел новый unit. НЕ enable, НЕ start.
  systemctl daemon-reload 2>/dev/null || true

  # Marker (opt-in активирован) — Plan 7.3 проверит наличие для меню/preflight.
  touch /usr/local/etc/xray/.subscription_installed
  chown xray:xray /usr/local/etc/xray/.subscription_installed 2>/dev/null || true

  echo ""
  echo -e "${YELLOW}  ⚠ Юнит создан, но НЕ запущен и НЕ enabled.${NC}"
  echo -e "${YELLOW}    Запуск/активацию выполняет Plan 7.3 menu (после установки публичного TLS).${NC}"
  echo ""
  return 0
}

# ═══════════════════════════════════════════════════════════
# Phase 7 Plan 7.3 — public TLS / local-only / port preflight
# ═══════════════════════════════════════════════════════════
# Public HTTPS port preflight. Эхает 443 если порт свободен, иначе 8443.
# Если порт занят Xray inbound — предупреждение и fallback на 8443.
# Если занят системным сервисом (nginx/apache/др.) — fallback + warning.
# Выбранный порт пишется в /usr/local/etc/xray/.subscription_port (читается
# _subscription_base_url).
_select_subscription_port() {
  local listener
  listener=$(ss -ltnp 'sport = :443' 2>/dev/null | tail -n +2)
  if [[ -z "$listener" ]]; then
    echo 443
    return 0
  fi
  if echo "$listener" | grep -q "xray"; then
    echo -e "${YELLOW}  ⚠ Порт 443 занят Xray inbound — fallback на 8443${NC}" >&2
  else
    echo -e "${YELLOW}  ⚠ Порт 443 занят сторонним процессом — fallback на 8443${NC}" >&2
  fi
  echo 8443
  return 0
}

_happ_find_existing_multiroute_profile() {
  local profile_file profile_name route_count live_count
  for profile_file in "$PROFILES_DIR"/*.json; do
    [[ -f "$profile_file" ]] || continue
    _profile_is_bulk_seed_file "$profile_file" && continue
    route_count=$(jq -r '(.routes // []) | length' "$profile_file" 2>/dev/null || echo 0)
    live_count=$(_profile_live_route_count "$profile_file" 2>/dev/null || echo 0)
    if [[ "$route_count" =~ ^[0-9]+$ ]] && [[ "$live_count" =~ ^[0-9]+$ ]] && \
       [[ "$route_count" -ge 7 ]] && [[ "$live_count" -ge 7 ]]; then
      profile_name=$(basename "$profile_file" .json)
      echo "$profile_name"
      return 0
    fi
  done
  return 1
}

_happ_next_default_profile_name() {
  local base="happ"
  local name="$base"
  local i=1
  while [[ -e "$PROFILES_DIR/$name.json" ]]; do
    name="${base}_${i}"
    ((i++))
  done
  echo "$name"
}

_happ_ensure_default_multiroute_profile() {
  HAPP_DEFAULT_PROFILE=""

  local existing
  if existing=$(_happ_find_existing_multiroute_profile); then
    HAPP_DEFAULT_PROFILE="$existing"
    echo -e "${CYAN}  → Использую существующий multi-route профиль: ${GREEN}${existing}${NC}"
    return 0
  fi

  local profile_name
  profile_name=$(_happ_next_default_profile_name)
  echo -e "${CYAN}  → Создаю HAPP профиль '${profile_name}' с 7 маршрутами...${NC}"
  if ! create_profile_all_routes "$profile_name" "no_pause" "hide_subscription"; then
    echo -e "${RED}✗ Не удалось создать HAPP multi-route профиль${NC}"
    return 1
  fi

  HAPP_DEFAULT_PROFILE="$profile_name"
  return 0
}

_subscription_ensure_handler_running() {
  if [[ ! -f /usr/local/etc/xray/.subscription_installed ]]; then
    return 1
  fi

  if systemctl is-active --quiet xraytailscale-sub.service; then
    return 0
  fi

  _subscription_restart_service
}

_subscription_restart_service() {
  ensure_xray_runtime_user >/dev/null 2>&1 || return 1
  [[ -f /etc/systemd/system/xraytailscale-sub.service ]] || return 1

  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed xraytailscale-sub.service 2>/dev/null || true
  systemctl enable xraytailscale-sub.service >/dev/null 2>&1 || return 1
  systemctl restart xraytailscale-sub.service >/dev/null 2>&1 || return 1
  sleep 1
  systemctl is-active --quiet xraytailscale-sub.service
}

_subscription_repair_handler() {
  echo -e "${CYAN}  → Восстанавливаю HAPP subscription handler...${NC}"
  if ! install_subscription_server >/dev/null 2>&1; then
    return 1
  fi

  _subscription_restart_service
}

_subscription_local_self_test() {
  local token="$1"
  [[ "$token" =~ ^[a-f0-9]{32}$ ]] || return 1

  _subscription_ensure_handler_running || return 1

  SUBSCRIPTION_SELFTEST_HTTP_STATUS=""
  SUBSCRIPTION_SELFTEST_ERROR=""
  SUBSCRIPTION_SELFTEST_BODY=""

  local body_tmp err_tmp
  body_tmp=$(mktemp /tmp/xraytailscale-subtest.XXXXXX) || return 1
  err_tmp=$(mktemp /tmp/xraytailscale-subtest.err.XXXXXX) || {
    rm -f "$body_tmp"
    return 1
  }

  local http_status curl_rc=0
  http_status=$(curl -sS --connect-timeout 2 --max-time 30 \
      "http://127.0.0.1:8080/sub/${token}" \
      -o "$body_tmp" -w '%{http_code}' 2>"$err_tmp") || curl_rc=$?
  SUBSCRIPTION_SELFTEST_HTTP_STATUS="$http_status"
  SUBSCRIPTION_SELFTEST_ERROR=$(head -c 240 "$err_tmp" 2>/dev/null | tr '\n\r' '  ')
  SUBSCRIPTION_SELFTEST_BODY=$(head -c 240 "$body_tmp" 2>/dev/null | tr '\n\r' '  ')

  if [[ "$curl_rc" -eq 0 && "$http_status" == "200" ]] && grep -q 'vless://' "$body_tmp"; then
    rm -f "$body_tmp" "$err_tmp"
    return 0
  fi

  rm -f "$body_tmp" "$err_tmp"
  return 1
}

_subscription_print_selftest_failure() {
  if [[ -n "${SUBSCRIPTION_SELFTEST_HTTP_STATUS:-}" ]]; then
    echo -e "${YELLOW}  Локальный HTTP status: ${SUBSCRIPTION_SELFTEST_HTTP_STATUS}${NC}"
  fi
  if [[ -n "${SUBSCRIPTION_SELFTEST_ERROR:-}" ]]; then
    echo -e "${YELLOW}  curl: ${SUBSCRIPTION_SELFTEST_ERROR}${NC}"
  fi
  if [[ -n "${SUBSCRIPTION_SELFTEST_BODY:-}" ]]; then
    echo -e "${YELLOW}  Ответ handler: ${SUBSCRIPTION_SELFTEST_BODY}${NC}"
  fi
}

_subscription_ensure_profile_ready() {
  local token="$1"

  if _subscription_local_self_test "$token"; then
    return 0
  fi

  _subscription_repair_handler || return 1
  _subscription_local_self_test "$token"
}

_happ_print_subscription_url_for_profile() {
  local profile_name="$1"
  local profile_file="$PROFILES_DIR/$profile_name.json"
  local token url

  token=$(jq -r '.sub_token // ""' "$profile_file" 2>/dev/null)
  if [[ ! "$token" =~ ^[a-f0-9]{32}$ ]]; then
    echo -e "${YELLOW}  ⚠ У профиля ${profile_name} нет валидного sub_token — URL не показан${NC}"
    return 1
  fi

  url="$(_subscription_base_url)/sub/${token}"
  echo ""
  echo -e "${GREEN}═══ ГОТОВАЯ HAPP SUBSCRIPTION URL ═══${NC}"
  echo -e "${BLUE}Профиль:${NC} ${GREEN}${profile_name}${NC}"
  if ! _subscription_ensure_profile_ready "$token"; then
    echo -e "${RED}✗ HAPP subscription handler не отдаёт локальную подписку.${NC}"
    echo -e "${YELLOW}  Внешний клиент получит 502 Bad Gateway, пока 127.0.0.1:8080 не оживёт.${NC}"
    _subscription_print_selftest_failure
    echo -e "${YELLOW}  Диагностика: systemctl status xraytailscale-sub --no-pager -l${NC}"
    echo -e "${YELLOW}  Логи: journalctl -u xraytailscale-sub -n 80 --no-pager${NC}"
    echo ""
    return 1
  fi

  if _subscription_is_local_only; then
    echo -e "${YELLOW}Local-only debug URL:${NC} ${url}"
    echo -e "${RED}QR не показываю: 127.0.0.1 доступен только с VPS/SSH tunnel, не с телефона.${NC}"
  else
    echo -e "${BLUE}URL:${NC} ${GREEN}${url}${NC}"
    qrencode -t ANSIUTF8 "$url"
  fi
  echo ""
  return 0
}

install_subscription_ip_tls() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}    УСТАНОВКА ПОДПИСКИ ПО IP VPS (HTTPS)      ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${CYAN}Режим по умолчанию: внешний HAPP-клиент получает https://<IP>/sub/<token>${NC}"
  echo -e "${YELLOW}Сертификаты на IP у Let's Encrypt short-lived (~6 дней), нужен рабочий renew.${NC}"
  echo ""

  echo -e "${CYAN}  → Проверяю HAPP subscription handler...${NC}"
  install_subscription_server || return 1

  local server_ip
  server_ip=$(get_server_ip)
  if [[ -z "$server_ip" || ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}✗ Не удалось определить публичный IPv4 VPS: ${server_ip:-пусто}${NC}"
    echo -e "${YELLOW}IPv6 IP-cert режим пока не автоматизирован — используйте домен.${NC}"
    sleep 3
    return 1
  fi
  echo -e "${CYAN}  → VPS IPv4: ${server_ip}${NC}"

  local email
  echo -n -e "${YELLOW}Email для Let's Encrypt (renew/account notices): ${NC}"
  read -r email
  if [[ -z "$email" ]] || ! [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    echo -e "${RED}✗ Некорректный email${NC}"
    sleep 2
    return 1
  fi

  local pub_port
  pub_port=$(_select_subscription_port)
  echo -e "${CYAN}  → HTTPS порт подписки: $pub_port${NC}"

  echo -e "${CYAN}  → Установка nginx...${NC}"
  if ! apt-get install -y nginx >/dev/null 2>&1; then
    echo -e "${RED}✗ apt-get install nginx не удалось${NC}"
    return 1
  fi

  local certbot_bin
  if ! _ensure_certbot_ip_tls; then
    echo -e "${YELLOW}Нужен Certbot 5.4+ для webroot IP certificates.${NC}"
    echo -e "${YELLOW}Временно используйте доменный режим или обновите certbot из актуального источника.${NC}"
    return 1
  fi
  certbot_bin="$CERTBOT_IP_BIN"
  echo -e "${GREEN}  ✓ Certbot с IP support: ${certbot_bin}${NC}"

  local webroot="/var/www/xraytailscale-ip-acme"
  mkdir -p "$webroot/.well-known/acme-challenge"
  chmod -R 755 "$webroot"

  cat > /etc/nginx/sites-available/xraytailscale-sub << NGINX_HTTP_EOF
limit_req_zone \$binary_remote_addr zone=xraytailscale_sub:10m rate=30r/m;

server {
    listen 80;
    listen [::]:80;
    server_name ${server_ip};

    location ^~ /.well-known/acme-challenge/ {
        root ${webroot};
        default_type text/plain;
    }

    location / {
        return 404;
    }
}
NGINX_HTTP_EOF
  ln -sf /etc/nginx/sites-available/xraytailscale-sub /etc/nginx/sites-enabled/xraytailscale-sub
  if ! nginx -t >/tmp/nginx-xraytailscale-sub.log 2>&1; then
    echo -e "${RED}✗ nginx -t failed${NC}"
    cat /tmp/nginx-xraytailscale-sub.log
    return 1
  fi
  if ! systemctl enable --now nginx >/dev/null 2>&1; then
    echo -e "${RED}✗ nginx не запустился. Проверьте, не занят ли порт 80 другим сервисом.${NC}"
    return 1
  fi
  if ! systemctl reload nginx >/dev/null 2>&1; then
    echo -e "${RED}✗ nginx не перечитал HTTP config для ACME challenge${NC}"
    return 1
  fi

  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw limit 80/tcp >/dev/null 2>&1
    ufw limit "${pub_port}/tcp" >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
    echo -e "${GREEN}  ✓ UFW: limit 80/tcp + ${pub_port}/tcp${NC}"
  fi

  echo -e "${CYAN}  → Запуск certbot IP certificate для ${server_ip}...${NC}"
  if ! "$certbot_bin" certonly \
      --cert-name "$server_ip" \
      --preferred-profile shortlived \
      --webroot \
      --webroot-path "$webroot" \
      --ip-address "$server_ip" \
      --non-interactive \
      --agree-tos \
      -m "$email" \
      --deploy-hook "systemctl reload nginx" \
      >/tmp/certbot-ip.log 2>&1; then
    echo -e "${RED}✗ certbot не смог выдать IP certificate. Лог: /tmp/certbot-ip.log${NC}"
    tail -30 /tmp/certbot-ip.log
    echo -e "${YELLOW}Проверьте, что порт 80 доступен снаружи и VPS IP совпадает.${NC}"
    return 1
  fi
  systemctl reset-failed certbot.service 2>/dev/null || true

  local cert_dir="/etc/letsencrypt/live/${server_ip}"
  if [[ ! -f "$cert_dir/fullchain.pem" || ! -f "$cert_dir/privkey.pem" ]]; then
    echo -e "${RED}✗ certbot завершился, но cert files не найдены: $cert_dir${NC}"
    return 1
  fi

  cat > /etc/nginx/sites-available/xraytailscale-sub << NGINX_TLS_EOF
limit_req_zone \$binary_remote_addr zone=xraytailscale_sub:10m rate=30r/m;

server {
    listen 80;
    listen [::]:80;
    server_name ${server_ip};

    location ^~ /.well-known/acme-challenge/ {
        root ${webroot};
        default_type text/plain;
    }

    location / {
        return 404;
    }
}

server {
    listen ${pub_port} ssl http2;
    listen [::]:${pub_port} ssl http2;
    server_name ${server_ip};

    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    location /sub/ {
        access_log off;
        limit_req zone=xraytailscale_sub burst=10 nodelay;
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow, nosnippet" always;
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        return 404;
    }
}
NGINX_TLS_EOF
  if ! nginx -t >/tmp/nginx-xraytailscale-sub.log 2>&1; then
    echo -e "${RED}✗ nginx TLS config failed${NC}"
    cat /tmp/nginx-xraytailscale-sub.log
    return 1
  fi
  if ! systemctl reload nginx >/dev/null 2>&1; then
    echo -e "${RED}✗ nginx не перечитал TLS config${NC}"
    return 1
  fi

  echo "$pub_port" > /usr/local/etc/xray/.subscription_port
  echo "$server_ip" > /usr/local/etc/xray/.subscription_domain
  echo "$server_ip" > /usr/local/etc/xray/.subscription_server_addr
  echo "ip_tls" > /usr/local/etc/xray/.subscription_mode
  chown xray:xray /usr/local/etc/xray/.subscription_port /usr/local/etc/xray/.subscription_domain /usr/local/etc/xray/.subscription_server_addr /usr/local/etc/xray/.subscription_mode 2>/dev/null || true

  if ! _subscription_restart_service; then
    echo -e "${RED}✗ xraytailscale-sub.service не запустился — проверьте journalctl -u xraytailscale-sub${NC}"
    return 1
  fi

  local _happ_profile
  if ! _happ_ensure_default_multiroute_profile; then
    return 1
  fi
  _happ_profile="$HAPP_DEFAULT_PROFILE"

  local _summary_base
  _summary_base=$(_subscription_base_url)
  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}    ✓ ПОДПИСКА ПО IP VPS АКТИВНА              ${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${BLUE}Base URL:${NC} ${GREEN}${_summary_base}${NC}"
  _happ_print_subscription_url_for_profile "$_happ_profile"
  echo -e "${CYAN}Для ручного контроля маршрутов используйте главное меню → 'Создать новый профиль'.${NC}"
  echo ""
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read -r _
}

# Public TLS installer by domain.
# Flow: domain prompt → DNS preflight (soft) → email prompt → port preflight
# → nginx HTTP-only ACME site on :80 → certbot certonly --webroot → explicit SSL
# nginx site on selected public port → markers → enable xraytailscale-sub.
# Важно: не используем certbot --nginx. Он плохо предсказуем на нестандартном
# HTTPS-порту (8443) и может оставить plain HTTP listener после failed certbot.
install_subscription_public_tls() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}    УСТАНОВКА ПУБЛИЧНОЙ ПОДПИСКИ (HTTPS)      ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""

  # Pre-flight: всегда регенерируем handler/unit — это чинит старые partial updates.
  echo -e "${CYAN}  → Проверяю HAPP subscription handler...${NC}"
  install_subscription_server || return 1

  # Domain prompt (M6: read -r — без -r теряются backslashes).
  local domain
  echo -n -e "${YELLOW}Введите домен (A/AAAA должна указывать на этот VPS): ${NC}"
  read -r domain
  if [[ -z "$domain" ]] || ! [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo -e "${RED}✗ Некорректный домен${NC}"
    sleep 2
    return 1
  fi

  # DNS sanity-check (soft — warning + опция продолжить).
  # Rationale: split-DNS / Cloudflare proxied (orange-cloud) дают false-negatives.
  local server_ip resolved_ip
  server_ip=$(get_server_ip)
  resolved_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)
  if [[ -n "$resolved_ip" ]] && [[ "$resolved_ip" != "$server_ip" ]]; then
    echo -e "${YELLOW}  ⚠ DNS-резолв $domain → $resolved_ip, но VPS IP = $server_ip${NC}"
    echo -e "${YELLOW}    certbot скорее всего откажет. Продолжить? [y/N]${NC}"
    local cont
    read -r cont
    [[ "$cont" =~ ^[yYдД]$ ]] || return 1
  fi

  # Email prompt (для certbot --agree-tos -m).
  local email
  echo -n -e "${YELLOW}Email для Let's Encrypt (восстановление аккаунта): ${NC}"
  read -r email
  if [[ -z "$email" ]] || ! [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    echo -e "${RED}✗ Некорректный email${NC}"
    sleep 2
    return 1
  fi

  # Port preflight: 443 (default) или 8443 (если 443 занят).
  local pub_port
  pub_port=$(_select_subscription_port)
  echo -e "${CYAN}  → Публичный порт: $pub_port${NC}"

  echo -e "${CYAN}  → Установка nginx + certbot...${NC}"
  if ! apt-get install -y nginx certbot >/dev/null 2>&1; then
    echo -e "${RED}✗ apt-get install nginx certbot не удалось${NC}"
    return 1
  fi

  local certbot_bin
  if [[ -x /snap/bin/certbot ]]; then
    certbot_bin="/snap/bin/certbot"
  else
    certbot_bin=$(command -v certbot 2>/dev/null || true)
  fi
  if [[ -z "$certbot_bin" || ! -x "$certbot_bin" ]]; then
    echo -e "${RED}✗ certbot не найден после установки${NC}"
    return 1
  fi

  local webroot="/var/www/xraytailscale-domain-acme"
  mkdir -p "$webroot/.well-known/acme-challenge"
  chmod -R 755 "$webroot"

  cat > /etc/nginx/sites-available/xraytailscale-sub << NGINX_HTTP_EOF
limit_req_zone \$binary_remote_addr zone=xraytailscale_sub:10m rate=30r/m;

server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root ${webroot};
        default_type text/plain;
    }

    location / {
        return 404;
    }
}
NGINX_HTTP_EOF
  ln -sf /etc/nginx/sites-available/xraytailscale-sub /etc/nginx/sites-enabled/xraytailscale-sub
  if ! nginx -t >/tmp/nginx-xraytailscale-sub.log 2>&1; then
    echo -e "${RED}✗ nginx -t failed${NC}"
    cat /tmp/nginx-xraytailscale-sub.log
    return 1
  fi
  if ! systemctl enable --now nginx >/dev/null 2>&1; then
    echo -e "${RED}✗ nginx не запустился. Проверьте, не занят ли порт 80 другим сервисом.${NC}"
    return 1
  fi
  if ! systemctl reload nginx >/dev/null 2>&1; then
    echo -e "${RED}✗ nginx не перечитал HTTP config для ACME challenge${NC}"
    return 1
  fi

  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw limit 80/tcp >/dev/null 2>&1
    ufw limit "${pub_port}/tcp" >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
    echo -e "${GREEN}  ✓ UFW: limit 80/tcp + ${pub_port}/tcp${NC}"
  fi

  echo -e "${CYAN}  → Запуск certbot webroot для $domain...${NC}"
  if ! "$certbot_bin" certonly \
      --cert-name "$domain" \
      --webroot \
      --webroot-path "$webroot" \
      -d "$domain" \
      --non-interactive \
      --agree-tos \
      -m "$email" \
      --deploy-hook "systemctl reload nginx" \
      >/tmp/certbot.log 2>&1; then
    echo -e "${RED}✗ certbot не смог выдать сертификат. Лог: /tmp/certbot.log${NC}"
    tail -30 /tmp/certbot.log
    echo -e "${YELLOW}Проверьте, что порт 80 доступен снаружи, DNS указывает на VPS или Cloudflare проксирует HTTP challenge.${NC}"
    return 1
  fi
  systemctl reset-failed certbot.service 2>/dev/null || true

  local cert_dir="/etc/letsencrypt/live/${domain}"
  if [[ ! -f "$cert_dir/fullchain.pem" || ! -f "$cert_dir/privkey.pem" ]]; then
    echo -e "${RED}✗ certbot завершился, но cert files не найдены: $cert_dir${NC}"
    return 1
  fi

  cat > /etc/nginx/sites-available/xraytailscale-sub << NGINX_TLS_EOF
limit_req_zone \$binary_remote_addr zone=xraytailscale_sub:10m rate=30r/m;

server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root ${webroot};
        default_type text/plain;
    }

    location / {
        return 404;
    }
}

server {
    listen ${pub_port} ssl http2;
    listen [::]:${pub_port} ssl http2;
    server_name ${domain};

    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    location /sub/ {
        access_log off;
        limit_req zone=xraytailscale_sub burst=10 nodelay;
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow, nosnippet" always;
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        return 404;
    }
}
NGINX_TLS_EOF
  if ! nginx -t >/tmp/nginx-xraytailscale-sub.log 2>&1; then
    echo -e "${RED}✗ nginx TLS config failed${NC}"
    cat /tmp/nginx-xraytailscale-sub.log
    return 1
  fi
  if ! systemctl reload nginx >/dev/null 2>&1; then
    echo -e "${RED}✗ nginx не перечитал TLS config${NC}"
    return 1
  fi

  # Markers — читаются _subscription_base_url (helper из Plan 7.2).
  echo "$pub_port" > /usr/local/etc/xray/.subscription_port
  echo "$domain" > /usr/local/etc/xray/.subscription_domain
  echo "$server_ip" > /usr/local/etc/xray/.subscription_server_addr
  echo "domain_tls" > /usr/local/etc/xray/.subscription_mode
  chown xray:xray /usr/local/etc/xray/.subscription_port /usr/local/etc/xray/.subscription_domain /usr/local/etc/xray/.subscription_server_addr /usr/local/etc/xray/.subscription_mode 2>/dev/null || true

  # Активация unit.
  if ! _subscription_restart_service; then
    echo -e "${RED}✗ xraytailscale-sub.service не запустился — проверьте journalctl -u xraytailscale-sub${NC}"
    return 1
  fi

  local _happ_profile
  if ! _happ_ensure_default_multiroute_profile; then
    return 1
  fi
  _happ_profile="$HAPP_DEFAULT_PROFILE"

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}    ✓ ПУБЛИЧНАЯ ПОДПИСКА АКТИВНА              ${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════${NC}"
  echo ""
  # B1: shared helper — НЕ строим https://${domain} инлайн.
  local _summary_base
  _summary_base=$(_subscription_base_url)
  echo -e "${BLUE}URL:${NC} ${GREEN}${_summary_base}${NC} (порт ${pub_port})"
  _happ_print_subscription_url_for_profile "$_happ_profile"
  echo -e "${CYAN}Для ручного контроля маршрутов используйте главное меню → 'Создать новый профиль'.${NC}"
  echo ""
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read -r _
}

# Local-only fallback installer (REQ-C03).
# Без nginx, без certbot, БЕЗ открытия UFW (loopback bypasses firewall).
# Доступ — только через ssh-tunnel: ssh -L 8080:127.0.0.1:8080 user@vps.
install_subscription_local_only() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}    УСТАНОВКА ПОДПИСКИ (LOCAL-ONLY FALLBACK) ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${YELLOW}⚠ Подписки доступны только локально (127.0.0.1:8080).${NC}"
  echo -e "${YELLOW}  Доступ — через ssh-tunnel: ssh -L 8080:127.0.0.1:8080 user@vps${NC}"
  echo ""

  install_subscription_server || return 1

  echo "8080" > /usr/local/etc/xray/.subscription_port
  echo "127.0.0.1" > /usr/local/etc/xray/.subscription_domain
  get_server_ip > /usr/local/etc/xray/.subscription_server_addr 2>/dev/null || true
  echo "local_only" > /usr/local/etc/xray/.subscription_mode
  chown xray:xray /usr/local/etc/xray/.subscription_port /usr/local/etc/xray/.subscription_domain /usr/local/etc/xray/.subscription_server_addr /usr/local/etc/xray/.subscription_mode 2>/dev/null || true

  if ! _subscription_restart_service; then
    echo -e "${RED}✗ xraytailscale-sub.service не запустился${NC}"
    return 1
  fi

  local _happ_profile
  if ! _happ_ensure_default_multiroute_profile; then
    return 1
  fi
  _happ_profile="$HAPP_DEFAULT_PROFILE"

  echo ""
  echo -e "${GREEN}✓ Local-only handler запущен на 127.0.0.1:8080${NC}"
  echo -e "${CYAN}  UFW: порт НЕ открыт (loopback bypass).${NC}"
  _happ_print_subscription_url_for_profile "$_happ_profile"
  echo ""
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read -r _
}

# Управление подпиской (REQ-C12): список профилей с sub_token, для выбранного —
# URL + QR + revoke + advanced raw vless:// (PQ-aware QR gate, REQ-C14).
# B1 invariant: base URL ВСЕГДА через _subscription_base_url (Plan 7.2 helper).
# M5: raw vless QR gated по pq_enabled из profile JSON (НЕ threshold-based по длине).
# M6: все read calls — с -r (4 шт: choice, act, два Enter-pause).
manage_subscription_menu() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}    УПРАВЛЕНИЕ ПОДПИСКОЙ                      ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""

  if [[ ! -f /usr/local/etc/xray/.subscription_installed ]]; then
    echo -e "${RED}✗ Подписка не установлена. Сначала выберите 'Установить'.${NC}"
    sleep 2
    return
  fi

  # B1: base URL ВСЕГДА через shared helper (Plan 7.2). НЕТ инлайн-построения.
  local base_url
  base_url=$(_subscription_base_url)
  local local_only=false
  if _subscription_is_local_only; then
    local_only=true
    echo -e "${RED}⚠ Подписка сейчас в local-only режиме: ${base_url}${NC}"
    echo -e "${YELLOW}  Этот URL НЕ работает с телефона/внешнего клиента. Включите public TLS в меню подписки.${NC}"
    echo ""
  fi

  local profiles=()
  local live_counts=()
  local stale_count=0
  local pf profile live_count
  for pf in "$PROFILES_DIR"/*.json; do
    [[ ! -f "$pf" ]] && continue
    if _profile_is_bulk_seed_file "$pf"; then
      continue
    fi
    profile=$(basename "$pf" .json)
    live_count=$(_profile_live_route_count "$pf" 2>/dev/null || echo 0)
    if [[ "$live_count" =~ ^[0-9]+$ ]] && [[ "$live_count" -gt 0 ]]; then
      profiles+=("$profile")
      live_counts+=("$live_count")
    else
      ((stale_count++))
    fi
  done

  if [[ ${#profiles[@]} -eq 0 ]]; then
    echo -e "${YELLOW}⚠ Нет профилей.${NC}"
    if [[ "$stale_count" -gt 0 ]]; then
      echo -e "${RED}  Найдено stale profile JSON: $stale_count. Их порты отсутствуют в live config.json.${NC}"
    fi
    sleep 2
    return
  fi
  if [[ "$stale_count" -gt 0 ]]; then
    echo -e "${YELLOW}⚠ Скрыто stale профилей: $stale_count (их порты уже не слушаются Xray).${NC}"
    echo ""
  fi

  echo -e "${YELLOW}Выберите профиль:${NC}"
  echo ""
  local i=1
  for profile in "${profiles[@]}"; do
    local tok
    tok=$(jq -r '.sub_token // ""' "$PROFILES_DIR/$profile.json" 2>/dev/null)
    local short="${tok:0:8}"
    local live="${live_counts[$((i-1))]}"
    echo -e "${CYAN} $i)${NC} $profile ${BLUE}[token: ${short}..., live routes: ${live}]${NC}"
    ((i++))
  done
  echo -e "${CYAN} 0)${NC} Назад"
  echo ""
  echo -n -e "${YELLOW}Профиль: ${NC}"
  local choice
  read -r choice
  [[ "$choice" == "0" ]] && return
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#profiles[@]} ]]; then
    echo -e "${RED}✗ Неверный выбор${NC}"
    sleep 2
    return
  fi

  local selected="${profiles[$((choice-1))]}"
  local pfile="$PROFILES_DIR/${selected}.json"
  local token
  token=$(jq -r '.sub_token // ""' "$pfile" 2>/dev/null)
  if [[ ! "$token" =~ ^[a-f0-9]{32}$ ]]; then
    echo -e "${RED}✗ В профиле нет валидного sub_token. Запустите 'sudo xraytailscale' — миграция .subscription_tokens_2026 догенерирует.${NC}"
    sleep 3
    return
  fi

  while true; do
    show_ascii
    local url="${base_url}/sub/${token}"
    echo -e "${BLUE}═══ Профиль: ${selected} ═══${NC}"
    echo ""
    if [[ "$local_only" == "true" ]]; then
      echo -e "${YELLOW}Local-only debug URL:${NC}"
      echo -e "  ${YELLOW}$url${NC}"
      echo -e "${RED}  Не QR-кодить для телефона: 127.0.0.1 у клиента указывает на сам клиент.${NC}"
    else
      echo -e "${BLUE}Subscription URL:${NC}"
      echo -e "  ${GREEN}$url${NC}"
    fi
    echo ""
    if [[ "$local_only" == "true" ]]; then
      echo -e "${CYAN} 1)${NC} Включить public TLS по IP VPS для внешней подписки"
    else
      echo -e "${CYAN} 1)${NC} Показать QR-код subscription URL"
    fi
    echo -e "${CYAN} 2)${NC} Revoke (сгенерировать новый sub_token)"
    echo -e "${CYAN} 3)${NC} Показать raw vless:// (advanced)"
    echo -e "${CYAN} 0)${NC} Назад"
    echo ""
    echo -n -e "${YELLOW}Выбор: ${NC}"
    local act
    read -r act
    case "$act" in
      1)
        # REQ-C14: QR ВСЕГДА для короткого subscription URL (HTTPS короткая строка).
        if [[ "$local_only" == "true" ]]; then
          install_subscription_ip_tls
          base_url=$(_subscription_base_url)
          if _subscription_is_local_only; then
            local_only=true
          else
            local_only=false
          fi
        else
          echo ""
          if _subscription_ensure_profile_ready "$token"; then
            qrencode -t ANSIUTF8 "$url"
            echo ""
          else
            echo -e "${RED}✗ HAPP subscription handler не отвечает локально.${NC}"
            echo -e "${YELLOW}  Внешний клиент сейчас получит 502 Bad Gateway.${NC}"
            _subscription_print_selftest_failure
            echo -e "${YELLOW}  Проверьте: systemctl status xraytailscale-sub --no-pager -l${NC}"
            echo -e "${YELLOW}  Логи: journalctl -u xraytailscale-sub -n 80 --no-pager${NC}"
            echo ""
          fi
        fi
        echo -n -e "${YELLOW}Enter для продолжения...${NC}"
        read -r _
        ;;
      2)
        # Revoke — генерируем новый 32-hex sub_token, пишем через safe_jq_write.
        # Рестарт subhttp НЕ нужен: handler читает .sub_token из profile JSON на каждый request.
        local new_token
        new_token=$(openssl rand -hex 16)
        if [[ ! "$new_token" =~ ^[a-f0-9]{32}$ ]]; then
          echo -e "${RED}✗ Не удалось сгенерировать токен${NC}"
          sleep 2
          continue
        fi
        if ! safe_jq_write --arg t "$new_token" '.sub_token = $t' "$pfile"; then
          echo -e "${RED}✗ Запись в profile JSON не удалась${NC}"
          sleep 2
          continue
        fi
        chown xray:xray "$pfile" 2>/dev/null || true
        token="$new_token"
        echo -e "${GREEN}✓ Новый sub_token. Старая URL более не работает.${NC}"
        echo -e "${CYAN}  Новая URL: ${base_url}/sub/${token}${NC}"
        sleep 3
        ;;
      3)
        # M5: raw vless:// QR — PQ-aware gate, НЕ threshold-based по длине строки.
        # Rationale: PQ профили имеют encryption=mlkem768x25519plus.<base64-~2KB>, что
        # делает QR нечитаемым. Legacy vless без PQ обычно укладывается в Version-25 QR.
        # Threshold-based (length > N) рискует ложно блокировать legacy с длинным SNI/xhttp_path.
        # Точный сигнал — pq_enabled поле в profile JSON (Phase 6 REQ-A04 / schema_version:2).
        local raw pq_enabled
        raw=$(_generate_vless_urls_for_profile "$pfile" 2>/dev/null) || {
          echo -e "${RED}✗ Не удалось построить vless://${NC}"
          sleep 2
          continue
        }
        if _profile_has_pq_route "$pfile"; then
          pq_enabled=true
        else
          pq_enabled=false
        fi
        echo ""
        echo -e "${CYAN}Raw vless:// URL(s):${NC}"
        echo -e "${YELLOW}${raw}${NC}"
        echo ""
        if [[ "$pq_enabled" == "true" ]]; then
          echo -e "${RED}  ✗ QR не генерируется: PQ-профиль (encryption=mlkem... ~2KB).${NC}"
          echo -e "${YELLOW}  PQ vless:// строки нечитаемы как QR-код.${NC}"
          echo -e "${YELLOW}  Используйте subscription URL/QR (пункт 1 — короткий HTTPS-link).${NC}"
        else
          echo -e "${GREEN}  → legacy профиль (без PQ) — QR допустим${NC}"
          qrencode -t ANSIUTF8 "$raw"
        fi
        echo ""
        echo -n -e "${YELLOW}Enter для продолжения...${NC}"
        read -r _
        ;;
      0) return ;;
    esac
  done
}

# TUI редактор /usr/local/etc/xray/.happ_defaults.env (REQ-C13).
# Атомарная замена через awk + temp + mv. sed -i НЕ используем — риск partial write.
# Sanitization: запрещаем " \ $ ` — защита от shell-инъекции при source.
# Рестарт subhttp НЕ требуется (subhttp source-ит env на каждый request).
# M6: read calls с -r чтобы не терять backslash в URL/путях.
happ_settings_menu() {
  local env_file=/usr/local/etc/xray/.happ_defaults.env
  if [[ ! -f "$env_file" ]]; then
    echo -e "${RED}✗ $env_file не существует — сначала выполните установку подписки.${NC}"
    sleep 2
    return
  fi

  while true; do
    show_ascii
    # Локальный source — читаем текущие значения.
    local HAPP_SERVER_NAME HAPP_SUPPORT_URL HAPP_WEB_URL HAPP_PROFILE_UPDATE_INTERVAL HAPP_ANNOUNCE_FILE HAPP_ROUTING_JSON_FILE
    # shellcheck disable=SC1090
    source "$env_file"

    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}    НАСТРОЙКИ HAPP METADATA                   ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN} 1)${NC} HAPP_SERVER_NAME = ${YELLOW}${HAPP_SERVER_NAME:-(имя профиля)}${NC}"
    echo -e "${CYAN} 2)${NC} HAPP_SUPPORT_URL = ${YELLOW}${HAPP_SUPPORT_URL:-(не задано)}${NC}"
    echo -e "${CYAN} 3)${NC} HAPP_WEB_URL = ${YELLOW}${HAPP_WEB_URL:-(не задано)}${NC}"
    echo -e "${CYAN} 4)${NC} HAPP_PROFILE_UPDATE_INTERVAL = ${YELLOW}${HAPP_PROFILE_UPDATE_INTERVAL:-24}${NC} часов"
    echo -e "${CYAN} 5)${NC} HAPP_ANNOUNCE_FILE = ${YELLOW}${HAPP_ANNOUNCE_FILE:-(не задано)}${NC}"
    echo -e "${CYAN} 6)${NC} HAPP_ROUTING_JSON_FILE = ${YELLOW}${HAPP_ROUTING_JSON_FILE:-(не задано)}${NC}"
    echo -e "${CYAN} 0)${NC} Назад"
    echo ""
    echo -n -e "${YELLOW}Изменить (1-6, 0=назад): ${NC}"
    local choice
    read -r choice
    case "$choice" in
      0) return ;;
      1) _happ_edit_field "$env_file" "HAPP_SERVER_NAME" "$HAPP_SERVER_NAME" ;;
      2) _happ_edit_field "$env_file" "HAPP_SUPPORT_URL" "$HAPP_SUPPORT_URL" ;;
      3) _happ_edit_field "$env_file" "HAPP_WEB_URL" "$HAPP_WEB_URL" ;;
      4) _happ_edit_field "$env_file" "HAPP_PROFILE_UPDATE_INTERVAL" "$HAPP_PROFILE_UPDATE_INTERVAL" ;;
      5) _happ_edit_field "$env_file" "HAPP_ANNOUNCE_FILE" "$HAPP_ANNOUNCE_FILE" ;;
      6) _happ_edit_field "$env_file" "HAPP_ROUTING_JSON_FILE" "$HAPP_ROUTING_JSON_FILE" ;;
      *) echo -e "${RED}✗ Некорректный выбор${NC}"; sleep 1 ;;
    esac
  done
}

# Атомарная замена значения KEY="..." в env-файле через awk → temp → mv.
# M6: read -r — без -r теряются backslashes в URL/путях.
# Sanitization запрещает " \ $ ` (предотвращает shell-инъекцию при source в subhttp.sh).
_happ_edit_field() {
  local env_file="$1"
  local key="$2"
  local current="$3"
  echo -n -e "${YELLOW}Новое значение для ${key} (Enter=оставить '${current}'): ${NC}"
  local new_val
  read -r new_val
  [[ -z "$new_val" ]] && return 0   # пользователь отменил
  if [[ "$new_val" =~ [\"\\\$\`] ]]; then
    echo -e "${RED}✗ Значение не может содержать символы \" \\ \$ \`${NC}"
    sleep 2
    return 1
  fi
  local tmp
  tmp=$(mktemp /tmp/happ_defaults.XXXXXX) || { echo -e "${RED}✗ mktemp failed${NC}"; return 1; }
  if grep -q "^${key}=" "$env_file"; then
    awk -v k="$key" -v v="$new_val" 'BEGIN{FS=OFS="="} $1==k {$0=k"=\""v"\""} {print}' "$env_file" > "$tmp"
  else
    cp "$env_file" "$tmp"
    printf '%s="%s"\n' "$key" "$new_val" >> "$tmp"
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo -e "${RED}✗ Временный файл пуст — отмена${NC}"
    return 1
  fi
  mv "$tmp" "$env_file"
  chmod 644 "$env_file"
  chown xray:xray "$env_file" 2>/dev/null || true
  echo -e "${GREEN}✓ ${key} обновлено (рестарт subhttp не требуется — source на каждый request)${NC}"
  if [[ -f /usr/local/etc/xray/.subscription_installed ]]; then
    if install_subscription_server >/dev/null 2>&1; then
      echo -e "${GREEN}subscription handler регенерирован${NC}"
    else
      echo -e "${YELLOW}Регенерация subscription handler не удалась — переустановите подписку через меню${NC}"
    fi
  fi
  sleep 1
}

# Редактор operator announcement для HAPP subscription (REQ-E04).
# subhttp.sh читает announce.txt на каждый request; после изменения регенерируем
# handler, если subscription server уже установлен.
edit_happ_announce_menu() {
  local ann_file="/usr/local/etc/xray/announce.txt"

  while true; do
    show_ascii
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}    HAPP ANNOUNCEMENT (текст подписки)         ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo ""

    if [[ -s "$ann_file" ]]; then
      echo -e "${GREEN}Текущий announcement:${NC}"
      head -c 200 "$ann_file"
      echo ""
      echo ""
    else
      echo -e "${YELLOW}Announcement не задан (HAPP header отсутствует)${NC}"
      echo ""
    fi

    echo -e "${CYAN} 1)${NC} Установить/изменить текст"
    echo -e "${CYAN} 2)${NC} Очистить (убрать announcement)"
    echo -e "${CYAN} 0)${NC} Назад"
    echo ""
    echo -n -e "${YELLOW}Выбор: ${NC}"
    local choice
    read -r choice

    case "$choice" in
      1)
        echo -e "${YELLOW}Введите однострочный текст (~200 char max, без переносов строк):${NC}"
        echo -n -e "${CYAN}> ${NC}"
        local new_text
        read -r new_text
        new_text="${new_text:0:200}"
        new_text="${new_text//$'\n'/}"
        new_text="${new_text//$'\r'/}"
        if [[ -z "$new_text" ]]; then
          rm -f "$ann_file"
          echo -e "${GREEN}Announcement очищен${NC}"
        else
          echo -n -e "${YELLOW}Сохранить '${new_text}'? [y/N]: ${NC}"
          local confirm
          read -r confirm
          if [[ "$confirm" =~ ^[yYдД]$ ]]; then
            local tmp
            tmp=$(mktemp /tmp/announce.XXXXXX) || {
              echo -e "${RED}✗ mktemp failed${NC}"
              echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
              read -r _
              continue
            }
            printf '%s' "$new_text" > "$tmp"
            mv "$tmp" "$ann_file"
            chown xray:xray "$ann_file" 2>/dev/null || true
            chmod 644 "$ann_file"
            echo -e "${GREEN}Announcement сохранен в $ann_file${NC}"
          else
            echo -e "${CYAN}✓ Отменено${NC}"
          fi
        fi
        if [[ -f /usr/local/etc/xray/.subscription_installed ]]; then
          if install_subscription_server >/dev/null 2>&1; then
            echo -e "${GREEN}subhttp.sh регенерирован с announce-логикой${NC}"
          else
            echo -e "${YELLOW}Регенерация subhttp.sh не удалась — переустановите подписку через меню${NC}"
          fi
        fi
        echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
        read -r _
        ;;
      2)
        rm -f "$ann_file"
        echo -e "${GREEN}Announcement очищен${NC}"
        if [[ -f /usr/local/etc/xray/.subscription_installed ]]; then
          if install_subscription_server >/dev/null 2>&1; then
            echo -e "${GREEN}subhttp.sh регенерирован без announcement${NC}"
          else
            echo -e "${YELLOW}Регенерация subhttp.sh не удалась — переустановите подписку через меню${NC}"
          fi
        fi
        echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
        read -r _
        ;;
      0) return ;;
      *) echo -e "${RED}Неверный выбор${NC}"; sleep 1 ;;
    esac
  done
}

# Главный wrapper-подменю «Подписка HAPP».
# Status-line через _subscription_base_url (B1 — никакого инлайн-построения).
# M6: read с -r.
happ_subscription_menu() {
  while true; do
    show_ascii
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}    HAPP SUBSCRIPTION SERVER                  ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo ""

    if [[ -f /usr/local/etc/xray/.subscription_installed ]]; then
      # B1: status-line через shared helper, никакого инлайна.
      local _status_url _status_mode
      _status_url=$(_subscription_base_url)
      _status_mode=$(cat /usr/local/etc/xray/.subscription_mode 2>/dev/null || echo "unknown")
      if _subscription_is_local_only; then
        echo -e "${YELLOW}  ⚠ Local-only (${_status_mode}): ${_status_url}${NC}"
        echo -e "${RED}    Не подходит для внешнего клиента. Включите public TLS (пункт 1).${NC}"
      else
        echo -e "${GREEN}  ✓ Public subscription (${_status_mode}): ${_status_url}${NC}"
      fi
      echo ""
    else
      echo -e "${YELLOW}  ⚠ Не установлено${NC}"
      echo ""
    fi

    echo -e "${CYAN} 1)${NC} Создать HAPP-подписку по IP VPS ${GREEN}(7 маршрутов + URL/QR)${NC}"
    echo -e "${CYAN} 2)${NC} Создать HAPP-подписку по домену ${GREEN}(7 маршрутов + URL/QR)${NC}"
    echo -e "${CYAN} 3)${NC} Local-only debug (127.0.0.1:8080)"
    echo -e "${CYAN} 4)${NC} Управление существующими подписками (URL / QR / revoke)"
    echo -e "${CYAN} 5)${NC} Настройки HAPP (.happ_defaults.env)"
    echo -e "${CYAN} 6)${NC} Настроить announcement (HAPP)"
    echo -e "${CYAN} 0)${NC} Назад в главное меню"
    echo ""
    echo -n -e "${YELLOW}Выбор: ${NC}"
    local c
    read -r c
    case "$c" in
      1|"") install_subscription_ip_tls ;;
      2) install_subscription_public_tls ;;
      3) install_subscription_local_only ;;
      4) manage_subscription_menu ;;
      5) happ_settings_menu ;;
      6) edit_happ_announce_menu ;;
      0) return ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════
# BULK HAPP USERS
# ═══════════════════════════════════════════════════════════

