#!/bin/bash
# test-selfsteal-convert.sh — конвертация главного inbound в self-steal:
# выбор кандидата, перенос порта на :443, Vision flow, dest/serverNames,
# сохранение UUID/shortIds, синхронизация профилей, перенос подписки 443→8443.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR=$(mktemp -d /tmp/xraytailscale-ssconvert.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck disable=SC1091
source "$REPO_ROOT/xraytailscale"

CONFIG_FILE="$WORKDIR/config.json"
PROFILES_DIR="$WORKDIR/profiles"
mkdir -p "$PROFILES_DIR"

# ── Фикстура: главный tcp inbound :44367 (2 клиента, чужой SNI) ──
# плюс xhttp :8443 (1 клиент) — конвертации подлежит только первый.
cat > "$CONFIG_FILE" <<'EOF'
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 44367,
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "11111111-2222-3333-4444-555555555555", "flow": ""},
          {"id": "22222222-3333-4444-5555-666666666666", "flow": ""}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.ozon.ru:443",
          "xver": 0,
          "serverNames": ["www.ozon.ru"],
          "privateKey": "PRIVKEY-KEEP-ME",
          "shortIds": ["sid-keep-1"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true},
      "tag": "inbound-44367"
    },
    {
      "listen": "0.0.0.0",
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "33333333-4444-5555-6666-777777777777"}],
        "decryption": "mlkem768x25519plus.test"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {"mode": "stream-one", "path": "/xhttp"},
        "realitySettings": {
          "dest": "www.ozon.ru:443",
          "serverNames": ["www.ozon.ru"],
          "privateKey": "PRIVKEY-KEEP-ME",
          "shortIds": ["sid-xhttp"]
        }
      },
      "tag": "inbound-8443"
    }
  ]
}
EOF

cat > "$PROFILES_DIR/main.json" <<'EOF'
{"name":"main","uuid":"11111111-2222-3333-4444-555555555555","transport":"tcp","port":44367,
 "fingerprint":"chrome","sni":"www.ozon.ru","sub_token":"a1b2c3d4e5f60718293a4b5c6d7e8f90","created":"2026-01-01 00:00:00"}
EOF
cat > "$PROFILES_DIR/second.json" <<'EOF'
{"name":"second","uuid":"22222222-3333-4444-5555-666666666666","transport":"tcp","port":44367,
 "fingerprint":"chrome","sni":"www.ozon.ru","sub_token":"b1b2c3d4e5f60718293a4b5c6d7e8f91","created":"2026-01-01 00:00:00"}
EOF

# Stubs: конвертация не должна трогать реальный диск/сервисы.
backup_config() { local _n="$1" _out="$2"; cp "$CONFIG_FILE" "$WORKDIR/backup.json"; printf -v "$_out" '%s' "$WORKDIR/backup.json"; return 0; }
open_firewall_port() { return 0; }
close_firewall_port() { return 0; }
safe_restart_xray() { return 0; }

# ── Выбор кандидата: max клиентов (44367, а не 8443) ──
picked=$(_selfsteal_pick_convert_port)
[[ "$picked" == "44367" ]] || fail "pick_convert_port: ожидался 44367 (max clients), получено '$picked'"

# ── Конвертация ──
_selfsteal_convert_inbound 44367 example.com 127.0.0.1:9443 >/dev/null || \
  fail "_selfsteal_convert_inbound вернула ошибку"

# config.json: порт/тег/dest/SNI/flow
jq -e '.inbounds[] | select(.port == 44367)' "$CONFIG_FILE" >/dev/null && fail "inbound :44367 остался после конвертации"
[[ $(jq -r '.inbounds[] | select(.port == 443) | .tag' "$CONFIG_FILE") == "inbound-443" ]] || fail "tag != inbound-443"
[[ $(jq -r '.inbounds[] | select(.port == 443) | .streamSettings.network' "$CONFIG_FILE") == "tcp" ]] || fail "network != tcp"
[[ $(jq -r '.inbounds[] | select(.port == 443) | .streamSettings.realitySettings.dest' "$CONFIG_FILE") == "127.0.0.1:9443" ]] || fail "dest != 127.0.0.1:9443"
[[ $(jq -r '.inbounds[] | select(.port == 443) | .streamSettings.realitySettings.serverNames[0]' "$CONFIG_FILE") == "example.com" ]] || fail "serverNames[0] != example.com"
jq -e 'all(.inbounds[] | select(.port == 443) | .settings.clients[]; .flow == "xtls-rprx-vision")' "$CONFIG_FILE" >/dev/null || \
  fail "не все клиенты получили flow xtls-rprx-vision"

# Сохранение ключей/UUID/shortIds
[[ $(jq -r '.inbounds[] | select(.port == 443) | .streamSettings.realitySettings.privateKey' "$CONFIG_FILE") == "PRIVKEY-KEEP-ME" ]] || fail "privateKey не сохранён"
[[ $(jq -r '.inbounds[] | select(.port == 443) | .streamSettings.realitySettings.shortIds[0]' "$CONFIG_FILE") == "sid-keep-1" ]] || fail "shortIds не сохранены"
[[ $(jq -r '.inbounds[] | select(.port == 443) | .settings.clients[0].id' "$CONFIG_FILE") == "11111111-2222-3333-4444-555555555555" ]] || fail "UUID клиента не сохранён"

# Чужой inbound :8443 не тронут
[[ $(jq -r '.inbounds[] | select(.port == 8443) | .streamSettings.network' "$CONFIG_FILE") == "xhttp" ]] || fail "xhttp :8443 повреждён (network)"
[[ $(jq -r '.inbounds[] | select(.port == 8443) | .settings.decryption' "$CONFIG_FILE") == "mlkem768x25519plus.test" ]] || fail "xhttp :8443 повреждён (decryption)"

# Профили синхронизированы
for p in main second; do
  [[ $(jq -r '.port' "$PROFILES_DIR/$p.json") == "443" ]] || fail "$p: port != 443"
  [[ $(jq -r '.sni' "$PROFILES_DIR/$p.json") == "example.com" ]] || fail "$p: sni != example.com"
  [[ $(jq -r '.fingerprint' "$PROFILES_DIR/$p.json") == "firefox" ]] || fail "$p: fingerprint != firefox"
  [[ $(jq -r '.transport' "$PROFILES_DIR/$p.json") == "tcp" ]] || fail "$p: transport != tcp"
  [[ $(jq -r '.server_address' "$PROFILES_DIR/$p.json") == "example.com" ]] || fail "$p: server_address != example.com"
done

# После конвертации pick обязан видеть :443
picked=$(_selfsteal_pick_convert_port)
[[ "$picked" == "443" ]] || fail "после конвертации pick_convert_port != 443"

# Профиль на :443 находится поиском (имя произвольное)
found=$(_selfsteal_profile_file_on_443)
[[ "$found" == "$PROFILES_DIR/main.json" || "$found" == "$PROFILES_DIR/second.json" ]] || \
  fail "_selfsteal_profile_file_on_443 не нашёл профиль: '$found'"

# vless:// генерируется из сконвертированного состояния (live-config guard проходит)
PUBLIC_KEY_FILE="$WORKDIR/.public_key"
echo "pubkey-test" > "$PUBLIC_KEY_FILE"
url=$(_generate_vless_url_pure "$PROFILES_DIR/main.json") || fail "URL не построен после конвертации"
[[ "$url" == *"@example.com:443?"* ]] || fail "URL: адрес != example.com:443 → $url"
[[ "$url" == *"sni=example.com"* ]] || fail "URL: нет sni=example.com"
[[ "$url" == *"flow=xtls-rprx-vision"* ]] || fail "URL: нет vision flow"
[[ "$url" == *"sid=sid-keep-1"* ]] || fail "URL: shortId не сохранён"
[[ "$url" == *"pbk=pubkey-test"* ]] || fail "URL: нет public key"

# ── Перенос nginx-подписки :443 → :8443 ──
SELFSTEAL_SUB_NGINX_AVAILABLE="$WORKDIR/nginx/sites-available/xraytailscale-sub"
SUBSCRIPTION_PORT_FILE="$WORKDIR/.subscription_port"
mkdir -p "$(dirname "$SELFSTEAL_SUB_NGINX_AVAILABLE")"
cat > "$SELFSTEAL_SUB_NGINX_AVAILABLE" <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name 195.246.230.219;
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name 195.246.230.219;
}
EOF
nginx() { return 0; }        # nginx -t всегда ок в тесте
systemctl() { return 0; }    # reload noop
_selfsteal_free_443_from_nginx >/dev/null || fail "_selfsteal_free_443_from_nginx вернула ошибку"
! grep -qE 'listen[[:space:]]+(\[::\]:)?443[[:space:]]+ssl' "$SELFSTEAL_SUB_NGINX_AVAILABLE" || \
  fail "nginx конфиг всё ещё слушает 443 ssl"
grep -q 'listen 8443 ssl http2;' "$SELFSTEAL_SUB_NGINX_AVAILABLE" || fail "listen 8443 ssl http2 не появился"
grep -q 'listen \[::\]:8443 ssl http2;' "$SELFSTEAL_SUB_NGINX_AVAILABLE" || fail "IPv6 listen 8443 не появился"
[[ $(cat "$SUBSCRIPTION_PORT_FILE") == "8443" ]] || fail ".subscription_port != 8443"

# Чужой конфиг (нет нашего сайта) → отказ
SELFSTEAL_SUB_NGINX_AVAILABLE="$WORKDIR/nginx/sites-available/unknown"
! _selfsteal_free_443_from_nginx >/dev/null 2>&1 || fail "чужой listener должен давать отказ"

# ── CLI/интеграция: сабкоманда и env-автодеплой ──
grep -q 'selfsteal-auto)' "$REPO_ROOT/xraytailscale" || fail "dispatch: нет сабкоманды selfsteal-auto"
grep -q 'selfsteal_auto_command' "$REPO_ROOT/xraytailscale" || fail "dispatch: не вызывается selfsteal_auto_command"
grep -q 'XT_DOMAIN' "$REPO_ROOT/install.sh" || fail "install.sh: нет XT_DOMAIN автодеплоя"
grep -q 'selfsteal-auto' "$REPO_ROOT/install.sh" || fail "install.sh: не вызывается selfsteal-auto"
grep -q 'selfsteal_autoconvert_seen' "$REPO_ROOT/xraytailscale" || fail "main_menu: нет авто-конвертации с маркером"

echo "PASS: selfsteal convert (pick/inbound/profiles/nginx-relocate/CLI/install)"
