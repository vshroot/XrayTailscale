#!/bin/bash

# ═══════════════════════════════════════════════════════════
# XRAYTAILSCALE v2.0 - Xray Reality VPN + Tailscale exit node
# GitHub: https://github.com/vshroot/XrayTailscale
# License: MIT
# HAPP subscription + multi-route profile release
# ═══════════════════════════════════════════════════════════

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Пути
CONFIG_FILE="/usr/local/etc/xray/config.json"
PROFILES_DIR="/usr/local/etc/xray/profiles"
DATA_DIR="/usr/local/etc/xray/data"
UPSTREAMS_DIR="/usr/local/etc/xray/upstreams"
XRAY_BACKUPS_DIR="/usr/local/etc/xray/backups"
XRAY_BIN="/usr/local/bin/xray"
PRIVATE_KEY_FILE="/usr/local/etc/xray/.private_key"
PUBLIC_KEY_FILE="/usr/local/etc/xray/.public_key"
VLESS_DECRYPTION_FILE="/usr/local/etc/xray/.vless_decryption"
VLESS_ENCRYPTION_FILE="/usr/local/etc/xray/.vless_encryption"
SNI_LIST="$DATA_DIR/sni_list.txt"
ASCII_ART="$DATA_DIR/ascii_art.txt"
TAILSCALE_SYSCTL_FILE="/etc/sysctl.d/99-xraytailscale-tailscale.conf"
CASCADE_ACTIVE_FILE="/usr/local/etc/xray/.cascade_active"
LEGACY_TCP_TUNING_FILE="/etc/sysctl.d/99-xraytailscale-tcp.conf"
LEGACY_XRAYEBATOR_TCP_TUNING_FILE="/etc/sysctl.d/99-xrayebator-tcp.conf"
SYSTEM_SYSCTL_CONF="/etc/sysctl.conf"
TCP_CC_ACTIVE_FILE="/proc/sys/net/ipv4/tcp_congestion_control"
TCP_CC_AVAILABLE_FILE="/proc/sys/net/ipv4/tcp_available_congestion_control"
HOST_TUNING_MIGRATION_MARKER="/usr/local/etc/xray/.host_tcp_tuning_removed_v3"
SYSCTL_SCAN_PATHS="/etc/sysctl.conf:/etc/sysctl.d:/usr/lib/sysctl.d:/lib/sysctl.d"
DEFAULT_CLIENT_FINGERPRINT="firefox"
GITHUB_USER="${GITHUB_USER:-vshroot}"
GITHUB_REPO="${GITHUB_REPO:-XrayTailscale}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
RAW_BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"
GITHUB_RAW_AUTH_TOKEN="${XRAYTAILSCALE_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"

github_raw_curl() {
  local url="$1"
  shift

  if [[ -n "$GITHUB_RAW_AUTH_TOKEN" ]]; then
    curl -fsSL -H "Authorization: Bearer ${GITHUB_RAW_AUTH_TOKEN}" "$@" "$url"
  else
    curl -fsSL "$@" "$url"
  fi
}

# Хардкод-список SNI shipped в v1.0 sni_list.txt. Используется миграциями
# SNI v2.0+ — все, что НЕ в этом set, считается user-custom и не трогается.
# При расширении v2.0 list — обновить v2 set отдельно.
readonly -a KNOWN_DEFAULTS_v1=(
  # ru_whitelist priority 1
  "www.ozon.ru" "api.ozon.ru" "st.ozon.ru" "ir.ozon.ru"
  "www.wildberries.ru" "splitter.wb.ru"
  "www.sberbank.ru" "www.tinkoff.ru" "www.alfabank.ru"
  "www.nspk.ru" "sbp.nspk.ru"
  "stats.vk-portal.net" "sun6-21.userapi.com" "sun6-20.userapi.com"
  "queuev4.vk.com" "eh.vk.com"
  "www.kinopoisk.ru" "www.1tv.ru" "www.rbc.ru" "www.vedomosti.ru"
  "www.gosuslugi.ru" "www.mos.ru" "www.spb.gov.ru"
  # yandex_cdn priority 2
  "speller.yandex.net" "api-maps.yandex.ru" "spell.yandex.net"
  "advapi.yandex.net" "mc.yandex.ru" "suggest.yandex.ru"
  # foreign priority 3
  "www.github.com" "raw.githubusercontent.com" "api.github.com"
  "www.cloudflare.com" "cdn.cloudflare.net" "aws.amazon.com"
  # fallback priority 4
  "www.mozilla.org" "www.ubuntu.com" "www.debian.org"
  # Apple/iCloud (исторически — будут удалены)
  "apple.com" "www.apple.com" "icloud.com" "www.icloud.com"
)

# ═══════════════════════════════════════════════════════════
# SOURCE-SAFETY GUARD (Phase 7, REQ-C10)
# ═══════════════════════════════════════════════════════════
# Если xraytailscale source-ится из другого скрипта (subhttp.sh для HAPP subscription),
# мы НЕ должны выполнять root-check, загружать ключи Reality или входить в интерактивное
# main_menu — нужны только определения функций и констант.
# Тест: BASH_SOURCE[0] (путь к sourced-файлу) != ${0} (имя процесса) → значит source.
# В source-режиме мы ПРОПУСКАЕМ top-level эффекты (root-check, key-load, CLI dispatch),
# но определения функций ниже регистрируются как обычно.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  XRAYTAILSCALE_SOURCED=1
else
  XRAYTAILSCALE_SOURCED=0
fi

# Проверка прав root + загрузка ключей выполняются только при прямом запуске.
if [[ "$XRAYTAILSCALE_SOURCED" -eq 0 ]]; then
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}✗ Требуются права root${NC}"
    echo -e "${YELLOW}Используйте: sudo xraytailscale${NC}"
    exit 1
  fi

  # Загрузка ключей
  if [[ -f "$PRIVATE_KEY_FILE" ]] && [[ -f "$PUBLIC_KEY_FILE" ]]; then
    PRIVATE_KEY=$(cat "$PRIVATE_KEY_FILE")
    PUBLIC_KEY=$(cat "$PUBLIC_KEY_FILE")
    if [[ -z "$PRIVATE_KEY" ]] || [[ -z "$PUBLIC_KEY" ]]; then
      echo -e "${RED}✗ Ключи Reality пусты.${NC}"
      echo -e "${YELLOW}Пересоздайте ключи командой:${NC}"
      echo "  cd /usr/local/etc/xray/ && sudo /usr/local/bin/xray x25519 2>&1"
      exit 1
    fi
  else
    echo -e "${RED}✗ Ключи Reality не найдены. Запустите install.sh${NC}"
    exit 1
  fi
fi

# Получение внешнего IP
get_server_ip() {
  local ip=$(curl -s4 --connect-timeout 5 --max-time 10 ifconfig.me 2>/dev/null || \
             curl -s4 --connect-timeout 5 --max-time 10 icanhazip.com 2>/dev/null)
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I | awk '{print $1}')
  fi
  echo "$ip"
}

# ═══════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════

# Update SNI for all transport types (transport-aware)
# Args: $1=port, $2=new_sni, $3=config_file
