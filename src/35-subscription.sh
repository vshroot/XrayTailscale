_cleanup_legacy_subscription_artifacts() {
  local legacy_base="xrayeba""tor"
  local legacy_unit="${legacy_base}-sub.service"
  local legacy_site="${legacy_base}-sub"

  systemctl disable --now "$legacy_unit" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${legacy_unit}" 2>/dev/null || true
  rm -f "/etc/nginx/sites-enabled/${legacy_site}" "/etc/nginx/sites-available/${legacy_site}" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════
# Общая rate-limit зона для /sub/ — в отдельном conf.d файле.
# Она нужна И IP-vhost'у, И self-steal backend (доменный режим), поэтому
# не может жить внутри одного из них: отключение IP-vhost при переходе на
# домен раньше уносило зону и роняло nginx -t («zero size shared memory zone»).
# conf.d/*.conf подключается на http-уровне и не зависит от sites-enabled.
# ═══════════════════════════════════════════════════════════
SUBSCRIPTION_LIMIT_ZONE_CONF="/etc/nginx/conf.d/xraytailscale-sub-limit.conf"
_subscription_ensure_limit_zone() {
  mkdir -p /etc/nginx/conf.d 2>/dev/null || true
  cat > "$SUBSCRIPTION_LIMIT_ZONE_CONF" <<'ZONE_EOF'
# Shared rate-limit zone for the HAPP /sub/ location.
# Used by both the IP-mode vhost and the self-steal backend (domain mode).
limit_req_zone $binary_remote_addr zone=xraytailscale_sub:10m rate=30r/m;
ZONE_EOF
}

install_subscription_server() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}     HAPP SUBSCRIPTION SERVER SETUP           ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""

  if ! ensure_xray_runtime_user; then
    return 1
  fi
  chmod 755 /usr/local/bin/xraytailscale 2>/dev/null || true
  _cleanup_legacy_subscription_artifacts
  _subscription_ensure_limit_zone

  # Pre-flight: socat (handler bind), openssl/base64/jq уже гарантированы install.sh.
  if ! command -v socat &>/dev/null; then
    echo -e "${CYAN}  → Installing socat...${NC}"
    if ! apt-get install -y socat >/dev/null 2>&1; then
      echo -e "${RED}✗ Could not install socat${NC}"
      echo -e "${YELLOW}Install manually: apt-get install -y socat${NC}"
      return 1
    fi
    echo -e "${GREEN}  ✓ socat installed${NC}"
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
# base64-список (v2ray-sub) — для клиентов, которые ждут именно base64-список
# и НЕ парсят сырой vless://-текст с HAPP-заголовками:
#   - v2rayNG / v2rayN (классика), Karing (sing-box), sing-box, Streisand, FoXray.
# HAPP (happ://...) читает text-ветку ниже — туда Karing НЕ входит.
if [[ "$query_lc" == *"format=v2ray"* || "$query_lc" == *"format=base64"* \
   || "$query_lc" == *"client=v2rayng"* || "$query_lc" == *"client=karing"* \
   || "$query_lc" == *"client=sing-box"* \
   || "$ua_lc" == *"v2rayng"* || "$ua_lc" == *"v2rayn"* \
   || "$ua_lc" == *"karing"* || "$ua_lc" == *"sing-box"* \
   || "$ua_lc" == *"singbox"* || "$ua_lc" == *"streisand"* \
   || "$ua_lc" == *"foxray"* || "$ua_lc" == *"clash"* ]]; then
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
    echo -e "${RED}✗ Generated /usr/local/bin/subhttp.sh fails bash -n${NC}"
    return 1
  fi
  echo -e "${GREEN}  ✓ /usr/local/bin/subhttp.sh created${NC}"

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
    echo -e "${GREEN}  ✓ /usr/local/etc/xray/.happ_defaults.env created${NC}"
  else
    echo -e "${YELLOW}  ⚠ /usr/local/etc/xray/.happ_defaults.env already exists — leaving it${NC}"
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

# Restart=always, а не on-failure: socat получает SIGTERM при обрыве управляющего
# процесса (например, внешний timeout поверх меню), и «чистое» завершение по
# сигналу не должно оставлять подписку мёртвой.
# StartLimitIntervalSec=0 отключает отказ после серии быстрых рестартов:
# иначе 5 SIGTERM подряд за 2 секунды уводили сервис в StartLimit, и подписка
# молча отдавал 502 до ручного reset-failed. Реальную порочность бинарника
# всё равно разрежает RestartSec=5.
Restart=always
RestartSec=5
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
SUBUNIT_EOF

  chmod 644 /etc/systemd/system/xraytailscale-sub.service
  chown root:root /etc/systemd/system/xraytailscale-sub.service
  echo -e "${GREEN}  ✓ /etc/systemd/system/xraytailscale-sub.service created${NC}"

  # daemon-reload — чтобы systemctl увидел новый unit. НЕ enable, НЕ start.
  systemctl daemon-reload 2>/dev/null || true

  # Marker (opt-in активирован) — Plan 7.3 проверит наличие для меню/preflight.
  touch /usr/local/etc/xray/.subscription_installed
  chown xray:xray /usr/local/etc/xray/.subscription_installed 2>/dev/null || true

  echo ""
  echo -e "${YELLOW}  ⚠ Unit created but NOT started and NOT enabled.${NC}"
  echo -e "${YELLOW}    Start/enable is done by the menu (after public TLS is set up).${NC}"
  echo ""
  return 0
}

# ═══════════════════════════════════════════════════════════
# Phase 7 Plan 7.3 — public TLS / local-only / port preflight
# ═══════════════════════════════════════════════════════════
# Свободный внешний порт для HAPP-подписки, когда :443 занят.
# Кандидаты совпадают с _selfsteal_pick_backend_port (85-selfsteal.sh).
# Порт занят, если ss -tln показывает listener (любой адрес) ИЛИ порт
# совпадает с self-steal backend (файл SELFSTEAL_PORT_FILE): backend
# слушает 127.0.0.1:<port>, но коллизия с nginx listen <port> ssl на
# 0.0.0.0 всё равно фатальна для nginx -t/reload (реальный инцидент).
# stdout: первый свободный порт. return 1 + stderr, если все заняты.
_subscription_find_free_port() {
  local p
  local selfsteal_port_file="${SELFSTEAL_PORT_FILE:-/usr/local/etc/xray/.selfsteal_backend_port}"
  local selfsteal_backend=""
  selfsteal_backend=$(cat "$selfsteal_port_file" 2>/dev/null || true)
  for p in 8443 9443 10443 11443 12443; do
    if ss -tlnH "sport = :$p" 2>/dev/null | grep -q .; then
      continue
    fi
    if [[ -n "$selfsteal_backend" && "$p" == "$selfsteal_backend" ]]; then
      continue
    fi
    echo "$p"
    return 0
  done
  echo -e "${RED}✗ No free port for the subscription in 8443–12443${NC}" >&2
  return 1
}

# Public HTTPS port preflight. Эхает 443 если порт свободен, иначе первый
# свободный из _subscription_find_free_port (НЕ хардкод 8443 — он может
# быть занят self-steal backend'ом или чужим сервисом).
# Если порт занят Xray inbound — предупреждение и fallback.
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
  local fallback
  if ! fallback=$(_subscription_find_free_port); then
    echo -e "${RED}✗ Port 443 is taken and no free fallback port${NC}" >&2
    return 1
  fi
  if echo "$listener" | grep -q "xray"; then
    echo -e "${YELLOW}  ⚠ Port 443 is taken by an Xray inbound — falling back to ${fallback}${NC}" >&2
  else
    echo -e "${YELLOW}  ⚠ Port 443 is taken by another process — falling back to ${fallback}${NC}" >&2
  fi
  echo "$fallback"
  return 0
}

# Внешний self-check подписки после установки (best-effort).
# curl на публичный URL (токен профиля, иначе базовый /sub/). При не-2xx/3xx —
# красная диагностика, но установка НЕ считается проваленной: return 0 всегда.
# $1 — имя HAPP-профиля (для sub_token), $2 — публичный порт.
_subscription_external_selfcheck() {
  local profile_name="$1" port="$2"
  local base token url code
  base=$(_subscription_base_url)
  token=$(jq -r '.sub_token // ""' "$PROFILES_DIR/$profile_name.json" 2>/dev/null)
  if [[ "$token" =~ ^[a-f0-9]{32}$ ]]; then
    url="${base}/sub/${token}"
  else
    url="${base}/sub/"
  fi
  echo -e "${CYAN}  → Checking the subscription from outside: ${url}${NC}"
  code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)
  [[ -z "$code" ]] && code="000"
  if [[ "$code" =~ ^[23] ]]; then
    echo -e "${GREEN}  ✓ Subscription verified from outside: HTTP ${code}${NC}"
    return 0
  fi
  echo -e "${RED}╔═══════════════════════════════════════════════${NC}"
  echo -e "${RED}  ✗ SUBSCRIPTION NOT RESPONDING FROM OUTSIDE (HTTP ${code})${NC}"
  echo -e "${RED}╚═══════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}  What to check on the server:${NC}"
  echo -e "${YELLOW}    ss -tlnp | grep ${port}   — is nginx listening on the port${NC}"
  echo -e "${YELLOW}    ufw status | grep ${port} — is the port open in the firewall${NC}"
  echo -e "${YELLOW}    nginx -t                  — is the nginx config valid${NC}"
  echo -e "${YELLOW}  Run diagnostics from the subscription menu.${NC}"
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
    echo -e "${CYAN}  → Using the existing multi-route profile: ${GREEN}${existing}${NC}"
    return 0
  fi

  local profile_name
  profile_name=$(_happ_next_default_profile_name)
  echo -e "${CYAN}  → Creating HAPP profile '${profile_name}' with 7 routes...${NC}"
  if ! create_profile_all_routes "$profile_name" "no_pause" "hide_subscription"; then
    echo -e "${RED}✗ Could not create the HAPP multi-route profile${NC}"
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
  echo -e "${CYAN}  → Restoring the HAPP subscription handler...${NC}"
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
    echo -e "${YELLOW}  Local HTTP status: ${SUBSCRIPTION_SELFTEST_HTTP_STATUS}${NC}"
  fi
  if [[ -n "${SUBSCRIPTION_SELFTEST_ERROR:-}" ]]; then
    echo -e "${YELLOW}  curl: ${SUBSCRIPTION_SELFTEST_ERROR}${NC}"
  fi
  if [[ -n "${SUBSCRIPTION_SELFTEST_BODY:-}" ]]; then
    echo -e "${YELLOW}  Handler response: ${SUBSCRIPTION_SELFTEST_BODY}${NC}"
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
    echo -e "${YELLOW}  ⚠ Profile ${profile_name} has no valid sub_token — URL not shown${NC}"
    return 1
  fi

  url="$(_subscription_base_url)/sub/${token}"
  echo ""
  echo -e "${GREEN}═══ READY HAPP SUBSCRIPTION URL ═══${NC}"
  echo -e "${BLUE}Profile:${NC} ${GREEN}${profile_name}${NC}"
  if ! _subscription_ensure_profile_ready "$token"; then
    echo -e "${RED}✗ HAPP subscription handler is not serving the local subscription.${NC}"
    echo -e "${YELLOW}  An external client will get 502 Bad Gateway until 127.0.0.1:8080 comes up.${NC}"
    _subscription_print_selftest_failure
    echo -e "${YELLOW}  Diagnostics: systemctl status xraytailscale-sub --no-pager -l${NC}"
    echo -e "${YELLOW}  Logs: journalctl -u xraytailscale-sub -n 80 --no-pager${NC}"
    echo ""
    return 1
  fi

  if _subscription_is_local_only; then
    echo -e "${YELLOW}Local-only debug URL:${NC} ${url}"
    echo -e "${RED}QR is not shown: 127.0.0.1 is reachable from the VPS/SSH tunnel only, not from a phone.${NC}"
  else
    echo -e "${BLUE}URL:${NC} ${GREEN}${url}${NC}"
    _print_qr_block "$url"
  fi
  echo ""
  return 0
}

install_subscription_ip_tls() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}    SET UP VPS IP SUBSCRIPTION (HTTPS)      ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${CYAN}Default mode: an external HAPP client gets https://<IP>/sub/<token>${NC}"
  echo -e "${YELLOW}Let's Encrypt IP certificates are short-lived (~6 days); a working renew is required.${NC}"
  echo ""

  echo -e "${CYAN}  → Checking the HAPP subscription handler...${NC}"
  install_subscription_server || return 1

  local server_ip
  server_ip=$(get_server_ip)
  if [[ -z "$server_ip" || ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}✗ Could not determine the VPS public IPv4: ${server_ip:-empty}${NC}"
    echo -e "${YELLOW}IPv6 IP-cert mode is not automated yet — use a domain.${NC}"
    sleep 3
    return 1
  fi
  echo -e "${CYAN}  → VPS IPv4: ${server_ip}${NC}"

  local email
  # Обратно-совместимый override: мастер (src/56-wizard.sh) спрашивает email
  # один раз и выставляет SUBSCRIPTION_LE_EMAIL перед вызовом — тогда prompt
  # пропускается, но валидация остаётся той же.
  if [[ -n "${SUBSCRIPTION_LE_EMAIL:-}" ]]; then
    email="$SUBSCRIPTION_LE_EMAIL"
    echo -e "${CYAN}  → Let's Encrypt email (from the wizard): ${email}${NC}"
  else
    echo -n -e "${YELLOW}Let's Encrypt email (renew/account notices): ${NC}"
    read -r email
  fi
  if [[ -z "$email" ]] || ! [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    echo -e "${RED}✗ Invalid email${NC}"
    sleep 2
    return 1
  fi

  local pub_port
  if ! pub_port=$(_select_subscription_port); then
    echo -e "${RED}✗ No free port for the subscription (8443–12443 are taken)${NC}"
    echo -e "${YELLOW}  Free one of the ports in 8443–12443 and re-run the install.${NC}"
    return 1
  fi
  echo -e "${CYAN}  → Subscription HTTPS port: $pub_port${NC}"

  echo -e "${CYAN}  → Installing nginx...${NC}"
  if ! apt-get install -y nginx >/dev/null 2>&1; then
    echo -e "${RED}✗ apt-get install nginx failed${NC}"
    return 1
  fi

  local certbot_bin
  if ! _ensure_certbot_ip_tls; then
    echo -e "${YELLOW}Certbot 5.4+ is required for webroot IP certificates.${NC}"
    echo -e "${YELLOW}Use domain mode for now or update certbot from a current source.${NC}"
    return 1
  fi
  certbot_bin="$CERTBOT_IP_BIN"
  echo -e "${GREEN}  ✓ Certbot with IP support: ${certbot_bin}${NC}"

  local webroot="/var/www/xraytailscale-ip-acme"
  mkdir -p "$webroot/.well-known/acme-challenge"
  chmod -R 755 "$webroot"

  cat > /etc/nginx/sites-available/xraytailscale-sub << NGINX_HTTP_EOF
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
    echo -e "${RED}✗ nginx did not start. Check if port 80 is taken by another service.${NC}"
    return 1
  fi
  if ! systemctl reload nginx >/dev/null 2>&1; then
    echo -e "${RED}✗ nginx did not reload the HTTP config for the ACME challenge${NC}"
    return 1
  fi

  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw limit 80/tcp >/dev/null 2>&1
    ufw limit "${pub_port}/tcp" >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
    echo -e "${GREEN}  ✓ UFW: limit 80/tcp + ${pub_port}/tcp${NC}"
  fi

  echo -e "${CYAN}  → Running certbot IP certificate for ${server_ip}...${NC}"
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
    echo -e "${RED}✗ certbot could not issue the IP certificate. Log: /tmp/certbot-ip.log${NC}"
    tail -30 /tmp/certbot-ip.log
    echo -e "${YELLOW}Check that port 80 is reachable from outside and the VPS IP matches.${NC}"
    return 1
  fi
  systemctl reset-failed certbot.service 2>/dev/null || true

  local cert_dir="/etc/letsencrypt/live/${server_ip}"
  if [[ ! -f "$cert_dir/fullchain.pem" || ! -f "$cert_dir/privkey.pem" ]]; then
    echo -e "${RED}✗ certbot finished but cert files were not found: $cert_dir${NC}"
    return 1
  fi

  cat > /etc/nginx/sites-available/xraytailscale-sub << NGINX_TLS_EOF
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
    echo -e "${RED}✗ nginx did not reload the TLS config${NC}"
    return 1
  fi

  echo "$pub_port" > /usr/local/etc/xray/.subscription_port
  echo "$server_ip" > /usr/local/etc/xray/.subscription_domain
  echo "$server_ip" > /usr/local/etc/xray/.subscription_server_addr
  echo "ip_tls" > /usr/local/etc/xray/.subscription_mode
  chown xray:xray /usr/local/etc/xray/.subscription_port /usr/local/etc/xray/.subscription_domain /usr/local/etc/xray/.subscription_server_addr /usr/local/etc/xray/.subscription_mode 2>/dev/null || true

  if ! _subscription_restart_service; then
    echo -e "${RED}✗ xraytailscale-sub.service did not start — check journalctl -u xraytailscale-sub${NC}"
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
  echo -e "${GREEN}    ✓ VPS IP SUBSCRIPTION IS ACTIVE              ${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${BLUE}Base URL:${NC} ${GREEN}${_summary_base}${NC}"
  _happ_print_subscription_url_for_profile "$_happ_profile"
  # Best-effort внешний self-check (не валит установку при неудаче).
  _subscription_external_selfcheck "$_happ_profile" "$pub_port"
  echo -e "${CYAN}For manual route control use the main menu → 'Create new profile'.${NC}"
  echo ""
  echo -n -e "${YELLOW}Press Enter to continue...${NC}"
  read -r _ || true
}

# Public TLS installer by domain.
# Flow: domain prompt → DNS preflight (soft) → email prompt → port preflight
# → nginx HTTP-only ACME site on :80 → certbot certonly --webroot → explicit SSL
# nginx site on selected public port → markers → enable xraytailscale-sub.
# Важно: не используем certbot --nginx. Он плохо предсказуем на нестандартном
# HTTPS-порту (fallback идёт по списку 8443→9443→10443→11443→12443 через
# _subscription_find_free_port) и может оставить plain HTTP listener после
# failed certbot.
install_subscription_public_tls() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}    SET UP PUBLIC SUBSCRIPTION (HTTPS)      ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""

  # Pre-flight: всегда регенерируем handler/unit — это чинит старые partial updates.
  echo -e "${CYAN}  → Checking the HAPP subscription handler...${NC}"
  install_subscription_server || return 1

  # Domain prompt (M6: read -r — без -r теряются backslashes).
  # Автоподстановка: сохранённый серверный домен предлагается дефолтом.
  local domain saved_domain
  saved_domain=$(get_server_domain)
  if [[ -n "$saved_domain" ]]; then
    echo -n -e "${YELLOW}Enter the domain (A/AAAA must point to this VPS) [${CYAN}$saved_domain${YELLOW}]: ${NC}"
  else
    echo -n -e "${YELLOW}Enter the domain (A/AAAA must point to this VPS): ${NC}"
  fi
  read -r domain
  [[ -z "$domain" ]] && domain="$saved_domain"
  if [[ -z "$domain" ]] || ! [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo -e "${RED}✗ Invalid domain${NC}"
    sleep 2
    return 1
  fi
  # Сохраняем как серверный домен для self-steal и будущих настроек.
  set_server_domain "$domain" || true

  # DNS sanity-check (soft — warning + опция продолжить).
  # Rationale: split-DNS / Cloudflare proxied (orange-cloud) дают false-negatives.
  local server_ip resolved_ip
  server_ip=$(get_server_ip)
  resolved_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)
  if [[ -n "$resolved_ip" ]] && [[ "$resolved_ip" != "$server_ip" ]]; then
    echo -e "${YELLOW}  ⚠ DNS resolves $domain → $resolved_ip, but VPS IP = $server_ip${NC}"
    echo -e "${YELLOW}    certbot will most likely refuse. Continue? [y/N]${NC}"
    local cont
    read -r cont
    [[ "$cont" =~ ^[yYдД]$ ]] || return 1
  fi

  # Email prompt (для certbot --agree-tos -m).
  local email
  echo -n -e "${YELLOW}Let's Encrypt email (account recovery): ${NC}"
  read -r email
  if [[ -z "$email" ]] || ! [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    echo -e "${RED}✗ Invalid email${NC}"
    sleep 2
    return 1
  fi

  # Port preflight: 443 (default), иначе первый свободный fallback из
  # 8443→9443→10443→11443→12443 через _subscription_find_free_port.
  local pub_port
  if ! pub_port=$(_select_subscription_port); then
    echo -e "${RED}✗ No free port for the subscription (8443–12443 are taken)${NC}"
    echo -e "${YELLOW}  Free one of the ports in 8443–12443 and re-run the install.${NC}"
    return 1
  fi
  echo -e "${CYAN}  → Public port: $pub_port${NC}"

  echo -e "${CYAN}  → Installing nginx + certbot...${NC}"
  if ! apt-get install -y nginx certbot >/dev/null 2>&1; then
    echo -e "${RED}✗ apt-get install nginx certbot failed${NC}"
    return 1
  fi

  local certbot_bin
  if [[ -x /snap/bin/certbot ]]; then
    certbot_bin="/snap/bin/certbot"
  else
    certbot_bin=$(command -v certbot 2>/dev/null || true)
  fi
  if [[ -z "$certbot_bin" || ! -x "$certbot_bin" ]]; then
    echo -e "${RED}✗ certbot not found after install${NC}"
    return 1
  fi

  local webroot="/var/www/xraytailscale-domain-acme"
  mkdir -p "$webroot/.well-known/acme-challenge"
  chmod -R 755 "$webroot"

  cat > /etc/nginx/sites-available/xraytailscale-sub << NGINX_HTTP_EOF
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
    echo -e "${RED}✗ nginx did not start. Check if port 80 is taken by another service.${NC}"
    return 1
  fi
  if ! systemctl reload nginx >/dev/null 2>&1; then
    echo -e "${RED}✗ nginx did not reload the HTTP config for the ACME challenge${NC}"
    return 1
  fi

  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw limit 80/tcp >/dev/null 2>&1
    ufw limit "${pub_port}/tcp" >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
    echo -e "${GREEN}  ✓ UFW: limit 80/tcp + ${pub_port}/tcp${NC}"
  fi

  echo -e "${CYAN}  → Running certbot webroot for $domain...${NC}"
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
    echo -e "${RED}✗ certbot could not issue the certificate. Log: /tmp/certbot.log${NC}"
    tail -30 /tmp/certbot.log
    echo -e "${YELLOW}Check that port 80 is reachable from outside, DNS points to the VPS, or Cloudflare proxies the HTTP challenge.${NC}"
    return 1
  fi
  systemctl reset-failed certbot.service 2>/dev/null || true

  local cert_dir="/etc/letsencrypt/live/${domain}"
  if [[ ! -f "$cert_dir/fullchain.pem" || ! -f "$cert_dir/privkey.pem" ]]; then
    echo -e "${RED}✗ certbot finished but cert files were not found: $cert_dir${NC}"
    return 1
  fi

  cat > /etc/nginx/sites-available/xraytailscale-sub << NGINX_TLS_EOF
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
    echo -e "${RED}✗ nginx did not reload the TLS config${NC}"
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
    echo -e "${RED}✗ xraytailscale-sub.service did not start — check journalctl -u xraytailscale-sub${NC}"
    return 1
  fi

  local _happ_profile
  if ! _happ_ensure_default_multiroute_profile; then
    return 1
  fi
  _happ_profile="$HAPP_DEFAULT_PROFILE"

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}    ✓ PUBLIC SUBSCRIPTION IS ACTIVE              ${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════${NC}"
  echo ""
  # B1: shared helper — НЕ строим https://${domain} инлайн.
  local _summary_base
  _summary_base=$(_subscription_base_url)
  echo -e "${BLUE}URL:${NC} ${GREEN}${_summary_base}${NC} (port ${pub_port})"
  _happ_print_subscription_url_for_profile "$_happ_profile"
  # Best-effort внешний self-check (не валит установку при неудаче).
  _subscription_external_selfcheck "$_happ_profile" "$pub_port"
  echo -e "${CYAN}For manual route control use the main menu → 'Create new profile'.${NC}"
  echo ""
  echo -n -e "${YELLOW}Press Enter to continue...${NC}"
  read -r _ || true
}

# Local-only fallback installer (REQ-C03).
# Без nginx, без certbot, БЕЗ открытия UFW (loopback bypasses firewall).
# Доступ — только через ssh-tunnel: ssh -L 8080:127.0.0.1:8080 user@vps.
# ═══════════════════════════════════════════════════════════
# Подписка по ДОМЕНУ self-steal (на том же :443, без порта)
# ═══════════════════════════════════════════════════════════
# Self-steal уже обслуживает домен на :443 с валидным LE-сертификатом:
# Xray (Reality) → dest → 127.0.0.1:<backend> → nginx с decoy-сайтом.
# Поэтому подписку можно отдавать ТЕМ ЖЕ доменом на том же :443, без
# отдельного порта и без нового сертификата:
#
#   https://<domain>/sub/<token>
#
# Реализация — location ^~ /sub/ в backend-виртуальном сервере self-steal.
# НИКАКОГО второго server_name <domain> на :80: именно это раньше ломало
# продление сертификатов (дублирующий server_name затенял ACME webroot).
# ACME продолжает обслуживать только self-steal вебрут.
#
# $1 — домен (опционально; по умолчанию читается из .selfsteal_domain).
install_subscription_selfsteal_domain() {
  local domain="${1:-}"
  if [[ -z "$domain" ]]; then
    domain=$(cat "${SELFSTEAL_DOMAIN_FILE:-/usr/local/etc/xray/.selfsteal_domain}" 2>/dev/null || true)
  fi
  if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo -e "${RED}✗ Self-steal domain not found — cannot enable domain subscription${NC}"
    echo -e "${YELLOW}  Run the self-steal setup first (wizard), or use IP mode.${NC}"
    return 1
  fi

  local backend_port
  backend_port=$(cat "${SELFSTEAL_PORT_FILE:-/usr/local/etc/xray/.selfsteal_backend_port}" 2>/dev/null || true)
  if [[ ! "$backend_port" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}✗ Self-steal backend port is unknown — is self-steal configured?${NC}"
    return 1
  fi

  local vhost="${SELFSTEAL_NGINX_AVAILABLE:-/etc/nginx/sites-available/xraytailscale-selfsteal.conf}"
  if [[ ! -f "$vhost" ]]; then
    echo -e "${RED}✗ nginx self-steal config not found: $vhost${NC}"
    return 1
  fi

  echo -e "${CYAN}  → Enabling domain subscription: https://${domain}/sub/<token>${NC}"
  echo -e "${CYAN}    (same :443 and the same LE certificate as the decoy site)${NC}"

  # 1) Гарантируем, что handler и unit на месте.
  if ! install_subscription_server >/dev/null 2>&1; then
    echo -e "${RED}✗ Could not prepare the subscription handler${NC}"
    return 1
  fi

  # 2) Вставляем location /sub/ в backend-блок, если его ещё нет.
  #    Идемпотентно: повторный запуск не дублирует блок.
  if grep -q 'location \^~ /sub/' "$vhost"; then
    echo -e "${CYAN}  → /sub/ location already present — keeping the existing config${NC}"
  else
    local backup="/tmp/xraytailscale-sub-vhost.$(date +%Y%m%d_%H%M%S).bak"
    cp "$vhost" "$backup" || { echo -e "${RED}✗ Could not back up $vhost${NC}"; return 1; }
    # Безопасная вставка через Python: правим ТОЛЬКО backend-блок
    # (listen 127.0.0.1:<backend_port> ssl), не трогая HTTP-блок на :80.
    if ! python3 - "$vhost" "$backend_port" <<'PYEOF'
import sys, re
path, port = sys.argv[1], sys.argv[2]
src = open(path).read()
marker = "location ^~ /sub/"
if marker in src:
    sys.exit(0)
# Ищем именно TLS-backend-блок: listen 127.0.0.1:<port> ssl.
pattern = re.compile(r'(listen 127\.0\.0\.1:' + re.escape(port) + r' ssl;.*?)(\n\}\n)', re.S)
m = pattern.search(src)
if not m:
    sys.stderr.write("backend TLS block not found for port %s\n" % port)
    sys.exit(1)
sub_block = '''
    # HAPP subscription: same domain, same LE certificate, no extra port.
    location ^~ /sub/ {
        access_log off;
        limit_req zone=xraytailscale_sub burst=10 nodelay;
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow, nosnippet" always;
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
'''
src = src[:m.end(1)] + sub_block + src[m.end(1):]
open(path, "w").write(src)
PYEOF
    then
      cp "$backup" "$vhost"
      echo -e "${RED}✗ Could not inject the /sub/ location — config rolled back${NC}"
      return 1
    fi
    if ! grep -q 'location \^~ /sub/' "$vhost"; then
      cp "$backup" "$vhost"
      echo -e "${RED}✗ /sub/ location was not added — config rolled back${NC}"
      return 1
    fi
    if ! nginx -t >/tmp/nginx-xraytailscale-sub.log 2>&1; then
      cp "$backup" "$vhost"
      nginx -t >/dev/null 2>&1 || true
      echo -e "${RED}✗ nginx -t failed after injection — config rolled back${NC}"
      cat /tmp/nginx-xraytailscale-sub.log
      return 1
    fi
    if ! systemctl reload nginx >/dev/null 2>&1; then
      cp "$backup" "$vhost"
      systemctl reload nginx >/dev/null 2>&1 || true
      echo -e "${RED}✗ nginx could not reload — config rolled back${NC}"
      return 1
    fi
    rm -f "$backup"
    echo -e "${GREEN}  ✓ /sub/ is served on the self-steal backend (:443)${NC}"
  fi

  # 3) Отключаем внешний TLS-виртуалхост IP-режима, если он был: он больше
  #    не нужен (и его короткоживущий IP-сертификат не нужно продлевать).
  if [[ -f /etc/nginx/sites-enabled/xraytailscale-sub ]]; then
    rm -f /etc/nginx/sites-enabled/xraytailscale-sub
    if ! nginx -t >/dev/null 2>&1; then
      echo -e "${RED}✗ nginx -t failed after disabling the IP vhost${NC}"
      return 1
    fi
    systemctl reload nginx >/dev/null 2>&1 || true
    echo -e "${CYAN}  → IP-mode vhost disabled (domain mode replaces it)${NC}"
  fi

  # 4) Маркеры: домен, порт 443 (→ URL без порта), режим domain_tls.
  #    Пишем ТОЛЬКО после успешного nginx -t + reload.
  echo "$domain" > /usr/local/etc/xray/.subscription_domain
  echo "443" > /usr/local/etc/xray/.subscription_port
  get_server_ip > /usr/local/etc/xray/.subscription_server_addr 2>/dev/null || true
  echo "domain_tls" > /usr/local/etc/xray/.subscription_mode
  chown xray:xray /usr/local/etc/xray/.subscription_port /usr/local/etc/xray/.subscription_domain \
    /usr/local/etc/xray/.subscription_server_addr /usr/local/etc/xray/.subscription_mode 2>/dev/null || true

  # 5) Запускаем handler (loopback :8080) и проверяем его.
  if ! _subscription_restart_service; then
    echo -e "${RED}✗ xraytailscale-sub.service failed to start — check journalctl -u xraytailscale-sub${NC}"
    return 1
  fi

  local _happ_profile
  if ! _happ_ensure_default_multiroute_profile; then
    return 1
  fi
  _happ_profile="$HAPP_DEFAULT_PROFILE"

  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}    ✓ DOMAIN SUBSCRIPTION IS ACTIVE           ${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}Base URL:${NC} ${GREEN}https://${domain}${NC}"
  _happ_print_subscription_url_for_profile "$_happ_profile"

  # Внешняя проверка ТЕМ ЖЕ доменом — это доказательство, что URL рабочий.
  local token url code
  token=$(jq -r '.sub_token // ""' "$PROFILES_DIR/$_happ_profile.json" 2>/dev/null || true)
  if [[ "$token" =~ ^[a-f0-9]{32}$ ]]; then
    url="https://${domain}/sub/${token}"
    code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
    [[ -z "$code" ]] && code="000"
    if [[ "$code" == "200" ]]; then
      echo -e "${GREEN}  ✓ External check: ${url} → HTTP 200 (valid certificate)${NC}"
    else
      echo -e "${YELLOW}  ⚠ External check: ${url} → HTTP ${code}${NC}"
      echo -e "${YELLOW}    Check: nginx -t && systemctl reload nginx; ss -tlnp | grep :443${NC}"
    fi
  fi
  echo ""
  echo -n -e "${YELLOW}Press Enter to continue...${NC}"
  read -r _ || true
  return 0
}

install_subscription_local_only() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}    SET UP SUBSCRIPTION (LOCAL-ONLY FALLBACK) ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${YELLOW}⚠ Subscriptions are only available locally (127.0.0.1:8080).${NC}"
  echo -e "${YELLOW}  Access via ssh-tunnel: ssh -L 8080:127.0.0.1:8080 user@vps${NC}"
  echo ""

  install_subscription_server || return 1

  echo "8080" > /usr/local/etc/xray/.subscription_port
  echo "127.0.0.1" > /usr/local/etc/xray/.subscription_domain
  get_server_ip > /usr/local/etc/xray/.subscription_server_addr 2>/dev/null || true
  echo "local_only" > /usr/local/etc/xray/.subscription_mode
  chown xray:xray /usr/local/etc/xray/.subscription_port /usr/local/etc/xray/.subscription_domain /usr/local/etc/xray/.subscription_server_addr /usr/local/etc/xray/.subscription_mode 2>/dev/null || true

  if ! _subscription_restart_service; then
    echo -e "${RED}✗ xraytailscale-sub.service did not start${NC}"
    return 1
  fi

  local _happ_profile
  if ! _happ_ensure_default_multiroute_profile; then
    return 1
  fi
  _happ_profile="$HAPP_DEFAULT_PROFILE"

  echo ""
  echo -e "${GREEN}✓ Local-only handler started on 127.0.0.1:8080${NC}"
  echo -e "${CYAN}  UFW: port NOT opened (loopback bypass).${NC}"
  _happ_print_subscription_url_for_profile "$_happ_profile"
  echo ""
  echo -n -e "${YELLOW}Press Enter to continue...${NC}"
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
  echo -e "${BLUE}    MANAGE SUBSCRIPTION                      ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""

  if [[ ! -f /usr/local/etc/xray/.subscription_installed ]]; then
    echo -e "${RED}✗ Subscription is not installed. Create it under More → HAPP subscription.${NC}"
    sleep 2
    return
  fi

  # B1: base URL ВСЕГДА через shared helper (Plan 7.2). НЕТ инлайн-построения.
  local base_url
  base_url=$(_subscription_base_url)
  local local_only=false
  if _subscription_is_local_only; then
    local_only=true
    echo -e "${RED}⚠ The subscription is currently local-only: ${base_url}${NC}"
    echo -e "${YELLOW}  This URL does NOT work from a phone/external client. Enable public TLS in the subscription menu.${NC}"
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
    echo -e "${YELLOW}⚠ No profiles.${NC}"
    if [[ "$stale_count" -gt 0 ]]; then
      echo -e "${RED}  Found stale profile JSON: $stale_count. Their ports are absent from the live config.json.${NC}"
    fi
    sleep 2
    return
  fi
  if [[ "$stale_count" -gt 0 ]]; then
    echo -e "${YELLOW}⚠ Hidden stale profiles: $stale_count (their ports are no longer listened by Xray).${NC}"
    echo ""
  fi

  echo -e "${YELLOW}Choose a profile:${NC}"
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
  echo -e "${CYAN} 0)${NC} Back"
  echo ""
  echo -n -e "${YELLOW}Profile: ${NC}"
  local choice
  read -r choice
  [[ "$choice" == "0" ]] && return
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#profiles[@]} ]]; then
    echo -e "${RED}✗ Invalid choice${NC}"
    sleep 2
    return
  fi

  local selected="${profiles[$((choice-1))]}"
  local pfile="$PROFILES_DIR/${selected}.json"
  local token
  token=$(jq -r '.sub_token // ""' "$pfile" 2>/dev/null)
  if [[ ! "$token" =~ ^[a-f0-9]{32}$ ]]; then
    echo -e "${RED}✗ The profile has no valid sub_token. Run 'sudo xraytailscale' — the .subscription_tokens_2026 migration will generate it.${NC}"
    sleep 3
    return
  fi

  while true; do
    show_ascii
    local url="${base_url}/sub/${token}"
    echo -e "${BLUE}═══ Profile: ${selected} ═══${NC}"
    echo ""
    if [[ "$local_only" == "true" ]]; then
      echo -e "${YELLOW}Local-only debug URL:${NC}"
      echo -e "  ${YELLOW}$url${NC}"
      echo -e "${RED}  Do not QR-code for a phone: 127.0.0.1 on the client points to the client itself.${NC}"
    else
      echo -e "${BLUE}Subscription URL:${NC}"
      echo -e "  ${GREEN}$url${NC}"
    fi
    echo ""
    if [[ "$local_only" == "true" ]]; then
      echo -e "${CYAN} 1)${NC} Enable public TLS on the VPS IP for an external subscription"
    else
      echo -e "${CYAN} 1)${NC} Show the subscription URL QR code"
    fi
    echo -e "${CYAN} 2)${NC} Revoke (generate a new sub_token)"
    echo -e "${CYAN} 3)${NC} Show raw vless:// (advanced)"
    echo -e "${CYAN} 0)${NC} Back"
    echo ""
    echo -n -e "${YELLOW}Choose: ${NC}"
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
            _print_qr_block "$url"
          else
            echo -e "${RED}✗ HAPP subscription handler is not responding locally.${NC}"
            echo -e "${YELLOW}  An external client will currently get 502 Bad Gateway.${NC}"
            _subscription_print_selftest_failure
            echo -e "${YELLOW}  Check: systemctl status xraytailscale-sub --no-pager -l${NC}"
            echo -e "${YELLOW}  Logs: journalctl -u xraytailscale-sub -n 80 --no-pager${NC}"
            echo ""
            echo -n -e "${YELLOW}Press Enter to continue...${NC}"
            read -r _
          fi
        fi
        ;;
      2)
        # Revoke — генерируем новый 32-hex sub_token, пишем через safe_jq_write.
        # Рестарт subhttp НЕ нужен: handler читает .sub_token из profile JSON на каждый request.
        local new_token
        new_token=$(openssl rand -hex 16)
        if [[ ! "$new_token" =~ ^[a-f0-9]{32}$ ]]; then
          echo -e "${RED}✗ Could not generate the token${NC}"
          sleep 2
          continue
        fi
        if ! safe_jq_write --arg t "$new_token" '.sub_token = $t' "$pfile"; then
          echo -e "${RED}✗ Writing to the profile JSON failed${NC}"
          sleep 2
          continue
        fi
        chown xray:xray "$pfile" 2>/dev/null || true
        token="$new_token"
        echo -e "${GREEN}✓ New sub_token. The old URL no longer works.${NC}"
        echo -e "${CYAN}  New URL: ${base_url}/sub/${token}${NC}"
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
          echo -e "${RED}✗ Could not build vless://${NC}"
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
          echo -e "${RED}  ✗ QR not generated: PQ profile (encryption=mlkem... ~2KB).${NC}"
          echo -e "${YELLOW}  PQ vless:// lines are unreadable as a QR code.${NC}"
          echo -e "${YELLOW}  Use the subscription URL/QR (option 1 — short HTTPS link).${NC}"
          echo ""
          echo -n -e "${YELLOW}Press Enter to continue...${NC}"
          read -r _
        else
          echo -e "${GREEN}  → legacy profile (no PQ) — QR is fine${NC}"
          _print_qr_block "$raw"
        fi
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
    echo -e "${RED}✗ $env_file does not exist — set up the subscription first.${NC}"
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
    echo -e "${BLUE}    HAPP METADATA SETTINGS                   ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN} 1)${NC} HAPP_SERVER_NAME = ${YELLOW}${HAPP_SERVER_NAME:-(profile name)}${NC}"
    echo -e "${CYAN} 2)${NC} HAPP_SUPPORT_URL = ${YELLOW}${HAPP_SUPPORT_URL:-(not set)}${NC}"
    echo -e "${CYAN} 3)${NC} HAPP_WEB_URL = ${YELLOW}${HAPP_WEB_URL:-(not set)}${NC}"
    echo -e "${CYAN} 4)${NC} HAPP_PROFILE_UPDATE_INTERVAL = ${YELLOW}${HAPP_PROFILE_UPDATE_INTERVAL:-24}${NC} hours"
    echo -e "${CYAN} 5)${NC} HAPP_ANNOUNCE_FILE = ${YELLOW}${HAPP_ANNOUNCE_FILE:-(not set)}${NC}"
    echo -e "${CYAN} 6)${NC} HAPP_ROUTING_JSON_FILE = ${YELLOW}${HAPP_ROUTING_JSON_FILE:-(not set)}${NC}"
    echo -e "${CYAN} 0)${NC} Back"
    echo ""
    echo -n -e "${YELLOW}Change (1-6, 0=back): ${NC}"
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
      *) echo -e "${RED}✗ Invalid choice${NC}"; sleep 1 ;;
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
  echo -n -e "${YELLOW}New value for ${key} (Enter=keep '${current}'): ${NC}"
  local new_val
  read -r new_val
  [[ -z "$new_val" ]] && return 0   # пользователь отменил
  if [[ "$new_val" =~ [\"\\\$\`] ]]; then
    echo -e "${RED}✗ The value cannot contain the characters \" \\ \$ \`${NC}"
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
    echo -e "${RED}✗ Temporary file is empty — cancelled${NC}"
    return 1
  fi
  mv "$tmp" "$env_file"
  chmod 644 "$env_file"
  chown xray:xray "$env_file" 2>/dev/null || true
  echo -e "${GREEN}✓ ${key} updated (no subhttp restart needed — sourced on each request)${NC}"
  if [[ -f /usr/local/etc/xray/.subscription_installed ]]; then
    if install_subscription_server >/dev/null 2>&1; then
      echo -e "${GREEN}subscription handler regenerated${NC}"
    else
      echo -e "${YELLOW}Subscription handler regeneration failed — reinstall the subscription via the menu${NC}"
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
    echo -e "${BLUE}    HAPP ANNOUNCEMENT (subscription text)         ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo ""

    if [[ -s "$ann_file" ]]; then
      echo -e "${GREEN}Current announcement:${NC}"
      head -c 200 "$ann_file"
      echo ""
      echo ""
    else
      echo -e "${YELLOW}Announcement not set (no HAPP header)${NC}"
      echo ""
    fi

    echo -e "${CYAN} 1)${NC} Set/change the text"
    echo -e "${CYAN} 2)${NC} Clear (remove the announcement)"
    echo -e "${CYAN} 0)${NC} Back"
    echo ""
    echo -n -e "${YELLOW}Choose: ${NC}"
    local choice
    read -r choice

    case "$choice" in
      1)
        echo -e "${YELLOW}Enter a single-line text (~200 char max, no newlines):${NC}"
        echo -n -e "${CYAN}> ${NC}"
        local new_text
        read -r new_text
        new_text="${new_text:0:200}"
        new_text="${new_text//$'\n'/}"
        new_text="${new_text//$'\r'/}"
        if [[ -z "$new_text" ]]; then
          rm -f "$ann_file"
          echo -e "${GREEN}Announcement cleared${NC}"
        else
          echo -n -e "${YELLOW}Save '${new_text}'? [y/N]: ${NC}"
          local confirm
          read -r confirm
          if [[ "$confirm" =~ ^[yYдД]$ ]]; then
            local tmp
            tmp=$(mktemp /tmp/announce.XXXXXX) || {
              echo -e "${RED}✗ mktemp failed${NC}"
              echo -n -e "${YELLOW}Press Enter to continue...${NC}"
              read -r _
              continue
            }
            printf '%s' "$new_text" > "$tmp"
            mv "$tmp" "$ann_file"
            chown xray:xray "$ann_file" 2>/dev/null || true
            chmod 644 "$ann_file"
            echo -e "${GREEN}Announcement saved to $ann_file${NC}"
          else
            echo -e "${CYAN}✓ Cancelled${NC}"
          fi
        fi
        if [[ -f /usr/local/etc/xray/.subscription_installed ]]; then
          if install_subscription_server >/dev/null 2>&1; then
            echo -e "${GREEN}subhttp.sh regenerated with announce logic${NC}"
          else
            echo -e "${YELLOW}subhttp.sh regeneration failed — reinstall the subscription via the menu${NC}"
          fi
        fi
        echo -n -e "${YELLOW}Press Enter to continue...${NC}"
        read -r _
        ;;
      2)
        rm -f "$ann_file"
        echo -e "${GREEN}Announcement cleared${NC}"
        if [[ -f /usr/local/etc/xray/.subscription_installed ]]; then
          if install_subscription_server >/dev/null 2>&1; then
            echo -e "${GREEN}subhttp.sh regenerated without announcement${NC}"
          else
            echo -e "${YELLOW}subhttp.sh regeneration failed — reinstall the subscription via the menu${NC}"
          fi
        fi
        echo -n -e "${YELLOW}Press Enter to continue...${NC}"
        read -r _
        ;;
      0) return ;;
      *) echo -e "${RED}Invalid choice${NC}"; sleep 1 ;;
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
        echo -e "${RED}    Not suitable for an external client. Enable public TLS (option 1).${NC}"
      else
        echo -e "${GREEN}  ✓ Public subscription (${_status_mode}): ${_status_url}${NC}"
      fi
      echo ""
    else
      echo -e "${YELLOW}  ⚠ Not installed${NC}"
      echo ""
    fi

    echo -e "${CYAN} 1)${NC} Create HAPP subscription on the VPS IP ${GREEN}(7 routes + URL/QR)${NC}"
    echo -e "${CYAN} 2)${NC} Create HAPP subscription on a domain ${GREEN}(7 routes + URL/QR)${NC}"
    echo -e "${CYAN} 3)${NC} Local-only debug (127.0.0.1:8080)"
    echo -e "${CYAN} 4)${NC} Manage existing subscriptions (URL / QR / revoke)"
    echo -e "${CYAN} 5)${NC} HAPP settings (.happ_defaults.env)"
    echo -e "${CYAN} 6)${NC} Configure announcement (HAPP)"
    echo -e "${CYAN} 0)${NC} Back"
    echo ""
    echo -n -e "${YELLOW}Choose: ${NC}"
    local c
    read -r c || return 0
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

