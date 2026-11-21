#!/bin/bash

# ═══════════════════════════════════════════════════════════
# XRAYTAILSCALE UPDATE SCRIPT v2.0
# Обновление XrayTailscale до последней версии
# GitHub: https://github.com/vshroot/XrayTailscale
# ═══════════════════════════════════════════════════════════

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# GitHub репозиторий
GITHUB_USER="${GITHUB_USER:-vshroot}"
GITHUB_REPO="${GITHUB_REPO:-XrayTailscale}"
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

# ═══════════════════════════════════════════════════════════
# ADGUARD HOME CLEANUP (deprecated в v2.0 — Plan 8.3)
# ═══════════════════════════════════════════════════════════
# AdGuard Home убирается как deprecated. CRITICAL ORDERING:
# DNS rollback ДО stop AdGuard, иначе возникает DNS black-hole window.
# Wrapped в функцию: `local` нельзя использовать на top-level update.sh.
_adguard_force_uninstall_if_present() {
  if [[ ! -f /opt/AdGuardHome/AdGuardHome ]]; then
    return 0
  fi

  echo ""
  echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${YELLOW}Deprecated AdGuard Home detected${NC}"
  echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}AdGuard Home is being removed as deprecated (previous releases${NC}"
  echo -e "${CYAN}had bugs in DNS filters). Removing automatically...${NC}"
  echo ""

  local cfg="${CONFIG_FILE:-/usr/local/etc/xray/config.json}"
  if [[ -f "$cfg" ]]; then
    echo -e "${CYAN}Step 1/5: Restoring Xray DNS (before stopping AdGuard)...${NC}"
    local _tmp
    _tmp=$(mktemp /tmp/xray-cfg.XXXXXX) || {
      echo -e "${RED}  mktemp failed — DNS rollback skipped${NC}"
      _tmp=""
    }
    if [[ -n "$_tmp" ]] && jq '.dns = {
      "servers": [
        "https+local://1.1.1.1/dns-query",
        "localhost"
      ],
      "queryStrategy": "UseIPv4",
      "disableCache": false
    }' "$cfg" > "$_tmp" 2>/dev/null \
       && [[ -s "$_tmp" ]] \
       && xray run -test -config "$_tmp" 2>&1 | grep -q "^Configuration OK\\.$"; then
      mv "$_tmp" "$cfg"
      chmod 644 "$cfg"
      chown xray:xray "$cfg" 2>/dev/null || true
      echo -e "${GREEN}  DNS rollback -> DoH Local (1.1.1.1)${NC}"
    else
      rm -f "$_tmp"
      echo -e "${YELLOW}  DNS rollback skipped (validation failed)${NC}"
    fi
  fi

  echo -e "${CYAN}Step 2/5: Stopping AdGuard Home...${NC}"
  systemctl stop AdGuardHome 2>/dev/null || true
  systemctl disable AdGuardHome 2>/dev/null || true
  /opt/AdGuardHome/AdGuardHome -s uninstall 2>/dev/null || true
  echo -e "${GREEN}  Service stopped${NC}"

  echo -e "${CYAN}Step 3/5: Removing /opt/AdGuardHome/ files...${NC}"
  rm -rf /opt/AdGuardHome/
  rm -f /etc/systemd/resolved.conf.d/adguardhome.conf
  echo -e "${GREEN}  Files removed${NC}"

  echo -e "${CYAN}Step 4/5: Restoring systemd-resolved...${NC}"
  if [[ -L /etc/resolv.conf ]] || [[ -f /etc/resolv.conf ]]; then
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
  fi
  systemctl restart systemd-resolved 2>/dev/null || true
  echo -e "${GREEN}  systemd-resolved restarted${NC}"

  echo -e "${CYAN}Step 5/5: UFW cleanup (port 53)...${NC}"
  if command -v ufw &>/dev/null; then
    ufw delete allow 53/tcp >/dev/null 2>&1
    ufw delete allow 53/udp >/dev/null 2>&1
    ufw delete allow 3000/tcp >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
  fi
  echo -e "${GREEN}  UFW checked${NC}"

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║  AdGuard Home removed. Xray DNS -> DoH Local (1.1.1.1)    ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  if [[ -f "$cfg" ]] && systemctl is-active --quiet xray; then
    if xray run -test -config "$cfg" 2>&1 | grep -q "^Configuration OK\\.$"; then
      systemctl restart xray
      echo -e "${GREEN}Xray restarted with the new DNS${NC}"
    else
      echo -e "${YELLOW}Xray DNS validation failed — restart skipped${NC}"
    fi
  fi
  echo ""
}

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}✗ Root privileges required${NC}"
  exit 1
fi

ensure_xray_runtime_user() {
  if getent passwd xray >/dev/null 2>&1; then
    return 0
  fi

  local nologin="/usr/sbin/nologin"
  [[ -x "$nologin" ]] || nologin="/sbin/nologin"
  [[ -x "$nologin" ]] || nologin="/bin/false"

  echo -e "${YELLOW}User xray is missing — creating the runtime user...${NC}"
  if ! getent group xray >/dev/null 2>&1; then
    groupadd -r xray 2>/dev/null || true
  fi
  if getent group xray >/dev/null 2>&1; then
    useradd -r -g xray -s "$nologin" -M -d /nonexistent xray
  else
    useradd -r -s "$nologin" -M -d /nonexistent xray
  fi
  if ! getent passwd xray >/dev/null 2>&1; then
    echo -e "${RED}✗ Could not create user xray${NC}"
    return 1
  fi
  echo -e "${GREEN}✓ User xray created${NC}"
  return 0
}

ensure_xray_runtime_user || exit 1

# ═══════════════════════════════════════════════════════════
# ОБРАБОТКА АРГУМЕНТОВ И ВОССТАНОВЛЕНИЕ СЕССИИ
# ═══════════════════════════════════════════════════════════
UPDATE_SESSION_FILE="/tmp/.xraytailscale_update_session"

# Удаляем старые файлы сессии (старше 5 минут)
if [[ -f "$UPDATE_SESSION_FILE" ]]; then
  file_age=$(($(date +%s) - $(stat -c %Y "$UPDATE_SESSION_FILE" 2>/dev/null || echo 0)))
  if [[ $file_age -gt 300 ]]; then
    rm -f "$UPDATE_SESSION_FILE" "$UPDATE_SESSION_FILE.warned"
  fi
fi

# Если скрипт запущен с аргументом (ветка передана при restart)
if [[ -n "$1" ]]; then
  GITHUB_BRANCH="$1"
  echo -e "${CYAN}Resuming the update after the script restart...${NC}"
  echo -e "${BLUE}Selected branch: ${MAGENTA}$GITHUB_BRANCH${NC}\n"
  sleep 1
# Если есть файл сессии (скрипт был перезапущен через exec, в течение 5 минут)
elif [[ -f "$UPDATE_SESSION_FILE" ]]; then
  GITHUB_BRANCH=$(cat "$UPDATE_SESSION_FILE")
  echo -e "${CYAN}Resuming the interrupted update...${NC}"
  echo -e "${BLUE}Branch from the session: ${MAGENTA}$GITHUB_BRANCH${NC}\n"
  sleep 1
else
  # Первый запуск - показываем меню выбора ветки
  clear
  echo -e "${CYAN}"
  echo '╔═══════════════════════════════════════════════════════════╗'
  echo '║                                                           ║'
  echo '║              XRAYTAILSCALE UPDATE SCRIPT v2.0                ║'
  echo '║              Update & Version Switch                    ║'
  echo '║                                                           ║'
  echo '╚═══════════════════════════════════════════════════════════╝'
  echo -e "${NC}\n"

  # Показываем текущую ветку если она установлена
  if [[ -f /usr/local/etc/xray/.current_branch ]]; then
    CURRENT_BRANCH=$(cat /usr/local/etc/xray/.current_branch 2>/dev/null || echo "unknown")
    echo -e "${YELLOW}Current branch: ${CYAN}$CURRENT_BRANCH${NC}\n"
  fi

  # Меню выбора ветки
  echo -e "${YELLOW}Choose a version to install/update:${NC}\n"

  echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║  1) Stable (main) - Stable version                      ║${NC}"
  echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
  echo -e "   ${CYAN}→${NC} Tested code for production"
  echo -e "   ${CYAN}→${NC} Updates every 1-2 months"
  echo -e "   ${GREEN}✓${NC} Recommended for servers"
  echo ""

  echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  2) Dev - Version with quick fixes                        ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo -e "   ${CYAN}→${NC} Fresh bug fixes"
  echo -e "   ${CYAN}→${NC} Updates every 1-2 weeks"
  echo -e "   ${YELLOW}⚠${NC} May contain minor bugs"
  echo ""

  echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}║  3) Experimental - Experimental (for testing)    ║${NC}"
  echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
  echo -e "   ${CYAN}→${NC} New features and alpha features"
  echo -e "   ${CYAN}→${NC} Auto-tuned combos, extended diagnostics"
  echo -e "   ${CYAN}→${NC} Updates several times a week"
  echo -e "   ${RED}⚠${NC} May be unstable!"
  echo ""

  echo -e "${CYAN}  0)${NC} Cancel\n"

  echo -n -e "${YELLOW}Your choice [1-3]: ${NC}"
  read branch_choice

  case $branch_choice in
    1)
      GITHUB_BRANCH="main"
      VERSION_NAME="Stable"
      VERSION_COLOR="${GREEN}"
      ;;
    2)
      GITHUB_BRANCH="dev"
      VERSION_NAME="Dev"
      VERSION_COLOR="${BLUE}"
      ;;
    3)
      GITHUB_BRANCH="experimental"
      VERSION_NAME="Experimental"
      VERSION_COLOR="${MAGENTA}"
      ;;
    0)
      echo -e "${CYAN}Cancelled${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}✗ Invalid choice${NC}"
      exit 1
      ;;
  esac

  # СОХРАНЯЕМ выбранную ветку В ФАЙЛ СЕССИИ СРАЗУ!
  echo "$GITHUB_BRANCH" > "$UPDATE_SESSION_FILE"
fi

# Устанавливаем VERSION_NAME и VERSION_COLOR если они не установлены
if [[ -z "$VERSION_NAME" ]]; then
  case $GITHUB_BRANCH in
    main)
      VERSION_NAME="Stable"
      VERSION_COLOR="${GREEN}"
      ;;
    dev)
      VERSION_NAME="Dev"
      VERSION_COLOR="${BLUE}"
      ;;
    experimental)
      VERSION_NAME="Experimental"
      VERSION_COLOR="${MAGENTA}"
      ;;
  esac
fi

RAW_BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

echo ""
echo -e "${BLUE}Updating to version: ${VERSION_COLOR}${VERSION_NAME}${NC}"
echo -e "${BLUE}GitHub branch: ${VERSION_COLOR}${GITHUB_BRANCH}${NC}\n"

# Предупреждение для experimental/dev (показываем один раз)
if [[ "$GITHUB_BRANCH" != "main" ]] && [[ ! -f "$UPDATE_SESSION_FILE.warned" ]]; then
  echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║                    ⚠ WARNING ⚠                          ║${NC}"
  echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo -e "${YELLOW}You are installing the ${VERSION_COLOR}${VERSION_NAME}${YELLOW} version.${NC}"

  if [[ "$GITHUB_BRANCH" == "experimental" ]]; then
    echo -e "${RED}This version may contain critical bugs!${NC}"
    echo -e "${YELLOW}Use it only for testing.${NC}"
  else
    echo -e "${YELLOW}This version contains fresh fixes.${NC}"
    echo -e "${CYAN}If you hit problems, roll back to Stable.${NC}"
  fi

  echo ""
  echo -n -e "${YELLOW}Continue the installation? (y/N): ${NC}"
  read confirm_install

  if [[ ! "$confirm_install" =~ ^[yYдД]$ ]]; then
    echo -e "${CYAN}✓ Cancelled${NC}"
    rm -f "$UPDATE_SESSION_FILE"
    exit 0
  fi

  # Отмечаем что предупреждение показано
  touch "$UPDATE_SESSION_FILE.warned"
  echo ""
fi

# Резервная копия текущих настроек
echo -e "${YELLOW}Creating a backup...${NC}"
BACKUP_DIR="/usr/local/etc/xray/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
UPDATE_CONFIG_BACKUP="$BACKUP_DIR/config.json"
cp /usr/local/bin/xraytailscale "$BACKUP_DIR/" 2>/dev/null
cp -r /usr/local/etc/xray/profiles "$BACKUP_DIR/" 2>/dev/null
cp /usr/local/etc/xray/config.json "$UPDATE_CONFIG_BACKUP" 2>/dev/null
cp /usr/local/etc/xray/.private_key "$BACKUP_DIR/" 2>/dev/null
cp /usr/local/etc/xray/.public_key "$BACKUP_DIR/" 2>/dev/null
cp /usr/local/etc/xray/scripts/update.sh "$BACKUP_DIR/update.sh.bak" 2>/dev/null
echo -e "${GREEN}✓ Backup: $BACKUP_DIR${NC}\n"

_restore_update_config_backup() {
  if [[ ! -s "$UPDATE_CONFIG_BACKUP" ]]; then
    echo -e "${RED}✗ Session backup config.json not found: $UPDATE_CONFIG_BACKUP${NC}"
    return 1
  fi
  echo -e "${YELLOW}Restoring config.json from the session backup...${NC}"
  cp "$UPDATE_CONFIG_BACKUP" /usr/local/etc/xray/config.json || return 1
  chown xray:xray /usr/local/etc/xray/config.json 2>/dev/null || true
  chmod 600 /usr/local/etc/xray/config.json
  echo -e "${GREEN}✓ config.json restored from $UPDATE_CONFIG_BACKUP${NC}"
}

# Сохранение информации о текущей ветке
echo "$GITHUB_BRANCH" > /usr/local/etc/xray/.current_branch 2>/dev/null

# ═══════════════════════════════════════════════════════════
# ОБНОВЛЕНИЕ СКРИПТА update.sh
# ═══════════════════════════════════════════════════════════
echo -e "${YELLOW}Checking for update.sh updates...${NC}"
UPDATE_TMP=$(mktemp /tmp/update_new_XXXXXX.sh)
github_raw_curl "${RAW_BASE_URL}/update.sh" --connect-timeout 10 --max-time 30 -o "$UPDATE_TMP"

if [[ $? -eq 0 ]] && [[ -s "$UPDATE_TMP" ]]; then
  chmod 755 "$UPDATE_TMP"

  # Проверяем что скрипт валидный
  if head -n 1 "$UPDATE_TMP" | grep -q "^#!/bin/bash" && bash -n "$UPDATE_TMP"; then
    mkdir -p /usr/local/etc/xray/scripts

    # Сравниваем с текущей версией
    if ! cmp -s "$UPDATE_TMP" /usr/local/etc/xray/scripts/update.sh 2>/dev/null; then
      mv "$UPDATE_TMP" /usr/local/etc/xray/scripts/update.sh
      echo -e "${GREEN}✓ update.sh script updated${NC}"
      echo -e "${YELLOW}⚠ Restart to apply the changes${NC}"
      sleep 2

      # ИСПРАВЛЕНИЕ: Передаем ветку через аргумент
      exec /usr/local/etc/xray/scripts/update.sh "$GITHUB_BRANCH"
      exit 0
    else
      echo -e "${GREEN}✓ update.sh is up to date${NC}"
      rm -f "$UPDATE_TMP"
    fi
  else
    echo -e "${YELLOW}⚠ The downloaded script is invalid${NC}"
    rm -f "$UPDATE_TMP"
  fi
else
  echo -e "${YELLOW}⚠ Could not update update.sh${NC}"
  rm -f "$UPDATE_TMP"
fi
echo ""

# ═══════════════════════════════════════════════════════════
# ОБНОВЛЕНИЕ ОСНОВНЫХ ФАЙЛОВ
# ═══════════════════════════════════════════════════════════

# Обновление xraytailscale
echo -e "${YELLOW}Updating xraytailscale...${NC}"
XRAY_TMP=$(mktemp /tmp/xraytailscale_new_XXXXXX)
github_raw_curl "${RAW_BASE_URL}/xraytailscale" --connect-timeout 10 --max-time 60 -o "$XRAY_TMP"

if [[ $? -eq 0 ]] && [[ -s "$XRAY_TMP" ]]; then
  chmod 755 "$XRAY_TMP"
  if bash -n "$XRAY_TMP"; then
    mv "$XRAY_TMP" /usr/local/bin/xraytailscale
    echo -e "${GREEN}✓ xraytailscale updated${NC}\n"
  else
    echo -e "${RED}✗ The downloaded xraytailscale fails bash -n${NC}"
    rm -f "$XRAY_TMP" "$UPDATE_SESSION_FILE" "$UPDATE_SESSION_FILE.warned"
    exit 1
  fi
else
  echo -e "${RED}✗ Error downloading xraytailscale${NC}"
  echo -e "${YELLOW}Check that branch '${GITHUB_BRANCH}' is reachable on GitHub${NC}"
  rm -f "$XRAY_TMP" "$UPDATE_SESSION_FILE" "$UPDATE_SESSION_FILE.warned"
  exit 1
fi

# Обновление uninstall.sh и восстановление symlink'ов команд.
echo -e "${YELLOW}Updating service scripts...${NC}"
mkdir -p /usr/local/etc/xray/scripts
UNINSTALL_TMP=$(mktemp /tmp/xraytailscale_uninstall_new_XXXXXX.sh)
if github_raw_curl "${RAW_BASE_URL}/uninstall.sh" --connect-timeout 10 --max-time 30 -o "$UNINSTALL_TMP" \
   && [[ -s "$UNINSTALL_TMP" ]] \
   && head -n 1 "$UNINSTALL_TMP" | grep -q "^#!/bin/bash" \
   && bash -n "$UNINSTALL_TMP"; then
  chmod 755 "$UNINSTALL_TMP"
  mv "$UNINSTALL_TMP" /usr/local/etc/xray/scripts/uninstall.sh
  echo -e "${GREEN}✓ uninstall.sh updated${NC}"
else
  echo -e "${YELLOW}⚠ Could not update uninstall.sh${NC}"
  rm -f "$UNINSTALL_TMP"
fi
chmod 755 /usr/local/bin/xraytailscale 2>/dev/null || true
chmod 755 /usr/local/etc/xray/scripts/update.sh 2>/dev/null || true
chmod 755 /usr/local/etc/xray/scripts/uninstall.sh 2>/dev/null || true
ln -sf /usr/local/etc/xray/scripts/update.sh /usr/local/bin/xraytailscale-update 2>/dev/null || true
ln -sf /usr/local/etc/xray/scripts/uninstall.sh /usr/local/bin/xraytailscale-uninstall 2>/dev/null || true
legacy_cmd="xrayeba""tor"
rm -f "/usr/local/bin/${legacy_cmd}" "/usr/local/bin/${legacy_cmd}-update" "/usr/local/bin/${legacy_cmd}-uninstall" 2>/dev/null || true
echo -e "${GREEN}✓ xraytailscale-update / xraytailscale-uninstall commands verified${NC}\n"

# Обновление списка SNI
echo -e "${YELLOW}Updating the SNI list...${NC}"
mkdir -p /usr/local/etc/xray/data
github_raw_curl "${RAW_BASE_URL}/sni_list.txt" -o /usr/local/etc/xray/data/sni_list.txt

if [[ $? -eq 0 ]]; then
  echo -e "${GREEN}✓ SNI list updated${NC}\n"
else
  echo -e "${YELLOW}⚠ Could not update the SNI list${NC}\n"
fi

# Обновление ASCII арта (опционально)
github_raw_curl "${RAW_BASE_URL}/ascii_art.txt" -o /usr/local/etc/xray/data/ascii_art.txt 2>/dev/null

# Проверка версии
echo -e "${YELLOW}Checking the installed version...${NC}"
VERSION_INFO=$(grep -m 1 "XRAYTAILSCALE v" /usr/local/bin/xraytailscale | sed 's/.*XRAYTAILSCALE //' | sed 's/ .*//')
echo -e "${GREEN}✓ Version: ${VERSION_INFO}${NC}\n"

# Если HAPP subscription уже установлен, его handler — сгенерированный файл.
# После обновления основного xraytailscale нужно перегенерировать subhttp.sh, иначе
# активная подписка останется на старой логике до ручного запуска меню.
if [[ -f /usr/local/etc/xray/.subscription_installed ]]; then
  echo -e "${YELLOW}Updating the HAPP subscription handler...${NC}"
  if source /usr/local/bin/xraytailscale && install_subscription_server >/dev/null 2>&1; then
    if declare -F _subscription_restart_service >/dev/null 2>&1; then
      if _subscription_restart_service; then
        echo -e "${GREEN}✓ subhttp.sh updated, xraytailscale-sub.service started${NC}"
      else
        echo -e "${YELLOW}⚠ subhttp.sh updated, but xraytailscale-sub.service did not start${NC}"
        echo -e "${YELLOW}  Check: systemctl status xraytailscale-sub --no-pager -l${NC}"
      fi
    else
      systemctl reset-failed xraytailscale-sub.service 2>/dev/null || true
      systemctl enable xraytailscale-sub.service >/dev/null 2>&1 || true
      if systemctl restart xraytailscale-sub.service; then
        echo -e "${GREEN}✓ subhttp.sh updated, xraytailscale-sub.service started${NC}"
      else
        echo -e "${YELLOW}⚠ subhttp.sh updated, but xraytailscale-sub.service did not start${NC}"
        echo -e "${YELLOW}  Check: systemctl status xraytailscale-sub --no-pager -l${NC}"
      fi
    fi
  else
    echo -e "${YELLOW}⚠ Could not regenerate the HAPP handler. Run: sudo xraytailscale → HAPP subscription${NC}"
  fi
  echo ""
fi

# Обновление geo-баз (Loyalsoldier enhanced)
echo -e "${YELLOW}Updating geo databases (Loyalsoldier)...${NC}"
XRAY_DAT_DIR="/usr/local/share/xray"
LOYALSOLDIER_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
GEO_UPDATED=false

mkdir -p "$XRAY_DAT_DIR"

# Update geoip.dat
if curl -fsSL --connect-timeout 10 "${LOYALSOLDIER_URL}/geoip.dat" -o "${XRAY_DAT_DIR}/geoip.dat.tmp" 2>/dev/null; then
  if [[ -s "${XRAY_DAT_DIR}/geoip.dat.tmp" ]]; then
    mv "${XRAY_DAT_DIR}/geoip.dat.tmp" "${XRAY_DAT_DIR}/geoip.dat"
    echo -e "${GREEN}  ✓ geoip.dat updated${NC}"
    GEO_UPDATED=true
  else
    rm -f "${XRAY_DAT_DIR}/geoip.dat.tmp"
    echo -e "${YELLOW}  ⚠ geoip.dat: empty response${NC}"
  fi
else
  rm -f "${XRAY_DAT_DIR}/geoip.dat.tmp"
  echo -e "${YELLOW}  ⚠ geoip.dat: unreachable (GitHub?)${NC}"
fi

# Update geosite.dat
if curl -fsSL --connect-timeout 10 "${LOYALSOLDIER_URL}/geosite.dat" -o "${XRAY_DAT_DIR}/geosite.dat.tmp" 2>/dev/null; then
  if [[ -s "${XRAY_DAT_DIR}/geosite.dat.tmp" ]]; then
    mv "${XRAY_DAT_DIR}/geosite.dat.tmp" "${XRAY_DAT_DIR}/geosite.dat"
    echo -e "${GREEN}  ✓ geosite.dat updated${NC}"
    GEO_UPDATED=true
  else
    rm -f "${XRAY_DAT_DIR}/geosite.dat.tmp"
    echo -e "${YELLOW}  ⚠ geosite.dat: empty response${NC}"
  fi
else
  rm -f "${XRAY_DAT_DIR}/geosite.dat.tmp"
  echo -e "${YELLOW}  ⚠ geosite.dat: unreachable (GitHub?)${NC}"
fi

if [[ "$GEO_UPDATED" == "true" ]]; then
  echo -e "${GREEN}✓ Geo databases updated${NC}\n"
else
  echo -e "${YELLOW}⚠ Geo databases not updated (using the existing ones)${NC}\n"
fi

# ═══════════════════════════════════════════════════════════
# ОПРЕДЕЛЕНИЕ update_xray_core (REQ-B01) — БЕЗ автоматического вызова.
# Trigger обновления = CLI `xraytailscale update` (см. xraytailscale dispatcher).
# Функция определена здесь для sync-test parity с install.sh / xraytailscale.
# ═══════════════════════════════════════════════════════════

# update_xray_core
# Скачивает и атомарно устанавливает свежий Xray-core с GitHub Releases.
# Использует: GitHub API → fallback redirect, SHA-256 verify, self-test нового binary,
# atomic install -m 755, rollback бинарника на неудачу.
#
# Returns:
#   0 — успешно обновлено (или уже на latest)
#   1 — пропущено пользователем (y/N → N)
#   2 — критическая ошибка (network / SHA / arch unsupported)
#   3 — config несовместим с новой версией (rollback применен, Xray на старой)
XRAY_COMPAT_VERSION="26.6.27"

update_xray_core() {
  local CURRENT_VERSION TARGET_TAG TARGET_VERSION MACHINE
  local TMPDIR ZIP_URL DGST_URL ZIP_PATH DGST_PATH

  # ── Step 1: Architecture detection ──────────────────────────────
  case "$(uname -m)" in
    x86_64|amd64)  MACHINE="64" ;;
    aarch64|arm64) MACHINE="arm64-v8a" ;;
    armv7l)        MACHINE="arm32-v7a" ;;
    armv6l)        MACHINE="arm32-v6" ;;
    *)
      echo -e "${RED}✗ Architecture $(uname -m) is not supported${NC}"
      return 2
      ;;
  esac

  # ── Step 2: Получить current version ───────────────────────────
  if [[ -x /usr/local/bin/xray ]]; then
    CURRENT_VERSION=$(/usr/local/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')
  fi
  CURRENT_VERSION="${CURRENT_VERSION:-неустановлено}"

  # ── Step 3: Получить latest tag (API → fallback redirect) ──────
  TARGET_TAG=$(_fetch_latest_tag) || {
    echo -e "${RED}✗ GitHub unreachable (API + redirect failed)${NC}"
    _print_manual_install_hint "$MACHINE"
    return 2
  }
  TARGET_VERSION="${TARGET_TAG#v}"

  # Чистая установка: по умолчанию ставим последнюю sing-box/Karing-совместимую
  # версию. Xray >= 26.9.9 требует X25519MLKEM768 в Reality ClientHello,
  # который sing-box не отправляет — Karing перестаёт подключаться.
  # Ручное обновление через меню остаётся доступным (с предупреждением).
  if [[ "${INSTALL_MODE:-0}" == "1" ]]; then
    TARGET_TAG="v${XRAY_COMPAT_VERSION}"
    TARGET_VERSION="$XRAY_COMPAT_VERSION"
    echo -e "${CYAN}Installing Xray $TARGET_VERSION (last sing-box/Karing-compatible)${NC}"
  fi

  # ── Step 4: Compare versions ────────────────────────────────────
  if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" ]]; then
    echo -e "${GREEN}✓ Xray $CURRENT_VERSION — already on latest${NC}"
    return 0
  fi

  # Защита от downgrade: если текущая > целевой — пропускаем
  if [[ "$CURRENT_VERSION" != "неустановлено" ]]; then
    local cv_major cv_minor cv_patch tv_major tv_minor tv_patch
    cv_major=$(echo "$CURRENT_VERSION" | awk -F. '{print $1+0}')
    cv_minor=$(echo "$CURRENT_VERSION" | awk -F. '{print $2+0}')
    cv_patch=$(echo "$CURRENT_VERSION" | awk -F. '{print $3+0}')
    tv_major=$(echo "$TARGET_VERSION" | awk -F. '{print $1+0}')
    tv_minor=$(echo "$TARGET_VERSION" | awk -F. '{print $2+0}')
    tv_patch=$(echo "$TARGET_VERSION" | awk -F. '{print $3+0}')
    if [[ $cv_major -gt $tv_major ]] || \
       [[ $cv_major -eq $tv_major && $cv_minor -gt $tv_minor ]] || \
       [[ $cv_major -eq $tv_major && $cv_minor -eq $tv_minor && $cv_patch -gt $tv_patch ]]; then
      echo -e "${GREEN}✓ Xray $CURRENT_VERSION is newer than the available $TARGET_VERSION — skipping${NC}"
      return 0
    fi
  fi

  # Возвращает 0, если major.minor.patch версии $1 >= версии $2.
_xray_ver_ge() {
  local a b IFS=.
  read -r -a a <<< "${1#v}"
  read -r -a b <<< "${2#v}"
  local i
  for i in 0 1 2; do
    local x="${a[$i]:-0}" y="${b[$i]:-0}"
    (( 10#$x > 10#$y )) && return 0
    (( 10#$x < 10#$y )) && return 1
  done
  return 0
}

# Предупреждение о несовместимости Xray ≥26.9.9 с sing-box/Karing.
_xray_update_karing_warning() {
  local current="$1" target="$2"
  # Порог применим только к 26.x.
  [[ "$target" == 26.* ]] || return 0
  if _xray_ver_ge "$target" "26.9.9" && ! _xray_ver_ge "$current" "26.9.9"; then
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  WARNING: Karing / sing-box compatibility will BREAK     ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}Xray-core ≥ 26.9.9 requires the X25519MLKEM768 key share in the${NC}"
    echo -e "${YELLOW}Reality handshake. sing-box (Karing, Streisand, FoXray) does NOT${NC}"
    echo -e "${YELLOW}send it, so those clients will fail with 'reality verification failed'.${NC}"
    echo -e "${YELLOW}Xray-based clients (HAPP, v2rayNG, v2rayN) keep working.${NC}"
    echo -e "${CYAN}To keep Karing working, stay on Xray ≤ 26.6.27 (answer 'n').${NC}"
    echo ""
  fi
  return 0
}

# ── Step 5: Confirmation prompt (CONTEXT.md decision 2) ────────
  echo -e "${CYAN}Xray-core update available:${NC}"
  echo -e "  ${YELLOW}Current:${NC} $CURRENT_VERSION"
  echo -e "  ${GREEN}New:${NC}    $TARGET_VERSION"
  echo -e "  ${CYAN}Size:${NC}   ~6.5MB (zip)"
  echo -e "  ${CYAN}Downtime:${NC} ~5 seconds"
  echo ""

  # sing-box (Karing, Streisand, FoXray и др.) не умеет X25519MLKEM768,
  # который Xray-core ≥ 26.9.9 требует в Reality ClientHello. При обновлении
  # через порог 26.9.9 такие клиенты молча перестают подключаться
  # ("reality verification failed"). Предупреждаем ДО скачивания.
  _xray_update_karing_warning "$CURRENT_VERSION" "$TARGET_VERSION"

  if [[ "${INSTALL_MODE:-0}" != "1" ]]; then
    echo -n -e "${YELLOW}Continue? [y/N]: ${NC}"
    read confirm
    [[ ! "$confirm" =~ ^[yYдД]$ ]] && {
      echo -e "${CYAN}Cancelled by the user${NC}"
      return 1
    }
  fi

  # ── Step 6: Download zip + dgst (с --progress-bar) ─────────────
  TMPDIR=$(mktemp -d /tmp/xray_update.XXXXXX)
  trap "rm -rf '$TMPDIR'" RETURN

  ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${TARGET_TAG}/Xray-linux-${MACHINE}.zip"
  DGST_URL="${ZIP_URL}.dgst"
  ZIP_PATH="${TMPDIR}/xray.zip"
  DGST_PATH="${ZIP_PATH}.dgst"

  echo -e "${CYAN}Downloading $TARGET_TAG...${NC}"
  if ! curl -fL --progress-bar --connect-timeout 30 --max-time 300 \
       -o "$ZIP_PATH" "$ZIP_URL"; then
    echo -e "${RED}✗ Could not download $ZIP_URL${NC}"
    return 2
  fi

  if ! curl -fsSL --connect-timeout 10 --max-time 30 \
       -o "$DGST_PATH" "$DGST_URL"; then
    echo -e "${RED}✗ Could not download .dgst (SHA-256 manifest is required)${NC}"
    return 2
  fi

  # ── Step 7: SHA-256 verify (mandatory) ─────────────────────────
  echo -e "${CYAN}Verifying SHA256...${NC}"
  local expected actual
  expected=$(awk -F '= *' '/^(SHA2-)?256=|^SHA256=/ {print $2; exit}' "$DGST_PATH" | tr -d '[:space:]')
  actual=$(sha256sum "$ZIP_PATH" | awk '{print $1}')

  if [[ -z "$expected" ]]; then
    echo -e "${RED}✗ The .dgst file has no SHA256 (format changed?)${NC}"
    return 2
  fi
  if [[ "$expected" != "$actual" ]]; then
    echo -e "${RED}✗ SHA256 mismatch — aborting${NC}"
    echo -e "${YELLOW}  Expected: $expected${NC}"
    echo -e "${YELLOW}  Got:      $actual${NC}"
    return 2
  fi
  echo -e "${GREEN}  ✓ SHA256 ok${NC}"

  # ── Step 8: Unzip ──────────────────────────────────────────────
  if ! unzip -q "$ZIP_PATH" -d "${TMPDIR}/extract"; then
    echo -e "${RED}✗ Extraction error${NC}"
    return 2
  fi
  if [[ ! -x "${TMPDIR}/extract/xray" ]]; then
    echo -e "${RED}✗ The xray binary is missing from the zip archive${NC}"
    return 2
  fi

  # ── Step 9: Self-test нового бинарника ─────────────────────────
  if ! "${TMPDIR}/extract/xray" version >/dev/null 2>&1; then
    echo -e "${RED}✗ The new binary does not run (binary corrupt / arch mismatch)${NC}"
    return 2
  fi

  # ── Step 10: Pre-validate config с НОВЫМ binary (catch breaking) ──
  # Skip если config.json отсутствует — install mode
  local CONFIG_FILE="/usr/local/etc/xray/config.json"
  if [[ -f "$CONFIG_FILE" ]]; then
    local test_output
    test_output=$("${TMPDIR}/extract/xray" run -test -config "$CONFIG_FILE" 2>&1)
    if ! grep -qx "Configuration OK." <<< "$test_output"; then
      echo -e "${RED}✗ config.json is invalid against $TARGET_VERSION${NC}"
      echo -e "${YELLOW}Details:${NC}"
      echo "$test_output" | head -10
      echo -e "${YELLOW}Update aborted — Xray keeps running on $CURRENT_VERSION${NC}"
      return 3
    fi
  else
    echo -e "${CYAN}  → config.json missing (install mode), pre-validate skipped${NC}"
  fi

  # ── Step 11: Backup старого binary ─────────────────────────────
  local backup_path="/usr/local/bin/xray.bak.$(date +%s)"
  if [[ -x /usr/local/bin/xray ]]; then
    cp /usr/local/bin/xray "$backup_path"
    chmod 755 "$backup_path"
    echo -e "${CYAN}  → Backup: $(basename "$backup_path")${NC}"
  fi

  # ── Step 12: Atomic install ────────────────────────────────────
  if ! install -m 755 -o root -g root \
       "${TMPDIR}/extract/xray" /usr/local/bin/xray; then
    echo -e "${RED}✗ install -m 755 error${NC}"
    [[ -f "$backup_path" ]] && {
      mv "$backup_path" /usr/local/bin/xray
      echo -e "${YELLOW}  → Rolling back to $CURRENT_VERSION${NC}"
    }
    return 2
  fi

  # ── Step 13: Restart с systemd-unit-guard (skip в install mode) ──
  # safe_restart_xray в update.sh недоступна (определена в xraytailscale).
  # Используем прямой systemctl + проверка is-active.
  if systemctl list-unit-files xray.service >/dev/null 2>&1 && [[ -f /etc/systemd/system/xray.service.d/security.conf ]]; then
    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
      echo -e "${GREEN}✓ Xray-core updated: $CURRENT_VERSION → $TARGET_VERSION${NC}"
      _cleanup_xray_backups
      return 0
    else
      echo -e "${RED}✗ Xray did not start after installing $TARGET_VERSION${NC}"
      if [[ -f "$backup_path" ]]; then
        mv "$backup_path" /usr/local/bin/xray
        systemctl restart xray
        sleep 2
        if systemctl is-active --quiet xray; then
          echo -e "${YELLOW}  → Binary rollback to $CURRENT_VERSION done${NC}"
        else
          echo -e "${RED}  ✗ Rollback did not help — manual intervention${NC}"
        fi
      fi
      return 3
    fi
  else
    # Install mode: systemd unit будет создан позже в [3/10].
    echo -e "${CYAN}  → Xray-core installed. The service is configured in [3/10].${NC}"
    _cleanup_xray_backups
    return 0
  fi
}

_fetch_latest_tag() {
  # Пробуем GitHub API первым
  local api_json tag
  api_json=$(curl -fsSL --connect-timeout 10 --max-time 20 \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null)
  tag=$(echo "$api_json" | jq -r '.tag_name // ""' 2>/dev/null)
  if [[ -n "$tag" && "$tag" != "null" ]]; then
    echo "$tag"
    return 0
  fi

  # Fallback: 302 redirect parse
  local redirect_url
  redirect_url=$(curl -fso /dev/null -w '%{url_effective}' \
    --connect-timeout 10 --max-time 15 -L --max-redirs 1 \
    "https://github.com/XTLS/Xray-core/releases/latest" 2>/dev/null)
  tag="${redirect_url##*/}"
  if [[ -n "$tag" && "$tag" =~ ^v[0-9]+\. ]]; then
    echo "$tag"
    return 0
  fi

  return 1
}

_print_manual_install_hint() {
  local arch="$1"
  echo -e "${YELLOW}  Manual install:${NC}"
  echo -e "${CYAN}    1. https://github.com/XTLS/Xray-core/releases/latest${NC}"
  echo -e "${CYAN}    2. Download Xray-linux-${arch}.zip + .dgst${NC}"
  echo -e "${CYAN}    3. unzip xray.zip && check sha256sum${NC}"
  echo -e "${CYAN}    4. install -m 755 ./xray /usr/local/bin/xray${NC}"
  echo -e "${CYAN}    5. systemctl restart xray${NC}"
}

_cleanup_xray_backups() {
  # Оставить 3 последних xray.bak.<timestamp>, остальные удалить.
  local backups
  mapfile -t backups < <(ls -t /usr/local/bin/xray.bak.* 2>/dev/null)

  if [[ ${#backups[@]} -gt 3 ]]; then
    local to_remove=("${backups[@]:3}")
    for f in "${to_remove[@]}"; do
      rm -f "$f"
    done
    echo -e "${CYAN}  → Old backups removed (3 kept)${NC}"
  fi
}

# ═══════════════════════════════════════════════════════════
# КОНЕЦ блока определений update_xray_core
# ═══════════════════════════════════════════════════════════

# Force-uninstall AdGuard Home (deprecated в v2.0) — должен выполниться ПЕРЕД DNS migration.
if ! _adguard_force_uninstall_if_present; then
  _restore_update_config_backup || true
  echo -e "${RED}✗ AdGuard cleanup failed — update aborted, config.json restored from the session backup${NC}"
  exit 1
fi

# ═══════════════════════════════════════════════════════════
# МИГРАЦИЯ DNS (AdGuard для блокировки рекламы)
# ═══════════════════════════════════════════════════════════
CONFIG_FILE="/usr/local/etc/xray/config.json"
if [[ -f "$CONFIG_FILE" ]]; then
  echo -e "${YELLOW}Checking DNS settings...${NC}"

  # Проверяем: если DNS -> 127.0.0.1 (AdGuard Home), не трогаем
  CURRENT_DNS=$(jq -r '.dns.servers[0] // ""' "$CONFIG_FILE" 2>/dev/null)
  if [[ "$CURRENT_DNS" == "127.0.0.1" ]]; then
    echo -e "${GREEN}  ✓ DNS -> 127.0.0.1 (AdGuard Home) -- preserved${NC}"
  elif [[ "$CURRENT_DNS" == "https+local://"* ]]; then
    echo -e "${GREEN}  ✓ DNS -> DoH Local -- preserved${NC}"
  elif ! grep -q "dns.adguard-dns.com" "$CONFIG_FILE" 2>/dev/null; then
    echo -e "${CYAN}  → Migrating to DoH Local${NC}"

    # Создаём новую конфигурацию DNS
    NEW_DNS='{
      "servers": [
        "https+local://1.1.1.1/dns-query",
        "localhost"
      ],
      "queryStrategy": "UseIPv4",
      "disableCache": false
    }'

    # Обновляем DNS секцию в конфиге
    TMP_FILE=$(mktemp /tmp/xray-cfg.XXXXXX) || {
      echo -e "${YELLOW}  ⚠ mktemp failed (DNS update skipped)${NC}"
      true
    }
    if [[ -n "$TMP_FILE" ]] && jq --argjson dns "$NEW_DNS" '.dns = $dns' "$CONFIG_FILE" > "$TMP_FILE" 2>/dev/null \
       && [[ -s "$TMP_FILE" ]] \
       && xray run -test -config "$TMP_FILE" 2>&1 | grep -q "^Configuration OK\.$"; then
      mv "$TMP_FILE" "$CONFIG_FILE"
      # Restore mode/owner (mktemp создаёт с mode 600, mv наследует root)
      chmod 644 "$CONFIG_FILE"
      chown xray:xray "$CONFIG_FILE" 2>/dev/null || true
      echo -e "${GREEN}  ✓ DNS updated to DoH Local (https+local://1.1.1.1)${NC}"
    else
      rm -f "$TMP_FILE"
      echo -e "${YELLOW}  ⚠ Could not update DNS (size-check or xray test failed, config unchanged)${NC}"
    fi
  else
    echo -e "${GREEN}  ✓ AdGuard DNS already configured${NC}"
  fi

fi

# Перезапуск Xray (если работает)
if systemctl is-active --quiet xray; then
  echo -e "${YELLOW}Validating config.json before restarting Xray...${NC}"

  # Guard #1: файл существует и не пуст
  if [[ ! -f /usr/local/etc/xray/config.json || ! -s /usr/local/etc/xray/config.json ]]; then
    echo -e "${RED}✗ config.json is missing or empty after migrations${NC}"
    _restore_update_config_backup || true
    echo -e "${RED}Update aborted. Xray keeps running on the old config.${NC}"
    exit 1
  fi

  # Guard #2: xray run -test (grep stdout — exit code ненадёжен: возвращает 0 на missing file)
  if ! xray run -test -config /usr/local/etc/xray/config.json 2>&1 | grep -q "^Configuration OK\.$"; then
    echo -e "${RED}✗ config.json is invalid after migrations${NC}"
    echo -e "${YELLOW}xray output:${NC}"
    xray run -test -config /usr/local/etc/xray/config.json 2>&1 | head -20

    _restore_update_config_backup || true
    echo -e "${RED}Update aborted. Xray keeps running on the old config.${NC}"
    exit 1
  fi
  echo -e "${GREEN}✓ config.json passed validation${NC}"

  echo -e "${YELLOW}Restarting Xray...${NC}"
  systemctl restart xray
  sleep 2

  if systemctl is-active --quiet xray; then
    echo -e "${GREEN}✓ Xray restarted${NC}\n"
  else
    echo -e "${RED}✗ Error restarting Xray${NC}"
    _restore_update_config_backup || true
    systemctl restart xray >/dev/null 2>&1 || true
    echo -e "${YELLOW}Logs: journalctl -u xray -n 50${NC}\n"
    exit 1
  fi
fi

# Очистка временных файлов
rm -f "$UPDATE_SESSION_FILE" "$UPDATE_SESSION_FILE.warned"

# ═══════════════════════════════════════════════════════════
# ФИНАЛЬНОЕ СООБЩЕНИЕ
# ═══════════════════════════════════════════════════════════
clear
echo -e "${VERSION_COLOR}"
echo '╔═══════════════════════════════════════════════════════════╗'
echo '║                                                           ║'
echo '║              ✓ UPDATE FINISHED!                     ║'
echo '║                                                           ║'
echo '╚═══════════════════════════════════════════════════════════╝'
echo -e "${NC}\n"

echo -e "${CYAN}Installed branch: ${VERSION_COLOR}${VERSION_NAME} (${GITHUB_BRANCH})${NC}"
echo -e "${CYAN}XrayTailscale release: ${VERSION_COLOR}${VERSION_INFO}${NC}"
echo -e "${CYAN}Backup: ${GREEN}${BACKUP_DIR}${NC}\n"

# Информация по ветке
case $GITHUB_BRANCH in
  main)
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Stable version installed${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}✓${NC} Tested code"
    echo -e "  ${GREEN}✓${NC} For production servers"
    ;;
  dev)
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Dev version installed${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}✓${NC} Fresh fixes"
    echo -e "  ${YELLOW}⚠${NC} To roll back: sudo xraytailscale-update → Stable"
    ;;
  experimental)
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}  ⚡ Experimental version installed${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}✓${NC} Auto-tuned combos with dynamic ports"
    echo -e "  ${GREEN}✓${NC} Per-profile SNI/fingerprint tuning"
    echo -e "  ${GREEN}✓${NC} Extended diagnostics"
    echo -e "  ${RED}⚠${NC} Test version!"
    echo -e "  ${YELLOW}To roll back: sudo xraytailscale-update → Stable${NC}"
    ;;
esac

echo ""
echo -e "${BLUE}Commands:${NC}"
echo -e "  ${YELLOW}sudo xraytailscale${NC} - run the manager"
echo -e "  ${YELLOW}sudo xraytailscale-update${NC} - switch/update the version"
echo -e "  ${YELLOW}systemctl status xray${NC} - service status"
echo -e "  ${YELLOW}journalctl -u xray -f${NC} - live logs"
echo ""

echo -e "${MAGENTA}For internet freedom! 🚀${NC}"
echo ""
