# ═══════════════════════════════════════════════════════════
# Self-steal: Reality маскируется под СОБСТВЕННЫЙ сайт
# ═══════════════════════════════════════════════════════════
# Схема:
#   клиент → VPS:443 (Xray VLESS+Reality+Vision, RAW TCP, uTLS firefox)
#   чужой наблюдатель/браузер → VPS:443 → Reality fallback → 127.0.0.1:<port>
#   (nginx с настоящим сайтом и валидным LE-сертификатом домена)
# Домен, IP и сертификат совпадают — нет расхождения SNI/сертификата,
# по которому выявляют классический Reality с чужим SNI.
#
# Зависимости: nginx, certbot (webroot HTTP-01 на :80), открытый :80 для renew.
# Xray НЕ читает сертификаты: он лишь проксирует TLS на локальный nginx,
# поэтому привилегии пользователя xray не расширяются.

SELFSTEAL_WEB_ROOT="/var/www/xraytailscale-selfsteal"
SELFSTEAL_NGINX_AVAILABLE="/etc/nginx/sites-available/xraytailscale-selfsteal.conf"
SELFSTEAL_NGINX_ENABLED="/etc/nginx/sites-enabled/xraytailscale-selfsteal.conf"
SELFSTEAL_DOMAIN_FILE="/usr/local/etc/xray/.selfsteal_domain"
SELFSTEAL_PORT_FILE="/usr/local/etc/xray/.selfsteal_backend_port"
SELFSTEAL_PROFILE_NAME="selfsteal"
SELFSTEAL_RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/xraytailscale-selfsteal-nginx.sh"

# ── Pure-генераторы (тестируются без root) ──────────────────

# HTTP-only конфиг: стадия 1 (до выпуска сертификата, ACME webroot).
_selfsteal_nginx_http_config() {
  local domain="$1"
  cat <<EOF
# XrayTailscale self-steal: ACME + редирект на HTTPS (Xray :443)
server {
    listen 80;
    server_name ${domain};
    root ${SELFSTEAL_WEB_ROOT};

    location /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
}

# Полный конфиг: стадия 2 (после выпуска LE-сертификата).
# TLS-сайт ТОЛЬКО на 127.0.0.1:<backend_port> — наружу смотрит Xray :443.
_selfsteal_nginx_config() {
  local domain="$1"
  local backend_port="$2"
  _selfsteal_nginx_http_config "$domain"
  cat <<EOF

# Self-steal backend: реальный сайт с валидным сертификатом ${domain}.
# Сюда Reality отправляет не-VLESS TLS (браузеры, активные зонды).
server {
    listen 127.0.0.1:${backend_port} ssl;
    server_name ${domain};

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

    root ${SELFSTEAL_WEB_ROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

# Правдоподобный статический сайт «фотоархив» (EN, без внешних ресурсов).
_selfsteal_write_site() {
  local domain="$1"
  local root="$SELFSTEAL_WEB_ROOT"
  mkdir -p "$root/assets" || return 1

  cat > "$root/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${domain} — Documentary Photo Archive</title>
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header>
  <h1>${domain}</h1>
  <p class="tagline">An independent archive of documentary photography.
  Northern landscapes, field notes and quiet places, digitised and preserved.</p>
  <nav><a href="/index.html">Gallery</a> · <a href="/about.html">About the archive</a></nav>
</header>
<main>
  <section class="grid">
    <figure><img src="/assets/photo-1.svg" alt="Ridge at dusk"><figcaption>Ridge at dusk, plate 001</figcaption></figure>
    <figure><img src="/assets/photo-2.svg" alt="Low tide"><figcaption>Low tide, plate 002</figcaption></figure>
    <figure><img src="/assets/photo-3.svg" alt="Taiga in fog"><figcaption>Taiga in fog, plate 003</figcaption></figure>
    <figure><img src="/assets/photo-4.svg" alt="Frozen lake"><figcaption>Frozen lake, plate 004</figcaption></figure>
    <figure><img src="/assets/photo-5.svg" alt="Night settlement"><figcaption>Night settlement, plate 005</figcaption></figure>
    <figure><img src="/assets/photo-6.svg" alt="Open steppe"><figcaption>Open steppe, plate 006</figcaption></figure>
  </section>
</main>
<footer>
  <p>Digitised from original medium-format negatives. For reproduction
  requests see the <a href="/about.html">about page</a>.</p>
  <p>&copy; 2019–2026 ${domain}</p>
</footer>
</body>
</html>
EOF

  cat > "$root/about.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>About — ${domain}</title>
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header>
  <h1>About the archive</h1>
  <nav><a href="/index.html">Gallery</a> · <a href="/about.html">About the archive</a></nav>
</header>
<main>
  <p>${domain} is a small non-commercial digitisation project. We scan
  medium-format negatives from northern expeditions and family collections,
  restore the emulsion damage where possible, and publish the plates under
  a permissive licence for researchers and educators.</p>
  <p>The archive is hosted on our own server. There is no tracking, no
  external fonts and no third-party requests: pages are plain HTML and SVG,
  exactly as the originals deserve.</p>
  <p>Reproduction requests: write to the archive maintainers via the postal
  address listed in the collection catalogue. New plates are published as
  scanning progresses; the current set covers plates 001–006.</p>
</main>
<footer><p>&copy; 2019–2026 ${domain}</p></footer>
</body>
</html>
EOF

  cat > "$root/assets/style.css" <<'EOF'
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; background: #14171b; color: #d7dce1;
       font-family: Georgia, 'Times New Roman', serif; line-height: 1.6; }
header { padding: 3rem 1.5rem 1.5rem; max-width: 960px; margin: 0 auto; }
h1 { font-weight: normal; letter-spacing: .04em; margin-bottom: .4rem; }
.tagline { color: #9aa4ad; max-width: 42rem; }
nav a, footer a { color: #8fb6d9; text-decoration: none; }
main { max-width: 960px; margin: 0 auto; padding: 1rem 1.5rem 3rem; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
        gap: 1.5rem; }
figure { margin: 0; background: #1b2026; padding: .8rem;
         border: 1px solid #2a3138; }
figure img { width: 100%; display: block; }
figcaption { font-size: .85rem; color: #9aa4ad; padding-top: .5rem; }
footer { max-width: 960px; margin: 0 auto; padding: 0 1.5rem 3rem;
         color: #7d868e; font-size: .85rem; }
EOF

  # «Пластины»: SVG с зерном плёнки (feTurbulence), разные палитры.
  local i
  local hues=("#2c3e50:#7f9bb3" "#3b4a3f:#a3b18a" "#4a3b32:#c9a227"
              "#26324b:#8ea9c9" "#1f1f2e:#b388eb" "#37474f:#90a4ae")
  local names=("RIDGE AT DUSK" "LOW TIDE" "TAIGA IN FOG"
               "FROZEN LAKE" "NIGHT SETTLEMENT" "OPEN STEPPE")
  for i in 1 2 3 4 5 6; do
    local pair="${hues[$((i-1))]}"
    local c1="${pair%%:*}" c2="${pair##*:}"
    cat > "$root/assets/photo-${i}.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 520">
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${c2}"/>
      <stop offset="1" stop-color="${c1}"/>
    </linearGradient>
    <filter id="grain">
      <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" result="n"/>
      <feColorMatrix in="n" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 0.06 0"/>
      <feBlend in="SourceGraphic" mode="overlay"/>
    </filter>
  </defs>
  <g filter="url(#grain)">
    <rect width="800" height="520" fill="url(#sky)"/>
    <path d="M0 $((300 + i * 12)) L160 $((220 + i * 9)) L340 $((310 - i * 7)) L520 $((200 + i * 11)) L700 $((290 + i * 5)) L800 $((240 + i * 8)) V520 H0 Z"
          fill="${c1}" opacity="0.85"/>
    <circle cx="$((120 + i * 90))" cy="$((90 + i * 14))" r="34" fill="${c2}" opacity="0.8"/>
    <text x="24" y="494" font-family="monospace" font-size="20" fill="#e8ecef"
          opacity="0.75">${names[$((i-1))]} — PLATE 00${i}</text>
  </g>
</svg>
EOF
  done

  printf 'User-agent: *\nAllow: /\n' > "$root/robots.txt"
  chmod -R a+rX "$root" 2>/dev/null || true
  return 0
}

# ── Preflight ───────────────────────────────────────────────

# Soft DNS check: расхождение = warning + подтверждение (split-DNS/CF proxy).
_selfsteal_dns_preflight() {
  local domain="$1"
  local server_ip resolved_ip
  server_ip=$(get_server_ip)
  resolved_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)
  if [[ -z "$resolved_ip" ]]; then
    echo -e "${YELLOW}  ⚠ $domain не резолвится. A-запись должна указывать на $server_ip${NC}"
    echo -n -e "${YELLOW}    Продолжить всё равно? [y/N]: ${NC}"
    local cont; read -r cont
    [[ "$cont" =~ ^[yYдД]$ ]]
    return
  fi
  if [[ "$resolved_ip" != "$server_ip" ]]; then
    echo -e "${YELLOW}  ⚠ DNS: $domain → $resolved_ip, но VPS IP = $server_ip${NC}"
    echo -e "${YELLOW}    Let's Encrypt скорее всего откажет.${NC}"
    echo -n -e "${YELLOW}    Продолжить? [y/N]: ${NC}"
    local cont; read -r cont
    [[ "$cont" =~ ^[yYдД]$ ]]
    return
  fi
  echo -e "${GREEN}  ✓ DNS: $domain → $server_ip (совпадает с VPS)${NC}"
  return 0
}

# Свободный localhost-порт для nginx backend (8443 может быть занят подпиской).
_selfsteal_pick_backend_port() {
  local p
  for p in 8443 9443 10443 11443 12443; do
    if ! ss -tlnH "sport = :$p" 2>/dev/null | grep -q .; then
      echo "$p"
      return 0
    fi
  done
  echo -e "${RED}✗ Нет свободного backend-порта из диапазона 8443–12443${NC}" >&2
  return 1
}

# Проверка inbound :443: self-steal несовместим с уже существующим обычным
# inbound на 443 (другой SNI или чужой dest). return 0 = можно продолжать.
_selfsteal_inbound_443_preflight() {
  local domain="$1" backend_dest="$2"
  jq -e '.inbounds[] | select(.port == 443)' "$CONFIG_FILE" >/dev/null 2>&1 || return 0
  local existing_sni existing_dest
  existing_sni=$(jq -r '.inbounds[] | select(.port == 443) | .streamSettings.realitySettings.serverNames[0] // ""' "$CONFIG_FILE" 2>/dev/null)
  existing_dest=$(jq -r '.inbounds[] | select(.port == 443) | .streamSettings.realitySettings.dest // ""' "$CONFIG_FILE" 2>/dev/null)
  if [[ "$existing_sni" != "$domain" || "$existing_dest" != "$backend_dest" ]]; then
    echo -e "${RED}✗ Порт 443 уже занят существующим inbound:${NC}"
    echo -e "  SNI:  ${CYAN}${existing_sni}${NC}"
    echo -e "  dest: ${CYAN}${existing_dest}${NC}"
    echo -e "${YELLOW}  Self-steal требует: SNI=${domain}, dest=${backend_dest}${NC}"
    echo -e "${YELLOW}  Удалите старый профиль на 443 (меню 2) или оставьте текущую схему.${NC}"
    return 1
  fi
  echo -e "${GREEN}  ✓ Inbound :443 уже self-steal для $domain — добавлю клиента${NC}"
  return 0
}

# ── Мастер установки ────────────────────────────────────────

selfsteal_setup() {
  show_ascii
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}   SELF-STEAL: свой сайт + VLESS Reality Vision ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${CYAN}Схема: VLESS + Reality + Vision (xtls-rprx-vision), RAW TCP :443,${NC}"
  echo -e "${CYAN}uTLS firefox. Reality маскируется под ВАШ сайт с LE-сертификатом:${NC}"
  echo -e "${CYAN}чужой HTTPS-заход на :443 увидит настоящий сайт фотоархива.${NC}"
  echo ""

  # Домен: автоподстановка сохранённого, ввод один раз.
  local domain
  domain=$(prompt_server_domain) || { sleep 2; return 1; }
  echo -e "${GREEN}  → Домен: $domain${NC}"

  if [[ -f "$SELFSTEAL_DOMAIN_FILE" && -f "$PROFILES_DIR/$SELFSTEAL_PROFILE_NAME.json" ]]; then
    echo -e "${YELLOW}Self-steal уже настроен ($(cat "$SELFSTEAL_DOMAIN_FILE")).${NC}"
    selfsteal_show_link
    return 0
  fi

  _selfsteal_dns_preflight "$domain" || return 1

  local backend_port
  backend_port=$(_selfsteal_pick_backend_port) || { sleep 2; return 1; }
  local backend_dest="127.0.0.1:${backend_port}"
  echo -e "${CYAN}  → Backend nginx: $backend_dest${NC}"

  _selfsteal_inbound_443_preflight "$domain" "$backend_dest" || { sleep 3; return 1; }

  # :443 не должен быть занят чужим процессом (nginx/apache/3x-ui).
  if ! jq -e '.inbounds[] | select(.port == 443)' "$CONFIG_FILE" >/dev/null 2>&1; then
    local listener
    listener=$(ss -tlnpH 'sport = :443' 2>/dev/null | head -1)
    if [[ -n "$listener" && "$listener" != *xray* ]]; then
      echo -e "${RED}✗ Порт 443 занят процессом:${NC} $listener"
      echo -e "${YELLOW}  Освободите 443 для Xray и повторите.${NC}"
      sleep 3
      return 1
    fi
  fi

  # Email для LE (как в публичной подписке).
  local email
  echo -n -e "${YELLOW}Email для Let's Encrypt (восстановление аккаунта): ${NC}"
  read -r email
  if [[ -z "$email" ]] || ! [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    echo -e "${RED}✗ Некорректный email${NC}"
    sleep 2
    return 1
  fi

  echo -e "${CYAN}  → Установка nginx + certbot...${NC}"
  if ! apt-get install -y nginx certbot; then
    echo -e "${RED}✗ apt-get install nginx certbot не удалось${NC}"
    return 1
  fi

  echo -e "${CYAN}  → Генерация сайта фотоархива в $SELFSTEAL_WEB_ROOT...${NC}"
  _selfsteal_write_site "$domain" || { echo -e "${RED}✗ Не удалось записать сайт${NC}"; return 1; }

  # Стадия 1: HTTP-only (ACME webroot), затем certbot.
  _selfsteal_nginx_http_config "$domain" > "$SELFSTEAL_NGINX_AVAILABLE" || return 1
  ln -sf "$SELFSTEAL_NGINX_AVAILABLE" "$SELFSTEAL_NGINX_ENABLED"
  systemctl enable nginx >/dev/null 2>&1 || true
  if ! nginx -t; then
    echo -e "${RED}✗ nginx -t не прошёл (HTTP-конфиг)${NC}"
    return 1
  fi
  systemctl restart nginx || { echo -e "${RED}✗ nginx не стартовал${NC}"; return 1; }

  # :80 для HTTP-01 challenge и будущих renew.
  open_firewall_port 80 tcp || \
    echo -e "${YELLOW}  ⚠ Не удалось открыть 80/tcp через UFW — откройте вручную для renew${NC}"

  local certbot_bin
  if [[ -x /snap/bin/certbot ]]; then
    certbot_bin="/snap/bin/certbot"
  else
    certbot_bin=$(command -v certbot 2>/dev/null || true)
  fi
  [[ -n "$certbot_bin" ]] || { echo -e "${RED}✗ certbot не найден${NC}"; return 1; }

  echo -e "${CYAN}  → Выпуск LE-сертификата для $domain (webroot HTTP-01)...${NC}"
  if ! "$certbot_bin" certonly --webroot -w "$SELFSTEAL_WEB_ROOT" \
        -d "$domain" --non-interactive --agree-tos -m "$email" \
        --keep-until-expiring; then
    echo -e "${RED}✗ certbot не выпустил сертификат${NC}"
    echo -e "${YELLOW}  Проверьте DNS и доступность http://${domain}/.well-known/acme-challenge/ снаружи.${NC}"
    return 1
  fi
  [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] || {
    echo -e "${RED}✗ Сертификат не найден в /etc/letsencrypt/live/${domain}/${NC}"
    return 1
  }

  # Стадия 2: полный конфиг с TLS-backend на 127.0.0.1:<port>.
  _selfsteal_nginx_config "$domain" "$backend_port" > "$SELFSTEAL_NGINX_AVAILABLE" || return 1
  if ! nginx -t; then
    echo -e "${RED}✗ nginx -t не прошёл (TLS-конфиг)${NC}"
    return 1
  fi
  systemctl reload nginx || systemctl restart nginx || return 1

  # Reload nginx после каждого renew (deploy-hook).
  mkdir -p "$(dirname "$SELFSTEAL_RENEW_HOOK")"
  printf '#!/bin/sh\nsystemctl reload nginx\n' > "$SELFSTEAL_RENEW_HOOK"
  chmod 755 "$SELFSTEAL_RENEW_HOOK"

  # Self-check: backend отвечает валидным TLS с нашим доменом.
  if curl -fsS --max-time 10 --resolve "${domain}:${backend_port}:127.0.0.1" \
       "https://${domain}:${backend_port}/" >/dev/null 2>&1; then
    echo -e "${GREEN}  ✓ Backend self-check: https://${domain}:${backend_port} отвечает${NC}"
  else
    echo -e "${YELLOW}  ⚠ Backend self-check не прошёл — проверьте: curl -vk --resolve ${domain}:${backend_port}:127.0.0.1 https://${domain}:${backend_port}/${NC}"
  fi

  # Профиль + inbound: create_profile сам делает backup/validate/restart.
  echo -e "${CYAN}  → Создание профиля '$SELFSTEAL_PROFILE_NAME' (VLESS+Reality+Vision :443, dest=$backend_dest)...${NC}"
  if ! create_profile "$SELFSTEAL_PROFILE_NAME" tcp 443 firefox "$domain" "" "" "" "$backend_dest"; then
    echo -e "${RED}✗ Профиль не создан. Сайт и сертификат оставлены — повторите мастер после разбора.${NC}"
    return 1
  fi

  # Клиент подключается по домену: адрес/SNI/сертификат совпадают.
  safe_jq_write --arg addr "$domain" '.server_address = $addr' \
    "$PROFILES_DIR/$SELFSTEAL_PROFILE_NAME.json" || \
    echo -e "${YELLOW}  ⚠ Не удалось записать server_address в профиль${NC}"

  printf '%s\n' "$domain" > "$SELFSTEAL_DOMAIN_FILE"
  printf '%s\n' "$backend_port" > "$SELFSTEAL_PORT_FILE"
  fix_xray_permissions

  echo ""
  echo -e "${GREEN}✓ Self-steal развёрнут: https://${domain} для чужих = ваш сайт,${NC}"
  echo -e "${GREEN}  для ваших клиентов = VLESS+Reality+Vision.${NC}"
  selfsteal_show_link
}

# ── Ссылка / статус / удаление ──────────────────────────────

selfsteal_show_link() {
  local profile_file="$PROFILES_DIR/$SELFSTEAL_PROFILE_NAME.json"
  if [[ ! -f "$profile_file" ]]; then
    echo -e "${RED}✗ Профиль $SELFSTEAL_PROFILE_NAME не найден — сначала запустите установку${NC}"
    sleep 2
    return 1
  fi
  local vless_link
  vless_link=$(_generate_vless_url_pure "$profile_file") || {
    echo -e "${RED}✗ Не удалось построить vless:// (inbound :443 жив? проверьте systemctl status xray)${NC}"
    sleep 3
    return 1
  }
  echo ""
  echo -e "${BLUE}Параметры self-steal:${NC}"
  echo -e "  ${CYAN}Домен:${NC}   $(cat "$SELFSTEAL_DOMAIN_FILE" 2>/dev/null)"
  echo -e "  ${CYAN}Порт:${NC}    443 (RAW TCP)"
  echo -e "  ${CYAN}Flow:${NC}    xtls-rprx-vision"
  echo -e "  ${CYAN}SNI/fp:${NC}  $(jq -r '.sni' "$profile_file") / $(jq -r '.fingerprint' "$profile_file")"
  echo -e "  ${CYAN}dest:${NC}    127.0.0.1:$(cat "$SELFSTEAL_PORT_FILE" 2>/dev/null) (локальный nginx)"
  echo ""
  echo -e "${BLUE}Ссылка для подключения:${NC}"
  echo -e "${YELLOW}${vless_link}${NC}"
  echo ""
  qrencode -t ANSIUTF8 "$vless_link" 2>/dev/null || true
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read -r _
}

selfsteal_status() {
  show_ascii
  echo -e "${BLUE}═══ SELF-STEAL STATUS ═══${NC}"
  if [[ ! -f "$SELFSTEAL_DOMAIN_FILE" ]]; then
    echo -e "${YELLOW}Self-steal не настроен.${NC}"
  else
    local domain backend_port
    domain=$(cat "$SELFSTEAL_DOMAIN_FILE")
    backend_port=$(cat "$SELFSTEAL_PORT_FILE" 2>/dev/null)
    echo -e "${CYAN}Домен:${NC}         $domain"
    echo -e "${CYAN}Backend:${NC}       127.0.0.1:${backend_port}"
    echo -e "${CYAN}nginx:${NC}         $(systemctl is-active nginx 2>/dev/null)"
    if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
      echo -e "${CYAN}Сертификат:${NC}    $(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${domain}/fullchain.pem" 2>/dev/null)"
    else
      echo -e "${RED}Сертификат не найден${NC}"
    fi
    echo -e "${CYAN}Inbound :443:${NC}"
    jq -r '.inbounds[] | select(.port == 443) |
      "  sni=\(.streamSettings.realitySettings.serverNames[0]) dest=\(.streamSettings.realitySettings.dest) clients=\(.settings.clients | length)"' \
      "$CONFIG_FILE" 2>/dev/null || echo "  (нет)"
    if curl -fsS --max-time 8 --resolve "${domain}:${backend_port}:127.0.0.1" \
         "https://${domain}:${backend_port}/" >/dev/null 2>&1; then
      echo -e "${GREEN}Backend TLS: OK${NC}"
    else
      echo -e "${YELLOW}Backend TLS: не отвечает${NC}"
    fi
  fi
  echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
  read -r _
}

selfsteal_remove() {
  local domain
  domain=$(cat "$SELFSTEAL_DOMAIN_FILE" 2>/dev/null)
  echo -e "${YELLOW}Удалить self-steal сайт и nginx-конфиг${NC}${domain:+ для $domain}?"
  echo -n -e "${YELLOW}Подтвердите [y/N]: ${NC}"
  local ans; read -r ans
  [[ "$ans" =~ ^[yYдД]$ ]] || return 0

  rm -f "$SELFSTEAL_NGINX_ENABLED" "$SELFSTEAL_NGINX_AVAILABLE" "$SELFSTEAL_RENEW_HOOK"
  rm -rf "$SELFSTEAL_WEB_ROOT"
  if command -v nginx >/dev/null 2>&1 && nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || true
  fi
  rm -f "$SELFSTEAL_DOMAIN_FILE" "$SELFSTEAL_PORT_FILE"
  echo -e "${GREEN}✓ Сайт и nginx-конфиг self-steal удалены${NC}"
  echo -e "${YELLOW}⚠ Профиль '$SELFSTEAL_PROFILE_NAME' и inbound :443 НЕ удалены автоматически.${NC}"
  echo -e "${YELLOW}  Удалите профиль через меню 2 — иначе Reality dest указывает на несуществующий сайт.${NC}"
  if [[ -n "$domain" && -d "/etc/letsencrypt/live/${domain}" ]]; then
    echo -e "${YELLOW}  Сертификат LE оставлен. Удалить вручную: certbot delete --cert-name ${domain}${NC}"
  fi
  sleep 3
}

selfsteal_menu() {
  while true; do
    show_ascii
    echo -e "${MAGENTA}═══ SELF-STEAL (свой сайт + Reality Vision :443) ═══${NC}"
    if [[ -f "$SELFSTEAL_DOMAIN_FILE" ]]; then
      echo -e "${CYAN}Текущий домен: $(cat "$SELFSTEAL_DOMAIN_FILE")${NC}"
    else
      echo -e "${CYAN}Не настроен. Домен: $(get_server_domain || echo "не задан")${NC}"
    fi
    echo ""
    echo -e "${CYAN}1)${NC} Установить / настроить self-steal"
    echo -e "${CYAN}2)${NC} Статус (nginx, сертификат, inbound)"
    echo -e "${CYAN}3)${NC} Показать ссылку и QR"
    echo -e "${CYAN}4)${NC} Удалить self-steal (сайт/nginx)"
    echo -e "${RED}0)${NC} Назад"
    echo -n -e "${YELLOW}Выберите действие: ${NC}"
    local choice
    read -r choice
    case "$choice" in
      1) selfsteal_setup ;;
      2) selfsteal_status ;;
      3) selfsteal_show_link ;;
      4) selfsteal_remove ;;
      0) return ;;
      *) echo -e "${RED}Неверный выбор${NC}"; sleep 1 ;;
    esac
  done
}
