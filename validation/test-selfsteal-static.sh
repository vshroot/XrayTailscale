#!/bin/bash
# test-selfsteal-static.sh — self-steal: nginx-генераторы, сайт, add_inbound dest,
# per-profile server_address в vless:// URL. Без root: конфиги в WORKDIR.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR=$(mktemp -d /tmp/xraytailscale-selfsteal.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck disable=SC1091
source "$REPO_ROOT/xraytailscale"

DOMAIN="northphoto-archive.org"

# ── nginx: полный конфиг (стадия 2) ──
conf=$(_selfsteal_nginx_config "$DOMAIN" 8443)
echo "$conf" | grep -q 'listen 127.0.0.1:8443 ssl;' || fail "backend не на 127.0.0.1:8443 ssl"
echo "$conf" | grep -q "server_name ${DOMAIN};" || fail "server_name отсутствует"
echo "$conf" | grep -q "ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;" || fail "ssl_certificate путь неверен"
echo "$conf" | grep -q "ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;" || fail "ssl_certificate_key путь неверен"
echo "$conf" | grep -q 'location /.well-known/acme-challenge/' || fail "ACME webroot location отсутствует"
echo "$conf" | grep -q 'return 301 https://$host$request_uri;' || fail "HTTP→HTTPS редирект отсутствует"
echo "$conf" | grep -q 'listen 80;' || fail "HTTP listener :80 отсутствует"

# ── nginx: HTTP-only (стадия 1, до выпуска сертификата) ──
http_conf=$(_selfsteal_nginx_http_config "$DOMAIN")
echo "$http_conf" | grep -q 'listen 80;' || fail "стадия 1: нет listen 80"
! echo "$http_conf" | grep -q 'ssl_certificate' || fail "стадия 1 должна быть HTTP-only (сертификата ещё нет)"

# ── Сайт фотоархива ──
SELFSTEAL_WEB_ROOT="$WORKDIR/webroot"
_selfsteal_write_site "$DOMAIN" || fail "генерация сайта не удалась"
[[ -f "$SELFSTEAL_WEB_ROOT/index.html" ]] || fail "index.html не создан"
[[ -f "$SELFSTEAL_WEB_ROOT/about.html" ]] || fail "about.html не создан"
[[ -f "$SELFSTEAL_WEB_ROOT/assets/style.css" ]] || fail "style.css не создан"
[[ -f "$SELFSTEAL_WEB_ROOT/robots.txt" ]] || fail "robots.txt не создан"
for i in 1 2 3 4 5 6; do
  [[ -f "$SELFSTEAL_WEB_ROOT/assets/photo-$i.svg" ]] || fail "photo-$i.svg не создан"
done
grep -q "$DOMAIN" "$SELFSTEAL_WEB_ROOT/index.html" || fail "домен не подставлен в сайт"
! grep -q '\${((' "$SELFSTEAL_WEB_ROOT/assets/photo-1.svg" || fail "арифметика SVG не раскрыта"

# ── add_inbound с явным reality_dest (self-steal) ──
CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
PUBLIC_KEY_FILE="$WORKDIR/.public_key"
mkdir -p "$PROFILES_DIR"
echo '{"inbounds":[]}' > "$CONFIG_FILE"
echo "test-public-key" > "$PUBLIC_KEY_FILE"
PRIVATE_KEY="test-private-key"
open_firewall_port() { return 0; }  # UFW noop в тесте

uuid="11111111-2222-3333-4444-555555555555"
add_inbound "$uuid" tcp 443 "$DOMAIN" firefox "" "" "" "127.0.0.1:8443" >/dev/null || \
  fail "add_inbound self-steal не удался"
[[ $(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$CONFIG_FILE") == "127.0.0.1:8443" ]] || \
  fail "dest != 127.0.0.1:8443"
[[ $(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG_FILE") == "$DOMAIN" ]] || \
  fail "serverNames[0] != домен"
[[ $(jq -r '.inbounds[0].settings.clients[0].flow' "$CONFIG_FILE") == "xtls-rprx-vision" ]] || \
  fail "flow != xtls-rprx-vision"
[[ $(jq -r '.inbounds[0].streamSettings.network' "$CONFIG_FILE") == "tcp" ]] || fail "network != tcp"
[[ $(jq -r '.inbounds[0].streamSettings.security' "$CONFIG_FILE") == "reality" ]] || fail "security != reality"

# ── Дефолт без reality_dest: поведение не изменилось ──
uuid2="22222222-3333-4444-5555-666666666666"
add_inbound "$uuid2" tcp 8443 www.ozon.ru firefox "" "" "" "" >/dev/null || fail "add_inbound default не удался"
[[ $(jq -r '.inbounds[] | select(.port == 8443) | .streamSettings.realitySettings.dest' "$CONFIG_FILE") == "www.ozon.ru:443" ]] || \
  fail "дефолтный dest изменился (регрессия)"

# ── Per-profile server_address в vless:// (подключение по домену) ──
cat > "$PROFILES_DIR/selfsteal.json" <<EOF
{"name":"selfsteal","uuid":"$uuid","transport":"tcp","port":443,
 "fingerprint":"firefox","sni":"$DOMAIN","server_address":"$DOMAIN"}
EOF
url=$(_generate_vless_url_pure "$PROFILES_DIR/selfsteal.json") || fail "URL для self-steal профиля не построен"
[[ "$url" == *"@${DOMAIN}:443?"* ]] || fail "URL не содержит домен как адрес: $url"
[[ "$url" == *"sni=${DOMAIN}"* ]] || fail "URL не содержит sni=домен"
[[ "$url" == *"fp=firefox"* ]] || fail "URL не содержит fp=firefox"
[[ "$url" == *"flow=xtls-rprx-vision"* ]] || fail "URL не содержит Vision flow"
[[ "$url" == *"type=tcp"* ]] || fail "URL не содержит type=tcp"
[[ "$url" == *"pbk=test-public-key"* ]] || fail "URL не содержит public key"

# Профиль БЕЗ server_address → адрес не домен (глобальная логика, override)
cat > "$PROFILES_DIR/plain.json" <<EOF
{"name":"plain","uuid":"$uuid","transport":"tcp","port":443,
 "fingerprint":"firefox","sni":"$DOMAIN"}
EOF
XRAYTAILSCALE_SERVER_ADDR_OVERRIDE="203.0.113.10"
url2=$(_generate_vless_url_pure "$PROFILES_DIR/plain.json") || fail "URL для plain профиля не построен"
[[ "$url2" == *"@203.0.113.10:443?"* ]] || fail "plain профиль: глобальный адрес не применился"
unset XRAYTAILSCALE_SERVER_ADDR_OVERRIDE

# ── Меню: пункт 16 маршрутизирует в selfsteal_menu ──
grep -q '16) selfsteal_menu' "$REPO_ROOT/xraytailscale" || \
  fail "главное меню: пункт 16 не ведёт в selfsteal_menu"

echo "PASS: selfsteal (nginx/site/reality_dest/server_address/menu)"
