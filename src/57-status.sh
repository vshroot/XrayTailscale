# ═══════════════════════════════════════════════════════════
# Статус-экран настроенного сервера + диагностика с автопочинкой
# ═══════════════════════════════════════════════════════════
# Показывается, когда сервер уже настроен (мастер пройден, inbound'ы есть):
# компактная сводка здоровья из 7 строк + меню действий.
# Второй блок — diagnose_and_repair(): 7 типовых поломок, каждая с
# предложением автопочинки, перепроверкой и точными командами для ручной
# проверки, если автопочинка не помогла.
#
# Инварианты модуля:
#   - все внешние вызовы (ss/curl/openssl/ufw/nginx/systemctl/journalctl/
#     certbot/getent) защищены command -v; отсутствие утилиты — это ⚠/n-a,
#     а не падение (сервер без iproute2 обязан показывать статус);
#   - URL подписки строится ТОЛЬКО через _subscription_base_url (или чужой
#     хелпер _happ_print_subscription_url_for_profile) — своей склейки
#     схемы/хоста здесь нет;
#   - пути маркеров — через ${VAR:-default}: тесты подменяют их на /tmp,
#     прод всегда /usr/local/etc/xray/ (как в src/56-wizard.sh).

STATUS_SUB_MARKER="${STATUS_SUB_MARKER:-/usr/local/etc/xray/.subscription_installed}"
STATUS_SUB_PORT_FILE="${STATUS_SUB_PORT_FILE:-/usr/local/etc/xray/.subscription_port}"
STATUS_SUB_MODE_FILE="${STATUS_SUB_MODE_FILE:-/usr/local/etc/xray/.subscription_mode}"
STATUS_SUB_DOMAIN_FILE="${STATUS_SUB_DOMAIN_FILE:-/usr/local/etc/xray/.subscription_domain}"
STATUS_SELFSTEAL_DOMAIN_FILE="${STATUS_SELFSTEAL_DOMAIN_FILE:-/usr/local/etc/xray/.selfsteal_domain}"
STATUS_SELFSTEAL_PORT_FILE="${STATUS_SELFSTEAL_PORT_FILE:-/usr/local/etc/xray/.selfsteal_backend_port}"
STATUS_NGINX_SUB_SITE="${STATUS_NGINX_SUB_SITE:-/etc/nginx/sites-available/xraytailscale-sub}"
STATUS_LE_LIVE_DIR="${STATUS_LE_LIVE_DIR:-/etc/letsencrypt/live}"
STATUS_SUB_SERVICE="${STATUS_SUB_SERVICE:-xraytailscale-sub}"
# Число дней, ниже которого сертификат считается «скоро истечёт».
STATUS_CERT_WARN_DAYS="${STATUS_CERT_WARN_DAYS:-7}"

# ─── Мини-хелперы вывода ────────────────────────────────────
_status_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
_status_bad()  { echo -e "  ${RED}✗${NC} $*"; }
_status_warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }

_status_pause() {
  echo ""
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read -r _ || true
}

# ─── Чтение маркеров (безопасно к отсутствию файлов) ────────
_status_sub_port() {
  local port=""
  port=$(cat "$STATUS_SUB_PORT_FILE" 2>/dev/null || true)
  [[ "$port" =~ ^[0-9]+$ ]] || port=""
  printf '%s\n' "$port"
}

_status_selfsteal_backend_port() {
  local port=""
  port=$(cat "$STATUS_SELFSTEAL_PORT_FILE" 2>/dev/null || true)
  [[ "$port" =~ ^[0-9]+$ ]] || port=""
  printf '%s\n' "$port"
}

# stdout: строка listen из ss для порта (пусто = никто не слушает / нет ss).
_status_port_listener() {
  local port="${1:-}"
  command -v ss >/dev/null 2>&1 || return 0
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  ss -tlnpH "sport = :${port}" 2>/dev/null | head -1 || true
}

# stdout: имя процесса из строки ss (или «неизвестный процесс»).
_status_listener_process() {
  local line="${1:-}" name=""
  [[ -n "$line" ]] || { echo ""; return 0; }
  name=$(sed -nE 's/.*users:\(\("([^"]+)".*/\1/p' <<< "$line" | head -1)
  [[ -n "$name" ]] || name="неизвестный процесс"
  printf '%s\n' "$name"
}

# Есть ли inbound на :443 в config.json.
_status_has_443_inbound() {
  [[ -f "$CONFIG_FILE" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '.inbounds[]? | select(.port == 443)' "$CONFIG_FILE" >/dev/null 2>&1
}

# ─── Режим: self-steal (свой домен) или Reality по IP ───────
# Пишет _STATUS_MODE_KIND (selfsteal|ip) и _STATUS_MODE_DOMAIN.
# Признаки self-steal: маркер .selfsteal_domain ИЛИ dest 127.0.0.1:<port>
# у inbound :443 (Reality отправляет не-VLESS TLS на локальный nginx).
_status_detect_mode() {
  _STATUS_MODE_KIND="ip"
  _STATUS_MODE_DOMAIN=""

  local domain="" dest=""
  domain=$(cat "$STATUS_SELFSTEAL_DOMAIN_FILE" 2>/dev/null || true)
  if [[ -z "$domain" ]] && command -v jq >/dev/null 2>&1 && [[ -f "$CONFIG_FILE" ]]; then
    dest=$(jq -r '(.inbounds[]? | select(.port == 443) | .streamSettings.realitySettings.dest) // ""' \
      "$CONFIG_FILE" 2>/dev/null | head -1 || true)
    [[ "$dest" == 127.0.0.1:* ]] || dest=""
  fi

  if [[ -n "$domain" || -n "$dest" ]]; then
    _STATUS_MODE_KIND="selfsteal"
    [[ -n "$domain" ]] || domain=$(get_server_domain 2>/dev/null || true)
    _STATUS_MODE_DOMAIN="$domain"
  fi
  return 0
}

# ─── Сертификат: остаток дней ──────────────────────────────
# $1 = домен или IP. stdout: целое число дней (может быть отрицательным).
# return 1: файла нет / openssl нет / не удалось разобрать дату.
_status_cert_days() {
  local name="${1:-}" file="" end="" end_epoch="" now_epoch="" days=""
  [[ -n "$name" ]] || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  command -v date >/dev/null 2>&1 || return 1

  file="${STATUS_LE_LIVE_DIR}/${name}/fullchain.pem"
  [[ -f "$file" ]] || return 1

  end=$(openssl x509 -enddate -noout -in "$file" 2>/dev/null | sed -n 's/^notAfter=//p')
  [[ -n "$end" ]] || return 1

  # GNU date (Linux), затем BSD date (macOS — локальные прогоны тестов).
  end_epoch=$(date -d "$end" +%s 2>/dev/null || true)
  if [[ ! "$end_epoch" =~ ^[0-9]+$ ]]; then
    end_epoch=$(date -j -f "%b %e %T %Y %Z" "$end" +%s 2>/dev/null || true)
  fi
  [[ "$end_epoch" =~ ^[0-9]+$ ]] || return 1

  now_epoch=$(date +%s 2>/dev/null || true)
  [[ "$now_epoch" =~ ^[0-9]+$ ]] || return 1

  days=$(( (end_epoch - now_epoch) / 86400 ))
  printf '%s\n' "$days"
}

# ─── UFW: сводка по 80/443/порту подписки ──────────────────
# stdout: человекочитаемое состояние. return 0 всегда.
_status_ufw_state() {
  local sub_port="${1:-}"
  if ! command -v ufw >/dev/null 2>&1; then
    echo "не используется (ufw не установлен)"
    return 0
  fi
  local st=""
  st=$(ufw status 2>/dev/null || true)
  if ! grep -q "Status: active" <<< "$st"; then
    echo "не активен (iptables-правила проекта)"
    return 0
  fi

  local missing="" p
  for p in 80 443 ${sub_port:+"$sub_port"}; do
    [[ -n "$p" ]] || continue
    # ufw печатает как «8443/tcp», так и мульти-порты «80,443/tcp».
    # ALLOW и LIMIT оба пропускают трафик: LIMIT лишь ограничивает частоту
    # новых соединений (антискан на порту подписки и :80). Считать LIMIT
    # «правила нет» — ложная тревога, ведущая к лишней автопочинке.
    grep -qE "^([0-9]+,)*${p}(,[0-9]+)*/tcp[[:space:]]+(ALLOW|LIMIT)" <<< "$st" || \
      missing="${missing}${missing:+, }${p}"
  done
  if [[ -z "$missing" ]]; then
    echo "активен, порты открыты (80/443${sub_port:+/$sub_port})"
  else
    echo "активен, НЕТ правил для port/tcp: ${missing}"
  fi
  return 0
}

# ─── URL подписки профиля (единственное место сборки) ──────
# База — всегда _subscription_base_url (никакой своей схемы/хоста), путь —
# /sub/<32hex-токен> из профиля. return 1 если токена нет.
_status_profile_sub_url() {
  local profile_name="${1:-}" token=""
  [[ -n "$profile_name" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  token=$(jq -r '.sub_token // ""' "$PROFILES_DIR/${profile_name}.json" 2>/dev/null || true)
  [[ "$token" =~ ^[a-f0-9]{32}$ ]] || return 1
  printf '%s/sub/%s\n' "$(_subscription_base_url)" "$token"
}

# Токен первого видимого профиля (для локальной проверки подписки).
_status_first_profile_token() {
  local name="" token=""
  name=$(_list_visible_profile_names 2>/dev/null | head -1 || true)
  [[ -n "$name" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  token=$(jq -r '.sub_token // ""' "$PROFILES_DIR/${name}.json" 2>/dev/null || true)
  [[ "$token" =~ ^[a-f0-9]{32}$ ]] || return 1
  printf '%s\n' "$token"
}

# HTTP-код ЛОКАЛЬНОЙ проверки подписки (127.0.0.1, ≤5с, без внешней сети).
# Handler отвечает 404 на «/sub/» без токена (strict regex) — поэтому при
# наличии профиля проверяем реальный токен, а голый /sub/ оставляем как
# проверку «жив ли nginx». stdout: код или «000».
_status_sub_http_code() {
  local port="${1:-}" token="" code=""
  command -v curl >/dev/null 2>&1 || return 1
  [[ "$port" =~ ^[0-9]+$ ]] || return 1

  if token=$(_status_first_profile_token 2>/dev/null); then
    code=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' \
      "https://127.0.0.1:${port}/sub/${token}" 2>/dev/null || true)
  else
    code=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' \
      "https://127.0.0.1:${port}/sub/" 2>/dev/null || true)
  fi
  [[ -n "$code" ]] || code="000"
  printf '%s\n' "$code"
}

# ─── Сводка (без меню — тесты вызывают отдельно) ───────────
# return 0: проблем нет. return 1: есть хотя бы один ✗/⚠.
status_render_summary() {
  local problems=0

  echo -e "${BLUE}═══ СТАТУС СЕРВЕРА ═══${NC}"
  echo ""

  # 1. Режим работы -----------------------------------------
  _status_detect_mode
  if [[ "$_STATUS_MODE_KIND" == "selfsteal" ]]; then
    if [[ -n "$_STATUS_MODE_DOMAIN" ]]; then
      echo -e "  ${BLUE}Режим:${NC}     ${GREEN}✓${NC} self-steal (${_STATUS_MODE_DOMAIN})"
    else
      echo -e "  ${BLUE}Режим:${NC}     ${YELLOW}⚠${NC} self-steal (домен не сохранён)"
      problems=$((problems + 1))
    fi
  else
    echo -e "  ${BLUE}Режим:${NC}     ${GREEN}✓${NC} Reality по IP"
  fi

  # 2. Xray -------------------------------------------------
  local xray_state=""
  if command -v systemctl >/dev/null 2>&1; then
    xray_state=$(systemctl is-active xray 2>/dev/null || true)
  fi
  if [[ "$xray_state" == "active" ]]; then
    echo -e "  ${BLUE}Xray:${NC}      ${GREEN}✓${NC} active"
  elif [[ -z "$xray_state" ]]; then
    echo -e "  ${BLUE}Xray:${NC}      ${YELLOW}⚠${NC} неизвестно (systemctl недоступен)"
    problems=$((problems + 1))
  else
    echo -e "  ${BLUE}Xray:${NC}      ${RED}✗${NC} ${xray_state}"
    problems=$((problems + 1))
  fi

  # 3. :443 -------------------------------------------------
  local listener="" proc=""
  listener=$(_status_port_listener 443)
  if ! command -v ss >/dev/null 2>&1; then
    echo -e "  ${BLUE}:443${NC}       ${YELLOW}⚠${NC} неизвестно (ss не найден)"
    problems=$((problems + 1))
  elif [[ -z "$listener" ]]; then
    echo -e "  ${BLUE}:443${NC}       ${RED}✗${NC} никто не слушает"
    problems=$((problems + 1))
  elif grep -q 'xray' <<< "$listener"; then
    echo -e "  ${BLUE}:443${NC}       ${GREEN}✓${NC} слушает xray"
  else
    proc=$(_status_listener_process "$listener")
    echo -e "  ${BLUE}:443${NC}       ${RED}✗${NC} занят: ${proc}"
    problems=$((problems + 1))
  fi

  # 4. Подписка ---------------------------------------------
  local sub_port="" sub_line="" sub_mode=""
  sub_port=$(_status_sub_port)
  sub_mode=$(cat "$STATUS_SUB_MODE_FILE" 2>/dev/null || true)
  if [[ ! -f "$STATUS_SUB_MARKER" ]]; then
    echo -e "  ${BLUE}Подписка:${NC}  ${RED}✗${NC} не установлена"
    problems=$((problems + 1))
  elif [[ -z "$sub_port" ]]; then
    echo -e "  ${BLUE}Подписка:${NC}  ${RED}✗${NC} нет файла порта (${STATUS_SUB_PORT_FILE})"
    problems=$((problems + 1))
  else
    sub_line=$(_status_port_listener "$sub_port")
    if ! command -v ss >/dev/null 2>&1; then
      echo -e "  ${BLUE}Подписка:${NC}  ${YELLOW}⚠${NC} :${sub_port} — слушается ли, неизвестно (ss нет)"
      problems=$((problems + 1))
    elif [[ -z "$sub_line" ]]; then
      echo -e "  ${BLUE}Подписка:${NC}  ${RED}✗${NC} порт :${sub_port} не слушается"
      problems=$((problems + 1))
    elif ! command -v curl >/dev/null 2>&1; then
      echo -e "  ${BLUE}Подписка:${NC}  ${YELLOW}⚠${NC} :${sub_port} слушается, HTTP не проверен (curl нет)"
    else
      local code=""
      code=$(_status_sub_http_code "$sub_port")
      if [[ "$code" =~ ^[23] && "$sub_mode" == "local_only" ]]; then
        # local-only подписка работает только с самого VPS — снаружи клиент
        # её не заберёт, поэтому это ⚠, а не успех.
        echo -e "  ${BLUE}Подписка:${NC}  ${YELLOW}⚠${NC} :${sub_port}, local-only (только с VPS, HTTP ${code})"
        problems=$((problems + 1))
      elif [[ "$code" =~ ^[23] ]]; then
        echo -e "  ${BLUE}Подписка:${NC}  ${GREEN}✓${NC} :${sub_port}${sub_mode:+ (${sub_mode})}, локально HTTP ${code}"
      elif _status_first_profile_token >/dev/null 2>&1; then
        echo -e "  ${BLUE}Подписка:${NC}  ${RED}✗${NC} :${sub_port}, локально HTTP ${code}"
        problems=$((problems + 1))
      elif [[ "$code" == "404" ]]; then
        # 404 на /sub/ — это ответ handler'а (strict regex требует 32-hex
        # токен): цепочка nginx → handler жива. Проверять нечего, профилей
        # с sub_token нет — лечится пунктом 1 (добавить пользователя).
        echo -e "  ${BLUE}Подписка:${NC}  ${GREEN}✓${NC} :${sub_port}, handler отвечает (профилей с токеном нет)"
      else
        echo -e "  ${BLUE}Подписка:${NC}  ${YELLOW}⚠${NC} :${sub_port}, HTTP ${code} (нет профилей с sub_token)"
      fi
    fi
  fi

  # 5. Сертификат -------------------------------------------
  local cert_subject="" days=""
  if [[ "$_STATUS_MODE_KIND" == "selfsteal" && -n "$_STATUS_MODE_DOMAIN" ]]; then
    cert_subject="$_STATUS_MODE_DOMAIN"
  elif [[ -f "$STATUS_SUB_MARKER" ]]; then
    # IP-режим подписки: сертификат выпущен на IP сервера.
    cert_subject=$(cat "$STATUS_SUB_DOMAIN_FILE" 2>/dev/null || true)
    [[ "$cert_subject" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || cert_subject=""
  fi

  if [[ -z "$cert_subject" ]]; then
    echo -e "  ${BLUE}Сертификат:${NC} ${YELLOW}⚠${NC} n/a (IP-режим)"
  elif days=$(_status_cert_days "$cert_subject"); then
    if [[ "$days" -lt 0 ]]; then
      echo -e "  ${BLUE}Сертификат:${NC} ${RED}✗${NC} истёк ${days#-} дн. назад (${cert_subject})"
      problems=$((problems + 1))
    elif [[ "$days" -lt "$STATUS_CERT_WARN_DAYS" ]]; then
      echo -e "  ${BLUE}Сертификат:${NC} ${YELLOW}⚠${NC} ${days} дн. до истечения (${cert_subject})"
      problems=$((problems + 1))
    else
      echo -e "  ${BLUE}Сертификат:${NC} ${GREEN}✓${NC} ${days} дн. (${cert_subject})"
    fi
  elif ! command -v openssl >/dev/null 2>&1; then
    echo -e "  ${BLUE}Сертификат:${NC} ${YELLOW}⚠${NC} не проверен (openssl нет)"
  elif [[ "$_STATUS_MODE_KIND" != "selfsteal" ]]; then
    echo -e "  ${BLUE}Сертификат:${NC} ${YELLOW}⚠${NC} n/a (IP-режим, файла нет)"
  else
    echo -e "  ${BLUE}Сертификат:${NC} ${RED}✗${NC} нет ${STATUS_LE_LIVE_DIR}/${cert_subject}/fullchain.pem"
    problems=$((problems + 1))
  fi

  # 6. UFW --------------------------------------------------
  local ufw_state=""
  ufw_state=$(_status_ufw_state "$sub_port")
  if [[ "$ufw_state" == *"НЕТ правил"* ]]; then
    # Проверяем «НЕТ правил» РАНЬШЕ «активен»: активный ufw с закрытым
    # портом подписки — это проблема, а не успех.
    echo -e "  ${BLUE}UFW:${NC}       ${YELLOW}⚠${NC} ${ufw_state}"
    problems=$((problems + 1))
  elif [[ "$ufw_state" == активен* ]]; then
    echo -e "  ${BLUE}UFW:${NC}       ${GREEN}✓${NC} ${ufw_state}"
  else
    echo -e "  ${BLUE}UFW:${NC}       ${YELLOW}⚠${NC} ${ufw_state}"
  fi

  # 7. Пользователи -----------------------------------------
  local users=() u="" count=0
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    users+=("$u")
  done < <(_list_visible_profile_names 2>/dev/null || true)
  count=${#users[@]}
  if [[ "$count" -eq 0 ]]; then
    echo -e "  ${BLUE}Пользователи:${NC} ${RED}✗${NC} нет профилей"
    problems=$((problems + 1))
  else
    echo -e "  ${BLUE}Пользователи:${NC} ${GREEN}✓${NC} ${count} ($(IFS=', '; echo "${users[*]}"))"
  fi

  echo ""
  [[ "$problems" -eq 0 ]] && return 0
  return 1
}

# ─── Пункт 1: добавить пользователя ────────────────────────
# Дефолт — следующий свободный user-NNN.
_status_next_default_user() {
  local f name max=0
  for f in "$PROFILES_DIR"/user-*.json; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f" .json)
    if [[ "$name" =~ ^user-([0-9]+)$ ]]; then
      max=$(( 10#${BASH_REMATCH[1]} > max ? 10#${BASH_REMATCH[1]} : max ))
    fi
  done
  printf 'user-%03d\n' $((max + 1))
}

_status_add_user() {
  local default_user="" user_name="" attempts=0

  echo ""
  echo -e "${MAGENTA}═══ ДОБАВИТЬ ПОЛЬЗОВАТЕЛЯ ═══${NC}"
  default_user=$(_status_next_default_user)

  while true; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -gt 10 ]]; then
      echo -e "${RED}  Слишком много неверных попыток — отмена${NC}"
      _status_pause
      return 1
    fi
    echo -n -e "${YELLOW}Имя профиля [${CYAN}${default_user}${YELLOW}]: ${NC}"
    if ! read -r user_name; then
      echo ""
      echo -e "${RED}  Нет ввода — отмена${NC}"
      return 1
    fi
    [[ -z "$user_name" ]] && user_name="$default_user"

    if [[ ! "$user_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
      echo -e "${RED}  ✗ Недопустимое имя: '${user_name}'${NC}"
      echo -e "${YELLOW}    Латиница, цифры, '-' и '_'; первый символ — буква или цифра.${NC}"
      continue
    fi
    if [[ -f "$PROFILES_DIR/${user_name}.json" ]]; then
      echo -e "${RED}  ✗ Пользователь ${user_name} уже существует${NC}"
      continue
    fi
    break
  done

  echo ""
  echo -e "${CYAN}  → Создаю профиль ${user_name}: 7 маршрутов (XHTTP+PQ дефолт)...${NC}"
  if ! declare -F create_profile_all_routes >/dev/null 2>&1; then
    echo -e "${RED}  ✗ create_profile_all_routes недоступна${NC}"
    _status_pause
    return 1
  fi
  if ! create_profile_all_routes "$user_name" "no_pause" "hide_subscription"; then
    echo ""
    echo -e "${RED}  ✗ Профиль ${user_name} не создан${NC}"
    echo -e "${YELLOW}    Что проверить:${NC}"
    echo -e "${YELLOW}      jq . ${CONFIG_FILE} >/dev/null     — валиден ли config.json${NC}"
    echo -e "${YELLOW}      systemctl status xray --no-pager -l${NC}"
    echo -e "${YELLOW}      ss -tlnH | grep LISTEN            — не заняты ли порты маршрутов${NC}"
    _status_pause
    return 1
  fi
  echo -e "${GREEN}  ✓ Профиль ${user_name} создан (7 маршрутов)${NC}"

  if declare -F _happ_print_subscription_url_for_profile >/dev/null 2>&1; then
    _happ_print_subscription_url_for_profile "$user_name" || true
  else
    local url=""
    if url=$(_status_profile_sub_url "$user_name"); then
      echo -e "${BLUE}  URL:${NC} ${GREEN}${url}${NC}"
    fi
  fi
  _status_pause
  return 0
}

# ─── Пункт 2: ссылки / QR ──────────────────────────────────
_status_show_links() {
  local names=() name url i choice

  echo ""
  echo -e "${MAGENTA}═══ ССЫЛКИ ПОДПИСКИ ═══${NC}"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    names+=("$name")
  done < <(_list_visible_profile_names 2>/dev/null || true)

  if [[ ${#names[@]} -eq 0 ]]; then
    echo -e "${YELLOW}  Профилей нет — добавьте пользователя (пункт 1).${NC}"
    _status_pause
    return 0
  fi

  for i in "${!names[@]}"; do
    name="${names[$i]}"
    if url=$(_status_profile_sub_url "$name"); then
      echo -e "  ${CYAN}$((i + 1)))${NC} ${GREEN}${name}${NC}"
      echo -e "      ${url}"
    else
      echo -e "  ${CYAN}$((i + 1)))${NC} ${GREEN}${name}${NC}"
      echo -e "      ${YELLOW}⚠ нет валидного sub_token — пересоздайте профиль${NC}"
    fi
  done
  echo ""
  echo -e "${CYAN}  [номер]${NC} показать QR   ${CYAN}[0]${NC} назад"
  echo -n -e "${YELLOW}Выбор: ${NC}"
  if ! read -r choice; then
    echo ""
    return 0
  fi
  [[ "$choice" == "0" || -z "$choice" ]] && return 0

  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#names[@]} ]]; then
    echo -e "${RED}  ✗ Неверный выбор${NC}"
    return 0
  fi

  name="${names[$((choice - 1))]}"
  echo ""
  if ! url=$(_status_profile_sub_url "$name"); then
    echo -e "${RED}  ✗ У профиля ${name} нет валидного sub_token — QR не построить${NC}"
    return 0
  fi
  echo -e "${BLUE}Профиль:${NC} ${GREEN}${name}${NC}"
  echo -e "${BLUE}URL:${NC} ${GREEN}${url}${NC}"
  echo ""
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$url" 2>/dev/null || \
      echo -e "${YELLOW}⚠ qrencode не построил QR — скопируйте ссылку выше${NC}"
  else
    echo -e "${YELLOW}⚠ qrencode не установлен — QR не показан (apt-get install -y qrencode)${NC}"
  fi
  return 0
}

# ─── Пункт 4: дополнительно ────────────────────────────────
_status_extra_menu() {
  local choice=""
  while true; do
    echo ""
    echo -e "${MAGENTA}═══ ДОПОЛНИТЕЛЬНО ═══${NC}"
    echo -e "${CYAN} 1)${NC} Пакетное добавление пользователей"
    echo -e "${CYAN} 2)${NC} Tailscale exit node"
    echo -e "${CYAN} 3)${NC} Каскад / upstream"
    echo -e "${CYAN} 4)${NC} Подписка HAPP (создать / управлять)"
    echo -e "${CYAN} 5)${NC} Self-steal (статус/удаление)"
    echo -e "${CYAN} 6)${NC} Профили advanced (SNI/порт/fingerprint)"
    echo -e "${CYAN} 7)${NC} Удалить пользователя"
    echo -e "${CYAN} 8)${NC} Обновить Xray-core"
    echo -e "${CYAN} 0)${NC} Назад"
    echo -n -e "${YELLOW}Выбор: ${NC}"
    if ! read -r choice; then return 0; fi
    case "$choice" in
      1) declare -F bulk_happ_users_menu >/dev/null 2>&1 && bulk_happ_users_menu || { echo -e "${YELLOW}  Модуль недоступен${NC}"; _status_pause; } ;;
      2) declare -F tailscale_exit_node_menu >/dev/null 2>&1 && tailscale_exit_node_menu || { echo -e "${YELLOW}  Модуль недоступен${NC}"; _status_pause; } ;;
      3) declare -F cascade_mode_menu >/dev/null 2>&1 && cascade_mode_menu || { echo -e "${YELLOW}  Модуль недоступен${NC}"; _status_pause; } ;;
      4) declare -F happ_subscription_menu >/dev/null 2>&1 && happ_subscription_menu || { echo -e "${YELLOW}  Модуль недоступен${NC}"; _status_pause; } ;;
      5) declare -F selfsteal_menu >/dev/null 2>&1 && selfsteal_menu || { echo -e "${YELLOW}  Модуль недоступен${NC}"; _status_pause; } ;;
      6) declare -F manage_profile_menu >/dev/null 2>&1 && manage_profile_menu || { echo -e "${YELLOW}  Модуль недоступен${NC}"; _status_pause; } ;;
      7) declare -F delete_profile_menu >/dev/null 2>&1 && delete_profile_menu || { echo -e "${YELLOW}  Модуль недоступен${NC}"; _status_pause; } ;;
      8) if declare -F update_command >/dev/null 2>&1; then
           update_command
           _status_pause
         else
           echo -e "${YELLOW}  Модуль недоступен${NC}"
           _status_pause
         fi ;;
      0|"") return 0 ;;
      *) echo -e "${RED}  Неверный выбор${NC}" ;;
    esac
  done
}

# ─── Статус-экран: сводка + меню ───────────────────────────
status_screen() {
  local choice=""
  while true; do
    if declare -F show_ascii >/dev/null 2>&1; then
      show_ascii
    fi
    status_render_summary || true
    echo -e "${BLUE}─── ДЕЙСТВИЯ ───${NC}"
    echo -e "${CYAN} 1)${NC} Добавить пользователя"
    echo -e "${CYAN} 2)${NC} Показать ссылки / QR"
    echo -e "${CYAN} 3)${NC} Диагностика и починка"
    echo -e "${CYAN} 4)${NC} Дополнительно →"
    echo -e "${RED} 0)${NC} Выход"
    echo -n -e "${YELLOW}Выберите действие: ${NC}"
    if ! read -r choice; then
      echo ""
      return 0
    fi
    case "$choice" in
      1) _status_add_user ;;
      2) _status_show_links ;;
      3) diagnose_and_repair ;;
      4) _status_extra_menu ;;
      0) return 0 ;;
      *) echo -e "${RED}Неверный выбор${NC}"; sleep 1 ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════
# ДИАГНОСТИКА И ПОЧИНКА (7 проверок)
# ═══════════════════════════════════════════════════════════
# Формат: «✓ пункт» или «✗ пункт → причина». При ✗ — предложение
# автопочинки, затем перепроверка тем же check_fn. Если починка не
# удалась — точные команды для ручной проверки (_status_manual_hints).

_DIAG_PROBLEMS=0
_DIAG_FIXED=0
_DIAG_ABORT=0
_STATUS_REASON=""

# Точные команды ручной проверки по номеру проверки.
_status_manual_hints() {
  local num="${1:-}"
  echo -e "${YELLOW}  Что проверить вручную:${NC}"
  case "$num" in
    1)
      echo -e "${YELLOW}    systemctl status xray --no-pager -l${NC}"
      echo -e "${YELLOW}    journalctl -u xray -n 40 --no-pager${NC}"
      echo -e "${YELLOW}    xray run -test -format json -config ${CONFIG_FILE}${NC}"
      ;;
    2)
      echo -e "${YELLOW}    ss -tlnpH 'sport = :443'      — кто держит порт${NC}"
      echo -e "${YELLOW}    systemctl stop <сервис>        — освободить порт (nginx/apache)${NC}"
      echo -e "${YELLOW}    jq '.inbounds[] | select(.port == 443)' ${CONFIG_FILE}${NC}"
      ;;
    3)
      echo -e "${YELLOW}    ss -tlnH 'sport = :80'         — порт 80 нужен для выпуска сертификата${NC}"
      echo -e "${YELLOW}    tail -30 /tmp/certbot-ip.log${NC}"
      echo -e "${YELLOW}    systemctl status ${STATUS_SUB_SERVICE} --no-pager -l${NC}"
      ;;
    4)
      echo -e "${YELLOW}    nginx -t                       — валиден ли конфиг${NC}"
      echo -e "${YELLOW}    ss -tlnpH 'sport = :$( _status_sub_port )'${NC}"
      echo -e "${YELLOW}    grep listen ${STATUS_NGINX_SUB_SITE}${NC}"
      echo -e "${YELLOW}    cat ${STATUS_SELFSTEAL_PORT_FILE}   — backend self-steal (коллизия?)${NC}"
      ;;
    5)
      echo -e "${YELLOW}    journalctl -u ${STATUS_SUB_SERVICE} -n 40 --no-pager${NC}"
      echo -e "${YELLOW}    systemctl status ${STATUS_SUB_SERVICE} --no-pager -l${NC}"
      echo -e "${YELLOW}    curl -sk https://127.0.0.1:$( _status_sub_port )/sub/ -v${NC}"
      ;;
    6)
      echo -e "${YELLOW}    certbot certificates${NC}"
      echo -e "${YELLOW}    certbot renew --dry-run${NC}"
      echo -e "${YELLOW}    tail -40 /var/log/letsencrypt/letsencrypt.log${NC}"
      ;;
    7)
      echo -e "${YELLOW}    ufw status numbered${NC}"
      echo -e "${YELLOW}    ufw allow 80/tcp${NC}"
      echo -e "${YELLOW}    dig +short ${_STATUS_MODE_DOMAIN:-<домен>}   — A-запись должна указывать на этот VPS${NC}"
      ;;
  esac
}

# Один шаг диагностики: check → (при ✗) предложение починки → перепроверка.
_diag_step() {
  local num="$1" title="$2" check_fn="$3" repair_fn="$4" ans="" attempts=0

  _STATUS_REASON=""
  if "$check_fn"; then
    echo -e "${GREEN}✓ ${num}. ${title}${NC}"
    return 0
  fi

  _DIAG_PROBLEMS=$((_DIAG_PROBLEMS + 1))
  echo -e "${RED}✗ ${num}. ${title} → ${_STATUS_REASON:-причина неизвестна}${NC}"

  while true; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -gt 10 ]]; then
      _DIAG_ABORT=1
      return 2
    fi
    echo -e "${CYAN}  [1]${NC} Починить   ${CYAN}[2]${NC} Пропустить   ${CYAN}[0]${NC} Выход"
    echo -n -e "${YELLOW}  Действие: ${NC}"
    if ! read -r ans; then
      echo ""
      echo -e "${YELLOW}  → Нет ввода: пропускаю проверку${NC}"
      _status_manual_hints "$num"
      return 1
    fi
    case "$ans" in
      1)
        if ! "$repair_fn"; then
          echo -e "${RED}  ✗ Автопочинка не удалась${NC}"
        fi
        # Перепроверка ТЕМ ЖЕ check_fn: «починка выполнена» ≠ «починено».
        _STATUS_REASON=""
        echo -e "${CYAN}  → Перепроверка...${NC}"
        if "$check_fn"; then
          echo -e "${GREEN}  ✓ Исправлено: ${title}${NC}"
          _DIAG_FIXED=$((_DIAG_FIXED + 1))
          return 0
        fi
        echo -e "${RED}  ✗ Проблема осталась: ${_STATUS_REASON:-проверка не проходит}${NC}"
        _status_manual_hints "$num"
        return 1
        ;;
      2)
        echo -e "${YELLOW}  → Пропущено${NC}"
        _status_manual_hints "$num"
        return 1
        ;;
      0)
        echo -e "${YELLOW}  → Выход из диагностики${NC}"
        _DIAG_ABORT=1
        return 2
        ;;
      *)
        echo -e "${RED}  Неверный выбор — введите 1, 2 или 0${NC}"
        ;;
    esac
  done
}

# ── Проверка 1/7: Xray active ──────────────────────────────
_status_diag_1_xray() {
  command -v systemctl >/dev/null 2>&1 || { _STATUS_REASON="systemctl не найден"; return 1; }
  local state=""
  state=$(systemctl is-active xray 2>/dev/null || true)
  if [[ "$state" == "active" ]]; then
    return 0
  fi
  _STATUS_REASON="сервис ${state:-неизвестно}"
  return 1
}

_status_repair_1_xray() {
  command -v systemctl >/dev/null 2>&1 || { _status_bad "systemctl не найден"; return 1; }
  # safe_restart_xray валидирует конфиг и откатывает его при ошибке —
  # перезапуск «вслепую» на битом config.json уронил бы рабочий VPN.
  if declare -F safe_restart_xray >/dev/null 2>&1; then
    echo -e "${CYAN}  → Перезапуск Xray с проверкой конфига...${NC}"
    if safe_restart_xray; then
      return 0
    fi
    echo -e "${YELLOW}  ⚠ safe_restart_xray не удался — пробую обычный restart${NC}"
  fi
  echo -e "${CYAN}  → systemctl restart xray${NC}"
  systemctl restart xray 2>/dev/null || return 1
  sleep 1
  systemctl is-active --quiet xray 2>/dev/null
}

# ── Проверка 2/7: :443 слушает xray ────────────────────────
_status_diag_2_port443() {
  command -v ss >/dev/null 2>&1 || { _STATUS_REASON="ss не найден (iproute2)"; return 1; }
  local listener=""
  listener=$(_status_port_listener 443)
  if [[ -z "$listener" ]]; then
    _STATUS_REASON="никто не слушает :443"
    return 1
  fi
  if grep -q 'xray' <<< "$listener"; then
    return 0
  fi
  _STATUS_REASON=":443 занят процессом $(_status_listener_process "$listener")"
  return 1
}

_status_repair_2_port443() {
  local listener=""
  listener=$(_status_port_listener 443)
  if [[ -n "$listener" ]] && ! grep -q 'xray' <<< "$listener"; then
    echo -e "${RED}  ✗ Порт :443 держит чужой процесс: ${listener}${NC}"
    echo -e "${YELLOW}  Автоперенос :443 невозможен — освободите порт вручную:${NC}"
    echo -e "${YELLOW}    ss -tlnp 'sport = :443'  →  systemctl stop <сервис>${NC}"
    return 1
  fi
  if ! _status_has_443_inbound; then
    echo -e "${RED}  ✗ В ${CONFIG_FILE} нет inbound на :443 — перезапуск не поможет${NC}"
    echo -e "${YELLOW}  Создайте пользователя или запустите мастер: sudo xraytailscale wizard${NC}"
    return 1
  fi
  echo -e "${CYAN}  → Inbound :443 есть, но не слушается — перезапуск Xray...${NC}"
  if declare -F safe_restart_xray >/dev/null 2>&1; then
    safe_restart_xray && return 0
  fi
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl restart xray 2>/dev/null || return 1
  sleep 1
  systemctl is-active --quiet xray 2>/dev/null
}

# ── Проверка 3/7: подписка установлена ────────────────────
_status_diag_3_subscription() {
  if [[ ! -f "$STATUS_SUB_MARKER" ]]; then
    _STATUS_REASON="нет маркера ${STATUS_SUB_MARKER}"
    return 1
  fi
  local port=""
  port=$(_status_sub_port)
  if [[ -z "$port" ]]; then
    _STATUS_REASON="нет файла порта ${STATUS_SUB_PORT_FILE}"
    return 1
  fi
  return 0
}

# Email для Let's Encrypt: спрашиваем ОДИН раз здесь, чтобы installer не
# задавал вопрос повторно (SUBSCRIPTION_LE_EMAIL override, как в мастере).
_status_ask_le_email() {
  local email="" tries=0 default="" domain=""
  domain=$(get_server_domain 2>/dev/null || true)
  [[ -n "$domain" ]] && default="admin@${domain}"

  while [[ "$tries" -lt 3 ]]; do
    tries=$((tries + 1))
    if [[ -n "$default" ]]; then
      echo -n -e "${YELLOW}  Email для Let's Encrypt [${CYAN}${default}${YELLOW}]: ${NC}" >&2
    else
      echo -n -e "${YELLOW}  Email для Let's Encrypt (нужен для сертификата): ${NC}" >&2
    fi
    if ! read -r email; then
      echo "" >&2
      return 1
    fi
    [[ -z "$email" ]] && email="$default"
    if [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
      printf '%s\n' "$email"
      return 0
    fi
    echo -e "${RED}  ✗ Некорректный email: '${email}'${NC}" >&2
  done
  return 1
}

_status_repair_3_subscription() {
  if ! declare -F install_subscription_ip_tls >/dev/null 2>&1; then
    echo -e "${RED}  ✗ install_subscription_ip_tls недоступна${NC}"
    return 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo -e "${RED}  ✗ systemctl не найден — установка сервиса невозможна${NC}"
    return 1
  fi

  echo -e "${YELLOW}  ⚠ Подписка ставится в IP-режиме (HTTPS по IP VPS): при self-steal${NC}"
  echo -e "${YELLOW}    доменный режим даёт конфликт server_name во втором nginx-vhost.${NC}"
  echo ""
  # Blast radius явно: установка — не «мелкая починка», а выпуск сертификата
  # + установка nginx + перезапись vhost. Требуем отдельного подтверждения.
  echo -e "${YELLOW}  Будет выполнено:${NC}"
  echo -e "${YELLOW}    • выпуск сертификата Let's Encrypt по IP VPS${NC}"
  echo -e "${YELLOW}    • установка/настройка nginx и systemd-сервиса xraytailscale-sub${NC}"
  echo -e "${YELLOW}    • запись /etc/nginx/sites-available/xraytailscale-sub${NC}"
  echo -e "${YELLOW}    • открытие порта в UFW${NC}"
  echo -n -e "${YELLOW}  Продолжить установку? [д/Н]: ${NC}"
  local ans
  if ! read -r ans; then
    echo ""
    return 1
  fi
  if [[ ! "$ans" =~ ^[yYдД]$ ]]; then
    echo -e "${YELLOW}  Установка отменена пользователем${NC}"
    return 1
  fi

  local email=""
  if ! email=$(_status_ask_le_email); then
    echo -e "${RED}  ✗ Email не получен — установка отменена${NC}"
    return 1
  fi

  # Восстанавливаем прежнее значение переменной после вызова installer'а.
  local prev_email="${SUBSCRIPTION_LE_EMAIL-}" had=0 rc=0
  [[ -n "${SUBSCRIPTION_LE_EMAIL+x}" ]] && had=1
  SUBSCRIPTION_LE_EMAIL="$email"
  install_subscription_ip_tls || rc=1
  if [[ "$had" -eq 1 ]]; then
    SUBSCRIPTION_LE_EMAIL="$prev_email"
  else
    unset SUBSCRIPTION_LE_EMAIL
  fi
  return "$rc"
}

# ── Проверка 4/7: порт подписки слушается ─────────────────
# Конфликт определяет _status_sub_port_check ниже (дубль удалён в ревью).

# Проверка порта подписки: 0 = конфликт/не слушается (причина в _STATUS_REASON).
_status_sub_port_check() {
  local port="${1:-}" backend="" line=""
  _STATUS_REASON=""
  if [[ -z "$port" ]]; then
    _STATUS_REASON="порт подписки неизвестен"
    return 1
  fi
  if ! command -v ss >/dev/null 2>&1; then
    _STATUS_REASON="ss не найден — проверить listen нельзя"
    return 1
  fi
  backend=$(_status_selfsteal_backend_port)
  if [[ -n "$backend" && "$port" == "$backend" ]]; then
    _STATUS_REASON="порт :${port} совпадает с backend'ом self-steal"
    return 1
  fi
  line=$(_status_port_listener "$port")
  if [[ -z "$line" ]]; then
    _STATUS_REASON="никто не слушает :${port}"
    return 1
  fi
  if ! grep -q 'nginx' <<< "$line"; then
    _STATUS_REASON="порт :${port} занят чужим процессом ($(_status_listener_process "$line"))"
    return 1
  fi
  return 0
}

# Есть ли конфликт порта (чужой процесс или backend self-steal) — без вывода.
_status_sub_port_conflict() {
  local port="${1:-}" backend=""
  [[ -n "$port" ]] || return 1
  backend=$(_status_selfsteal_backend_port)
  [[ -n "$backend" && "$port" == "$backend" ]] && return 0
  [[ -n "$(_status_port_listener "$port")" ]] || return 1
  [[ -n "$port" ]] || return 1
  _status_sub_port_check "$port" >/dev/null 2>&1 && return 1
  grep -q 'nginx' <<< "$(_status_port_listener "$port")" && return 1
  return 0
}

_status_diag_4_subport() {
  local port=""
  port=$(_status_sub_port)
  _status_sub_port_check "$port"
}

# Автоперенос подписки на свободный порт из диапазона 8443–12443.
# Инвариант консистентности: конфиг nginx и маркер .subscription_port
# меняются АТОМАРНО как пара. Любой сбой на полпути → откат конфига
# и возврат 1, чтобы не осталось «маркер на новом порту, nginx на старом».
_status_move_subscription_port() {
  local old_port="$1" new_port="" site="$STATUS_NGINX_SUB_SITE"

  # Порт из маркера подставляется в sed и в firewall — только цифры.
  if [[ ! "$old_port" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}  ✗ Некорректный текущий порт: '${old_port}'${NC}"
    return 1
  fi
  if [[ ! -f "$site" ]]; then
    echo -e "${RED}  ✗ Нет конфига ${site} — перенос невозможен${NC}"
    return 1
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    echo -e "${RED}  ✗ nginx не найден${NC}"
    return 1
  fi
  if ! declare -F _subscription_find_free_port >/dev/null 2>&1; then
    echo -e "${RED}  ✗ _subscription_find_free_port недоступна${NC}"
    return 1
  fi
  if ! new_port=$(_subscription_find_free_port); then
    echo -e "${RED}  ✗ Нет свободного порта для подписки (8443–12443 заняты)${NC}"
    return 1
  fi
  if [[ ! "$new_port" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}  ✗ Некорректный новый порт: '${new_port}'${NC}"
    return 1
  fi
  if [[ "$new_port" == "$old_port" ]]; then
    echo -e "${RED}  ✗ Свободный порт совпал с текущим (:${old_port}) — перенос не требуется${NC}"
    return 1
  fi

  # Preflight: в конфиге реально есть listen на старом порту, иначе sed
  # «успешно» ничего не заменит и мы запишем маркер на несуществующий порт.
  if ! grep -qE "listen[[:space:]]+\[::\]:${old_port}[[:space:]]|listen[[:space:]]+${old_port}[[:space:]]" "$site"; then
    echo -e "${RED}  ✗ В ${site} нет listen :${old_port} — перенос не требуется/невозможен${NC}"
    return 1
  fi

  echo -e "${CYAN}  → Перенос подписки :${old_port} → :${new_port}...${NC}"
  # -i.bak остаётся до успешного reload: откатываться может понадобиться позже.
  if ! sed -i.bak -E \
      "s/listen ${old_port} ssl/listen ${new_port} ssl/; s/listen \[::\]:${old_port} ssl/listen \[::\]:${new_port} ssl/; s/listen ${old_port} http2/listen ${new_port} http2/; s/listen \[::\]:${old_port} http2/listen \[::\]:${new_port} http2/" \
      "$site"; then
    echo -e "${RED}  ✗ Не удалось переписать ${site}${NC}"
    return 1
  fi
  # Пост-проверка: замена реально применилась.
  if ! grep -qE "listen[[:space:]]+(\[::\]:)?${new_port}[[:space:] ;]" "$site"; then
    echo -e "${RED}  ✗ sed не применил замену в ${site} — откат${NC}"
    mv "${site}.bak" "$site" 2>/dev/null || true
    return 1
  fi
  if ! nginx -t >/dev/null 2>&1; then
    echo -e "${RED}  ✗ nginx -t не прошёл после переноса — откат конфига${NC}"
    nginx -t 2>&1 | tail -5
    if ! mv "${site}.bak" "$site" 2>/dev/null; then
      echo -e "${RED}  ✗✗ ОТКАТ НЕ УДАЛСЯ. Восстановите вручную: mv ${site}.bak ${site}${NC}"
    fi
    return 1
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl reload nginx >/dev/null 2>&1; then
      echo -e "${RED}  ✗ nginx не перечитал конфиг — откат на :${old_port}${NC}"
      if mv "${site}.bak" "$site" 2>/dev/null; then
        systemctl reload nginx >/dev/null 2>&1 || true
        echo -e "${YELLOW}  Конфиг восстановлен, подписка осталась на :${old_port}${NC}"
      else
        echo -e "${RED}  ✗✗ ОТКАТ НЕ УДАЛСЯ. Восстановите вручную: mv ${site}.bak ${site} && systemctl reload nginx${NC}"
      fi
      return 1
    fi
  fi
  rm -f "${site}.bak"

  # Firewall ДО маркера: если порт не открылся, снаружи подписка не работает —
  # молча объявлять успех нельзя. Откатываем всё.
  if declare -F open_firewall_port >/dev/null 2>&1; then
    if ! open_firewall_port "$new_port" tcp; then
      echo -e "${RED}  ✗ Не удалось открыть ${new_port}/tcp — откат на :${old_port}${NC}"
      sed -i -E "s/listen ${new_port} ssl/listen ${old_port} ssl/; s/listen \[::\]:${new_port} ssl/listen \[::\]:${old_port} ssl/" "$site"
      nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
      return 1
    fi
  fi

  # Атомарная запись маркера (tmp + mv): читатели не увидят недописанный порт.
  local tmp_marker="${STATUS_SUB_PORT_FILE}.tmp.$$"
  if ! printf '%s\n' "$new_port" > "$tmp_marker" 2>/dev/null \
     || ! mv "$tmp_marker" "$STATUS_SUB_PORT_FILE" 2>/dev/null; then
    rm -f "$tmp_marker"
    echo -e "${RED}  ✗ Не удалось записать ${STATUS_SUB_PORT_FILE} — откат на :${old_port}${NC}"
    sed -i -E "s/listen ${new_port} ssl/listen ${old_port} ssl/; s/listen \[::\]:${new_port} ssl/listen \[::\]:${old_port} ssl/" "$site"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    return 1
  fi
  chown xray:xray "$STATUS_SUB_PORT_FILE" 2>/dev/null || true

  echo ""
  echo -e "${YELLOW}  ⚠ ВНИМАНИЕ: ссылка подписки ИЗМЕНИЛАСЬ (порт ${old_port} → ${new_port}).${NC}"
  echo -e "${GREEN}  Новая база URL: $(_subscription_base_url)${NC}"
  local name="" url=""
  name=$(_list_visible_profile_names 2>/dev/null | head -1 || true)
  if [[ -n "$name" ]] && url=$(_status_profile_sub_url "$name"); then
    echo -e "${GREEN}  Новая URL (${name}): ${url}${NC}"
  fi
  echo -e "${YELLOW}  Переимпортируйте подписку в клиенте.${NC}"
  return 0
}

_status_repair_4_subport() {
  local old_port=""
  old_port=$(_status_sub_port)
  if [[ -z "$old_port" ]]; then
    echo -e "${RED}  ✗ Порт подписки неизвестен — сначала установите подписку${NC}"
    return 1
  fi

  # Конфликт порта (чужой процесс / backend self-steal) — только автоперенос.
  if _status_sub_port_conflict "$old_port"; then
    _status_move_subscription_port "$old_port" || return 1
    return 0
  fi

  # Порт свободен (nginx не слушает): конфиг валиден → reload.
  if ! command -v nginx >/dev/null 2>&1; then
    echo -e "${RED}  ✗ nginx не найден — подписка без него не поднимется${NC}"
    return 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo -e "${RED}  ✗ systemctl не найден${NC}"
    return 1
  fi
  if ! nginx -t >/dev/null 2>&1; then
    echo -e "${RED}  ✗ nginx -t не проходит — reload не поможет. Вывод:${NC}"
    nginx -t 2>&1 | tail -8
    return 1
  fi
  echo -e "${CYAN}  → nginx -t OK: reload...${NC}"
  if ! systemctl reload nginx >/dev/null 2>&1; then
    echo -e "${RED}  ✗ nginx не перечитал конфиг${NC}"
    return 1
  fi
  sleep 1
  if [[ -n "$(_status_port_listener "$old_port")" ]]; then
    return 0
  fi

  # Порт не поднялся: конфиг мог указывать на другой порт — переносим.
  echo -e "${YELLOW}  ⚠ :${old_port} всё ещё не слушается — пробую перенос на свободный порт${NC}"
  _status_move_subscription_port "$old_port"
}

# ── Проверка 5/7: подписка отвечает локально ──────────────
_status_diag_5_subhttp() {
  local port="" code=""
  port=$(_status_sub_port)
  if [[ -z "$port" ]]; then
    _STATUS_REASON="порт подписки неизвестен"
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    _STATUS_REASON="curl не найден"
    return 1
  fi
  local mode=""
  mode=$(cat "$STATUS_SUB_MODE_FILE" 2>/dev/null || true)
  code=$(_status_sub_http_code "$port")
  if [[ "$code" =~ ^[23] && "$mode" == "local_only" ]]; then
    _STATUS_REASON="local-only режим: снаружи клиент подписку не заберёт"
    return 1
  fi
  if [[ "$code" =~ ^[23] ]]; then
    return 0
  fi
  if ! _status_first_profile_token >/dev/null 2>&1; then
    # Нет ни одного профиля с sub_token — проверять содержимое подписки нечем.
    # 404 здесь — штатный ответ handler'а (strict regex), значит цепочка жива.
    if [[ "$code" == "404" ]]; then
      return 0
    fi
    _STATUS_REASON="локально HTTP ${code} (нет профилей с sub_token)"
    return 1
  fi
  _STATUS_REASON="локально HTTP ${code}"
  return 1
}

_status_repair_5_subhttp() {
  if command -v journalctl >/dev/null 2>&1; then
    echo -e "${CYAN}  → Последние строки лога ${STATUS_SUB_SERVICE}:${NC}"
    journalctl -u "$STATUS_SUB_SERVICE" -n 20 --no-pager 2>/dev/null | tail -20 || true
  else
    echo -e "${YELLOW}  ⚠ journalctl не найден — лог сервиса недоступен${NC}"
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    echo -e "${RED}  ✗ systemctl не найден — сервис не перезапустить${NC}"
    return 1
  fi
  local state=""
  state=$(systemctl is-active "$STATUS_SUB_SERVICE" 2>/dev/null || true)
  if [[ "$state" == "active" ]]; then
    # Сервис жив, но ответ не 2xx/3xx: переустанавливаем handler
    # (_subscription_repair_handler = install_subscription_server + restart).
    echo -e "${YELLOW}  ℹ Сервис активен, но handler не отдаёт подписку — переустанавливаю handler${NC}"
    if declare -F _subscription_repair_handler >/dev/null 2>&1; then
      _subscription_repair_handler && return 0
    fi
    echo -e "${YELLOW}    Починка профилей: sudo xraytailscale subscription-repair${NC}"
    return 1
  fi
  echo -e "${CYAN}  → Сервис ${state:-неизвестно} — перезапуск ${STATUS_SUB_SERVICE}...${NC}"
  systemctl reset-failed "$STATUS_SUB_SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$STATUS_SUB_SERVICE" 2>/dev/null || return 1
  sleep 2
  systemctl is-active --quiet "$STATUS_SUB_SERVICE" 2>/dev/null
}

# ── Проверка 6/7: сертификат ──────────────────────────────
_status_diag_6_cert() {
  if ! command -v openssl >/dev/null 2>&1; then
    _STATUS_REASON="openssl не найден"
    return 1
  fi

  _status_detect_mode
  local subject="" days=""
  if [[ "$_STATUS_MODE_KIND" == "selfsteal" && -n "$_STATUS_MODE_DOMAIN" ]]; then
    subject="$_STATUS_MODE_DOMAIN"
  elif [[ -f "$STATUS_SUB_MARKER" ]]; then
    subject=$(cat "$STATUS_SUB_DOMAIN_FILE" 2>/dev/null || true)
    [[ "$subject" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || subject=""
  fi

  if [[ -z "$subject" ]]; then
    # IP-режим без файла сертификата: подписка могла не встать — это ловит
    # проверка 3, здесь не дублируем ошибку.
    return 0
  fi
  if ! days=$(_status_cert_days "$subject"); then
    _STATUS_REASON="нет сертификата ${STATUS_LE_LIVE_DIR}/${subject}/fullchain.pem"
    return 1
  fi
  if [[ "$days" -lt "$STATUS_CERT_WARN_DAYS" ]]; then
    _STATUS_REASON="осталось ${days} дн. (< ${STATUS_CERT_WARN_DAYS})"
    return 1
  fi
  return 0
}

_status_repair_6_cert() {
  if ! command -v certbot >/dev/null 2>&1; then
    echo -e "${RED}  ✗ certbot не найден${NC}"
    echo -e "${YELLOW}    apt-get install -y certbot${NC}"
    return 1
  fi
  echo -e "${CYAN}  → certbot renew --dry-run (реальный renew НЕ выполняется)...${NC}"
  local out="" rc=0
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout 300 certbot renew --dry-run 2>&1) || rc=$?
  else
    out=$(certbot renew --dry-run 2>&1) || rc=$?
  fi
  printf '%s\n' "$out" | tail -20
  if [[ "$rc" -ne 0 ]]; then
    echo -e "${RED}  ✗ dry-run завершился с кодом ${rc}${NC}"
    echo -e "${YELLOW}    Проверьте :80 (ACME) и DNS домена.${NC}"
    return 1
  fi
  echo -e "${GREEN}  ✓ dry-run прошёл: renew работоспособен${NC}"
  # dry-run не обновляет сертификат; при <7 дней нужен реальный renew.
  echo -e "${YELLOW}  ℹ Если сертификат истекает, выполните: certbot renew --force-renewal${NC}"
  return 0
}

# ── Проверка 7/7: порт 80 (ACME renew) ────────────────────
_status_diag_7_port80() {
  if ! command -v ufw >/dev/null 2>&1; then
    return 0
  fi
  local st=""
  st=$(ufw status 2>/dev/null || true)
  if ! grep -q "Status: active" <<< "$st"; then
    return 0
  fi
  if grep -qE "^([0-9]+,)*80(,[0-9]+)*/tcp[[:space:]]+(ALLOW|LIMIT)" <<< "$st"; then
    return 0
  fi
  _STATUS_REASON="ufw активен, правила для 80/tcp нет"
  return 1
}

_status_repair_7_port80() {
  if ! declare -F open_firewall_port >/dev/null 2>&1; then
    echo -e "${RED}  ✗ open_firewall_port недоступна${NC}"
    return 1
  fi
  open_firewall_port 80 tcp || return 1

  # DNS: без A-записи на этот сервер ACME не пройдёт даже с открытым :80.
  local domain="" server_ip="" resolved=""
  domain=$(get_server_domain 2>/dev/null || true)
  if [[ -n "$domain" ]]; then
    server_ip=$(get_server_ip 2>/dev/null || true)
    if command -v getent >/dev/null 2>&1; then
      resolved=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1 || true)
    fi
    if [[ -n "$resolved" && -n "$server_ip" && "$resolved" != "$server_ip" ]]; then
      echo -e "${YELLOW}  ⚠ DNS: ${domain} → ${resolved}, а IP сервера ${server_ip}.${NC}"
      echo -e "${YELLOW}    Продлите/исправьте A-запись, иначе ACME renew упадёт.${NC}"
    elif [[ -z "$resolved" ]]; then
      echo -e "${YELLOW}  ⚠ DNS: ${domain} не резолвится — проверьте A-запись (ожидается ${server_ip:-IP сервера}).${NC}"
    fi
  fi
  return 0
}

# ─── Итог диагностики ─────────────────────────────────────
_diag_report() {
  local remaining=$((_DIAG_PROBLEMS - _DIAG_FIXED))
  [[ "$remaining" -lt 0 ]] && remaining=0
  echo ""
  if [[ "$remaining" -eq 0 ]]; then
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            ✓ ВСЁ В ПОРЯДКЕ                ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
    echo -e "${GREEN}Исправлено: ${_DIAG_FIXED}, осталось проблем: 0${NC}"
  else
    echo -e "${YELLOW}Исправлено: ${_DIAG_FIXED}, осталось проблем: ${remaining}${NC}"
    echo -e "${YELLOW}  Повторите диагностику после устранения причин.${NC}"
  fi
  return 0
}

# ─── Главный сценарий диагностики ─────────────────────────
diagnose_and_repair() {
  _DIAG_PROBLEMS=0
  _DIAG_FIXED=0
  _DIAG_ABORT=0

  echo ""
  echo -e "${MAGENTA}═══ ДИАГНОСТИКА И ПОЧИНКА (7 проверок) ═══${NC}"
  echo ""

  _diag_step 1 "Xray запущен"                     _status_diag_1_xray    _status_repair_1_xray
  [[ "$_DIAG_ABORT" -eq 1 ]] && { _diag_report; return 1; }

  _diag_step 2 "Порт :443 слушает Xray"           _status_diag_2_port443 _status_repair_2_port443
  [[ "$_DIAG_ABORT" -eq 1 ]] && { _diag_report; return 1; }

  _diag_step 3 "Подписка установлена"             _status_diag_3_subscription _status_repair_3_subscription
  [[ "$_DIAG_ABORT" -eq 1 ]] && { _diag_report; return 1; }

  _diag_step 4 "Порт подписки слушается"          _status_diag_4_subport _status_repair_4_subport
  [[ "$_DIAG_ABORT" -eq 1 ]] && { _diag_report; return 1; }

  _diag_step 5 "Подписка отвечает локально"       _status_diag_5_subhttp _status_repair_5_subhttp
  [[ "$_DIAG_ABORT" -eq 1 ]] && { _diag_report; return 1; }

  _diag_step 6 "Сертификат действителен"          _status_diag_6_cert    _status_repair_6_cert
  [[ "$_DIAG_ABORT" -eq 1 ]] && { _diag_report; return 1; }

  _diag_step 7 "Порт 80 открыт (ACME renew)"      _status_diag_7_port80  _status_repair_7_port80

  _diag_report
  _status_pause
  [[ "$((_DIAG_PROBLEMS - _DIAG_FIXED))" -le 0 ]] && return 0
  return 1
}
