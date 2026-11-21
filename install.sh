#!/bin/bash

# ═══════════════════════════════════════════════════════════
# XRAYTAILSCALE INSTALLER v2.0
# Автоматическая установка Xray Reality VPN + Tailscale exit node
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

# Пути
CONFIG_FILE="/usr/local/etc/xray/config.json"
PROFILES_DIR="/usr/local/etc/xray/profiles"
DATA_DIR="/usr/local/etc/xray/data"
SCRIPTS_DIR="/usr/local/etc/xray/scripts"
PRIVATE_KEY_FILE="/usr/local/etc/xray/.private_key"
PUBLIC_KEY_FILE="/usr/local/etc/xray/.public_key"

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}✗ Root privileges are required for installation${NC}"
  exit 1
fi

clear
echo -e "${CYAN}"
echo '╔═══════════════════════════════════════════════════════════╗'
echo '║                                                           ║'
echo '║              XRAYTAILSCALE INSTALLER v2.0                ║'
echo '║       Xray Reality VPN + Tailscale exit node             ║'
echo '║                                                           ║'
echo '╚═══════════════════════════════════════════════════════════╝'
echo -e "${NC}\n"
echo -e "${YELLOW}Starting installation...${NC}\n"
sleep 2

# [1/10] Установка зависимостей
echo -e "${BLUE}[1/10]${NC} ${YELLOW}Installing required packages...${NC}"
apt update > /dev/null 2>&1
apt install -y ca-certificates curl wget jq qrencode uuid-runtime ufw unzip openssl socat > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
  echo -e "${GREEN}✓ Dependencies installed${NC}\n"
else
  echo -e "${RED}✗ Dependency install error${NC}"
  exit 1
fi

# [2/10] Установка Xray-core (REQ-B03 single source of truth)
echo -e "${BLUE}[2/10]${NC} ${YELLOW}Installing Xray-core...${NC}"

# Inline-копия update_xray_core() (синхронизирована с update.sh / xraytailscale через
# validation/test-update-xray-core-sync.sh).
# На свежей установке /usr/local/bin/xray отсутствует → CURRENT_VERSION="неустановлено"
# → flow становится «download + install», без compare/confirmation branch.
# INSTALL_MODE=1 bypass'ит confirmation prompt и активирует install-mode guards
# на Step 10 (config.json может отсутствовать) и Step 13 (systemd unit еще не настроен).

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

INSTALL_MODE=1 update_xray_core
UPDATE_RC=$?
if [[ $UPDATE_RC -ne 0 ]]; then
  echo -e "${RED}✗ Could not install Xray-core (code $UPDATE_RC)${NC}"
  echo -e "${YELLOW}  Manual install: https://github.com/XTLS/Xray-core/releases/latest${NC}"
  exit 1
fi

# Проверка что бинарник появился
if [[ ! -x /usr/local/bin/xray ]]; then
  echo -e "${RED}✗ Xray binary not found after install${NC}"
  exit 1
fi
XRAY_VERSION=$(/usr/local/bin/xray version 2>/dev/null | head -1)
echo -e "${GREEN}✓ Xray-core installed${NC}"
echo -e "${CYAN}  ${XRAY_VERSION}${NC}\n"

# [3/10] Настройка Xray сервиса (non-root с capabilities)
echo -e "${BLUE}[3/10]${NC} ${YELLOW}Configuring the Xray service...${NC}"

# Create xray system user if not exists
if ! getent passwd xray >/dev/null 2>&1; then
  NOLOGIN_SHELL="/usr/sbin/nologin"
  [[ -x "$NOLOGIN_SHELL" ]] || NOLOGIN_SHELL="/sbin/nologin"
  [[ -x "$NOLOGIN_SHELL" ]] || NOLOGIN_SHELL="/bin/false"
  if ! getent group xray >/dev/null 2>&1; then
    groupadd -r xray 2>/dev/null || true
  fi
  if getent group xray >/dev/null 2>&1; then
    useradd -r -g xray -s "$NOLOGIN_SHELL" -M -d /nonexistent xray
  else
    useradd -r -s "$NOLOGIN_SHELL" -M -d /nonexistent xray
  fi
  if ! getent passwd xray >/dev/null 2>&1; then
    echo -e "${RED}✗ Could not create user xray${NC}"
    exit 1
  fi
  echo -e "${GREEN}  ✓ User xray created${NC}"
fi

# Create base systemd unit if the Xray package/zip install did not provide one.
if ! systemctl cat xray.service >/dev/null 2>&1; then
  cat > /etc/systemd/system/xray.service <<'SVCEOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
User=xray
Group=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVCEOF
  chmod 644 /etc/systemd/system/xray.service
  echo -e "${GREEN}  ✓ xray.service created${NC}"
else
  echo -e "${CYAN}  → xray.service already exists${NC}"
fi

# Create systemd drop-in for non-root with capabilities
mkdir -p /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/security.conf << 'SVCEOF'
[Service]
User=xray
Group=xray
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
SVCEOF

systemctl daemon-reload
echo -e "${GREEN}✓ Service configured (User=xray, CAP_NET_BIND_SERVICE)${NC}\n"

# [3.5/10] Загрузка расширенных geo-баз (Loyalsoldier)
echo -e "${BLUE}[3.5/10]${NC} ${YELLOW}Loading extended geo databases...${NC}"
XRAY_DAT_DIR="/usr/local/share/xray"
LOYALSOLDIER_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"

mkdir -p "$XRAY_DAT_DIR"

# Download geoip.dat
echo -e "${CYAN}  → Downloading geoip.dat...${NC}"
if curl -fsSL "${LOYALSOLDIER_URL}/geoip.dat" -o "${XRAY_DAT_DIR}/geoip.dat.tmp"; then
  if [[ -s "${XRAY_DAT_DIR}/geoip.dat.tmp" ]]; then
    mv "${XRAY_DAT_DIR}/geoip.dat.tmp" "${XRAY_DAT_DIR}/geoip.dat"
    echo -e "${GREEN}  ✓ geoip.dat loaded${NC}"
  else
    rm -f "${XRAY_DAT_DIR}/geoip.dat.tmp"
    echo -e "${YELLOW}  ⚠ geoip.dat is empty, using the default${NC}"
  fi
else
  echo -e "${YELLOW}  ⚠ Could not download geoip.dat, using the default${NC}"
fi

# Download geosite.dat
echo -e "${CYAN}  → Downloading geosite.dat...${NC}"
if curl -fsSL "${LOYALSOLDIER_URL}/geosite.dat" -o "${XRAY_DAT_DIR}/geosite.dat.tmp"; then
  if [[ -s "${XRAY_DAT_DIR}/geosite.dat.tmp" ]]; then
    mv "${XRAY_DAT_DIR}/geosite.dat.tmp" "${XRAY_DAT_DIR}/geosite.dat"
    echo -e "${GREEN}  ✓ geosite.dat loaded${NC}"
  else
    rm -f "${XRAY_DAT_DIR}/geosite.dat.tmp"
    echo -e "${YELLOW}  ⚠ geosite.dat is empty, using the default${NC}"
  fi
else
  echo -e "${YELLOW}  ⚠ Could not download geosite.dat, using the default${NC}"
fi

echo -e "${GREEN}✓ Geo databases configured (Loyalsoldier enhanced)${NC}\n"

# [4/10] Создание структуры директорий
echo -e "${BLUE}[4/10]${NC} ${YELLOW}Creating the directory structure...${NC}"
mkdir -p "$PROFILES_DIR"
mkdir -p "$DATA_DIR"
mkdir -p "$SCRIPTS_DIR"
mkdir -p /var/log/xray
chown xray:xray /var/log/xray
chown -R xray:xray /usr/local/etc/xray/
echo -e "${GREEN}✓ Directories created${NC}\n"

# [5/10] Генерация ключей Reality
echo -e "${BLUE}[5/10]${NC} ${YELLOW}Generating Reality keys...${NC}"

if [[ ! -x /usr/local/bin/xray ]]; then
  echo -e "${RED}✗ Binary /usr/local/bin/xray not found or not executable${NC}"
  echo -e "${YELLOW}  The Xray install on step [2/10] may have failed${NC}"
  exit 1
fi

KEYS_OUTPUT=$(/usr/local/bin/xray x25519 2>&1)
KEYS_EXIT=$?

if [[ $KEYS_EXIT -ne 0 ]]; then
  echo -e "${RED}✗ The xray x25519 command failed (code $KEYS_EXIT)${NC}"
  echo "Output:"
  echo "$KEYS_OUTPUT"
  exit 1
fi

# Парсинг всех форматов вывода xray x25519:
#   Старый (до v25.8):     Private key: ... / Public key: ...
#   Средний (v25.8-v26.3): PrivateKey: ...  / Password: ...
#   Новый (v26.3.27+):     PrivateKey: ...  / Password (PublicKey): ...
# Layer 1: known field names (поддерживает все 3 формата вывода xray x25519:
#   Старый (до v25.8):     Private key: ... / Public key: ...
#   Средний (v25.8-v26.3): PrivateKey: ...  / Password: ...
#   Новый (v26.3.27+):     PrivateKey: ...  / Password (PublicKey): ...
PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | awk -F': ' '/^Private [Kk]ey:/ || /^PrivateKey:/ {print $2; exit}')
PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | awk -F': ' '/^Public [Kk]ey:/ || /^Password/ {print $2; exit}')

# Layer 2 (fallback): если field-name parser не сработал — найти строки base64 shape.
# x25519 keys = 32 байта = 43 символа base64.RawURLEncoding (без padding, алфавит [A-Za-z0-9_-])
# ИЛИ 44 символа base64.StdEncoding (с одним '=' padding, алфавит [A-Za-z0-9+/=]).
# Расширенный regex покрывает оба алфавита: [A-Za-z0-9_+/=-] длиной 43-44.
if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
  echo -e "${YELLOW}⚠ The field-based parser found no keys, trying the base64-shape fallback${NC}"
  KEY_CANDIDATES=$(echo "$KEYS_OUTPUT" | grep -oE '[A-Za-z0-9_+/=-]{43,44}' | head -2)
  PRIVATE_KEY=$(echo "$KEY_CANDIDATES" | sed -n '1p')
  PUBLIC_KEY=$(echo "$KEY_CANDIDATES" | sed -n '2p')
fi

# Layer 3 (validator): оба ключа должны быть base64 (RawURL или Std) длиной 43-44.
# RawURL (Xray default): 43 chars, алфавит [A-Za-z0-9_-]
# Std (legacy/edge): 44 chars (с '=' padding), алфавит [A-Za-z0-9+/=]
# Объединённый regex покрывает оба варианта.
validate_x25519_key() {
  local key="$1"
  [[ "$key" =~ ^[A-Za-z0-9_+/=-]{43,44}$ ]]
}

if ! validate_x25519_key "$PRIVATE_KEY" || ! validate_x25519_key "$PUBLIC_KEY"; then
  echo -e "${RED}✗ Keys failed base64 validation (expected 43-44 chars of base64-url or base64-std)${NC}"
  echo -e "${YELLOW}Command output:${NC}"
  echo "$KEYS_OUTPUT"
  echo -e "${YELLOW}Parsed:${NC}"
  echo -e "  Private (${#PRIVATE_KEY} chars): ${PRIVATE_KEY:0:20}..."
  echo -e "  Public  (${#PUBLIC_KEY} chars): ${PUBLIC_KEY:0:20}..."
  exit 1
fi

printf "%s" "$PRIVATE_KEY" > "$PRIVATE_KEY_FILE"
printf "%s" "$PUBLIC_KEY" > "$PUBLIC_KEY_FILE"
chmod 600 "$PRIVATE_KEY_FILE"
chmod 644 "$PUBLIC_KEY_FILE"
echo -e "${GREEN}✓ Keys generated${NC}"
echo -e "${CYAN}  Private: ${PRIVATE_KEY:0:16}...${NC}"
echo -e "${CYAN}  Public: ${PUBLIC_KEY:0:16}...${NC}\n"

# Set file ownership for xray user
chown -R xray:xray /usr/local/etc/xray/
chmod 600 "$PRIVATE_KEY_FILE"
chmod 644 "$PUBLIC_KEY_FILE"

# ── VLESS Encryption keys (Phase 6 REQ-A01) ────────────────────
# Генерация PQ decryption/encryption пары через xray vlessenc.
# Требует Xray-core ≥ 25.9.5 (гарантируется install.sh шагом «Установка Xray-core» latest stable).
echo -e "${BLUE}[5b/10]${NC} ${YELLOW}Generating VLESS Encryption keys (mlkem768x25519plus.native)...${NC}"

VLESS_DECRYPTION_FILE="/usr/local/etc/xray/.vless_decryption"
VLESS_ENCRYPTION_FILE="/usr/local/etc/xray/.vless_encryption"

VLESSENC_OUTPUT=$(/usr/local/bin/xray vlessenc 2>&1)
VLESSENC_EXIT=$?

if [[ $VLESSENC_EXIT -ne 0 ]]; then
  echo -e "${RED}✗ xray vlessenc failed (code $VLESSENC_EXIT)${NC}"
  echo "Output:"; echo "$VLESSENC_OUTPUT"
  exit 1
fi

# Layer 1: section-aware parser — берём именно ML-KEM-768 auth pair, не X25519 pair.
VLESS_DECRYPTION=$(echo "$VLESSENC_OUTPUT" | awk -F'"' '
  /^Authentication: ML-KEM-768/ { in_mlkem=1; next }
  in_mlkem && /^"decryption":/ { print $4; exit }
' | tr -d '[:space:]')
VLESS_ENCRYPTION=$(echo "$VLESSENC_OUTPUT" | awk -F'"' '
  /^Authentication: ML-KEM-768/ { in_mlkem=1; next }
  in_mlkem && /^"encryption":/ { print $4; exit }
' | tr -d '[:space:]')

# Layer 2: mlkem-shape fallback. Если Xray в будущей версии уберёт section labels,
# tail -2 выбирает последнюю пару; в current output это ML-KEM-768.
if [[ ! "$VLESS_DECRYPTION" =~ ^mlkem768x25519plus\. ]] || [[ ! "$VLESS_ENCRYPTION" =~ ^mlkem768x25519plus\. ]]; then
  echo -e "${YELLOW}⚠ The section parser found no keys, trying the mlkem-shape fallback${NC}"
  MLKEM_LINES=$(echo "$VLESSENC_OUTPUT" | grep -oE 'mlkem768x25519plus\.[^"[:space:]]+')
  VLESS_DECRYPTION=$(echo "$MLKEM_LINES" | tail -2 | sed -n '1p')
  VLESS_ENCRYPTION=$(echo "$MLKEM_LINES" | tail -1)
fi

# Layer 3: validator
if [[ ! "$VLESS_DECRYPTION" =~ ^mlkem768x25519plus\. ]] || [[ ! "$VLESS_ENCRYPTION" =~ ^mlkem768x25519plus\. ]]; then
  echo -e "${RED}✗ Could not parse the mlkem768x25519plus keys${NC}"
  echo -e "${YELLOW}  Make sure Xray-core ≥ 25.9.5 is installed${NC}"
  echo -e "${YELLOW}Full vlessenc output:${NC}"; echo "$VLESSENC_OUTPUT"
  exit 1
fi

printf "%s" "$VLESS_DECRYPTION" > "$VLESS_DECRYPTION_FILE"
printf "%s" "$VLESS_ENCRYPTION" > "$VLESS_ENCRYPTION_FILE"
chmod 600 "$VLESS_DECRYPTION_FILE" "$VLESS_ENCRYPTION_FILE"
chown xray:xray "$VLESS_DECRYPTION_FILE" "$VLESS_ENCRYPTION_FILE" 2>/dev/null || true

echo -e "${GREEN}✓ VLESS Encryption keys generated${NC}"
echo -e "${CYAN}  decryption: ${VLESS_DECRYPTION:0:48}...${NC}"

# [6/10] Создание базовой конфигурации
echo -e "${BLUE}[6/10]${NC} ${YELLOW}Creating the Xray configuration...${NC}"
cat > "$CONFIG_FILE" << 'EOF'
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "localhost"
    ],
    "queryStrategy": "UseIPv4",
    "disableCache": false
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "network": "udp",
        "port": 443,
        "outboundTag": "block"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "bufferSize": 4
      }
    }
  }
}
EOF

chown xray:xray "$CONFIG_FILE"
# Mark config as already optimized (skip migration on first launch)
touch /usr/local/etc/xray/.config_optimized
chown xray:xray /usr/local/etc/xray/.config_optimized
chmod 644 "$CONFIG_FILE"
echo -e "${GREEN}✓ Configuration created${NC}\n"

# [7/10] Настройка Firewall
echo -e "${BLUE}[7/10]${NC} ${YELLOW}Configuring the firewall...${NC}"
UFW_ERRORS=0
for ufw_port in 22 80 443 8443 2053 2083 2087 8080 2096 8880 9443; do
  if ! ufw allow "${ufw_port}/tcp" > /dev/null 2>&1; then
    echo -e "${YELLOW}  ⚠ Could not open port ${ufw_port}/tcp${NC}"
    ((UFW_ERRORS++))
  fi
done

if [[ $UFW_ERRORS -gt 0 ]]; then
  echo -e "${RED}✗ Firewall incompletely configured — install stopped so you do not lose access to the VPS${NC}"
  exit 1
fi

if ! ufw status | grep -q "Status: active"; then
  if ! ufw --force enable > /dev/null 2>&1; then
    echo -e "${RED}✗ Could not enable UFW — check the firewall manually${NC}"
    exit 1
  fi
fi

if ! ufw reload > /dev/null 2>&1; then
  echo -e "${RED}✗ Could not reload UFW — check the firewall manually${NC}"
  exit 1
fi
echo -e "${GREEN}✓ Firewall configured${NC}"
echo -e "${CYAN}  Open ports: 22, 80, 443, 8443, 2053, 2083, 2087, 8080, 2096, 8880, 9443${NC}\n"

# [8/10] Host TCP tuning
echo -e "${BLUE}[8/10]${NC} ${YELLOW}Host TCP tuning is not changed by the installer${NC}"
echo -e "${CYAN}✓ System TCP/sysctl settings left under the VPS operator's control${NC}\n"

# [9/10] Загрузка данных
echo -e "${BLUE}[9/10]${NC} ${YELLOW}Loading application data...${NC}"
github_raw_curl "${RAW_BASE_URL}/sni_list.txt" -o "${DATA_DIR}/sni_list.txt"
if [[ $? -eq 0 ]] && [[ -s "${DATA_DIR}/sni_list.txt" ]]; then
  echo -e "${GREEN}✓ SNI list loaded${NC}"
else
  echo -e "${YELLOW}⚠ Could not download the SNI list, creating a basic one...${NC}"
  cat > "${DATA_DIR}/sni_list.txt" << 'EOF'
www.ozon.ru|ru_whitelist|1
wildberries.ru|ru_whitelist|1
sberbank.ru|ru_whitelist|1
nspk.ru|ru_whitelist|1
speller.yandex.net|yandex_cdn|2
gosuslugi.ru|ru_whitelist|1
stats.vk-portal.net|ru_whitelist|1
github.com|foreign|3
cloudflare.com|foreign|3
www.microsoft.com|foreign|3
EOF
fi

github_raw_curl "${RAW_BASE_URL}/ascii_art.txt" -o "${DATA_DIR}/ascii_art.txt" 2>/dev/null
if [[ -s "${DATA_DIR}/ascii_art.txt" ]]; then
  echo -e "${GREEN}✓ ASCII art loaded${NC}\n"
else
  echo -e "${CYAN}✓ ASCII art unavailable (not critical)${NC}\n"
fi

# [10/10] Установка приложения
echo -e "${BLUE}[10/10]${NC} ${YELLOW}Installing the management app...${NC}"
XRAYTAILSCALE_TMP=$(mktemp /tmp/xraytailscale_install_XXXXXX)
if github_raw_curl "${RAW_BASE_URL}/xraytailscale" --connect-timeout 10 --max-time 60 -o "$XRAYTAILSCALE_TMP" \
   && [[ -s "$XRAYTAILSCALE_TMP" ]] \
   && head -n 1 "$XRAYTAILSCALE_TMP" | grep -q "^#!/bin/bash" \
   && bash -n "$XRAYTAILSCALE_TMP"; then
  chmod 755 "$XRAYTAILSCALE_TMP"
  mv "$XRAYTAILSCALE_TMP" /usr/local/bin/xraytailscale
  echo -e "${GREEN}✓ The xraytailscale app is installed${NC}"
else
  echo -e "${RED}✗ Error downloading xraytailscale${NC}"
  rm -f "$XRAYTAILSCALE_TMP"
  exit 1
fi

# Скрипты управления
UPDATE_TMP=$(mktemp /tmp/xraytailscale_update_install_XXXXXX.sh)
if github_raw_curl "${RAW_BASE_URL}/update.sh" --connect-timeout 10 --max-time 30 -o "$UPDATE_TMP" 2>/dev/null \
   && [[ -s "$UPDATE_TMP" ]] \
   && head -n 1 "$UPDATE_TMP" | grep -q "^#!/bin/bash" \
   && bash -n "$UPDATE_TMP"; then
  chmod 755 "$UPDATE_TMP"
  mv "$UPDATE_TMP" "${SCRIPTS_DIR}/update.sh"
else
  echo -e "${YELLOW}⚠ update.sh was not downloaded or is invalid${NC}"
  rm -f "$UPDATE_TMP"
fi
UNINSTALL_TMP=$(mktemp /tmp/xraytailscale_uninstall_install_XXXXXX.sh)
if github_raw_curl "${RAW_BASE_URL}/uninstall.sh" --connect-timeout 10 --max-time 30 -o "$UNINSTALL_TMP" 2>/dev/null \
   && [[ -s "$UNINSTALL_TMP" ]] \
   && head -n 1 "$UNINSTALL_TMP" | grep -q "^#!/bin/bash" \
   && bash -n "$UNINSTALL_TMP"; then
  chmod 755 "$UNINSTALL_TMP"
  mv "$UNINSTALL_TMP" "${SCRIPTS_DIR}/uninstall.sh"
else
  echo -e "${YELLOW}⚠ uninstall.sh was not downloaded or is invalid${NC}"
  rm -f "$UNINSTALL_TMP"
fi
ln -sf "${SCRIPTS_DIR}/update.sh" /usr/local/bin/xraytailscale-update 2>/dev/null
ln -sf "${SCRIPTS_DIR}/uninstall.sh" /usr/local/bin/xraytailscale-uninstall 2>/dev/null
legacy_cmd="xrayeba""tor"
rm -f "/usr/local/bin/${legacy_cmd}" "/usr/local/bin/${legacy_cmd}-update" "/usr/local/bin/${legacy_cmd}-uninstall" 2>/dev/null || true
echo "$GITHUB_BRANCH" > /usr/local/etc/xray/.current_branch
chown xray:xray /usr/local/etc/xray/.current_branch 2>/dev/null || true
echo -e "${GREEN}✓ Scripts installed${NC}\n"

# Запуск Xray
systemctl enable xray > /dev/null 2>&1

# Pre-validate config перед restart (REQ-D03)
echo -e "${YELLOW}Validating config.json before starting Xray...${NC}"

# Guard #1: файл существует и не пуст
if [[ ! -f /usr/local/etc/xray/config.json || ! -s /usr/local/etc/xray/config.json ]]; then
  echo -e "${RED}✗ config.json is missing or empty${NC}"
  echo -e "${RED}Install aborted. Check /usr/local/etc/xray/config.json manually.${NC}"
  exit 1
fi

# Guard #2: xray run -test (grep stdout — exit code ненадёжен: возвращает 0 на missing file)
if ! xray run -test -config /usr/local/etc/xray/config.json 2>&1 | grep -q "^Configuration OK\.$"; then
  echo -e "${RED}✗ config.json is invalid (xray run -test failed)${NC}"
  echo -e "${YELLOW}xray output:${NC}"
  xray run -test -config /usr/local/etc/xray/config.json 2>&1 | head -20
  echo -e "${RED}Install aborted. Check /usr/local/etc/xray/config.json manually.${NC}"
  exit 1
fi
echo -e "${GREEN}✓ config.json passed validation${NC}"

systemctl restart xray > /dev/null 2>&1
if systemctl is-active --quiet xray; then
  echo -e "${GREEN}✓ Xray started successfully${NC}\n"
else
  echo -e "${CYAN}✓ Xray installed (it will start when a profile is created)${NC}\n"
fi

# Финальное сообщение
clear
echo -e "${GREEN}"
echo '╔═══════════════════════════════════════════════════════════╗'
echo '║                                                           ║'
echo '║          ✓ INSTALLATION COMPLETED SUCCESSFULLY!                 ║'
echo '║                                                           ║'
echo '╚═══════════════════════════════════════════════════════════╝'
echo -e "${NC}\n"
echo -e "${CYAN}To manage the server, run:${NC}"
echo -e "${YELLOW}╭──────────────────────────╮${NC}"
echo -e "${YELLOW}│ ${GREEN}sudo xraytailscale${YELLOW}          │${NC}"
echo -e "${YELLOW}╰──────────────────────────╯${NC}\n"
echo -e "${BLUE}Additional commands:${NC}"
echo -e "  ${CYAN}sudo xraytailscale-update${NC}    - update XrayTailscale"
echo -e "  ${CYAN}sudo xraytailscale-uninstall${NC} - remove XrayTailscale"
echo ""
echo -e "${BLUE}Open firewall ports:${NC}"
echo -e "  ${GREEN}443/tcp${NC}  - HTTPS (main)"
echo ""
echo -e "${BLUE}GitHub:${NC} https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
echo -e "${BLUE}Version:${NC} 2.0"
echo ""

# ── Первичная настройка ──────────────────────────────────────────────────────
# Три сценария:
#   XT_DOMAIN=<домен>  — нон-интерактивно: self-steal + главный профиль на :443;
#   интерактивный tty  — сразу запускаем мастер (домен/без домена, первый
#                        пользователь, подписка, внешняя проверка, ссылка/QR);
#   без tty            — печатаем, как запустить мастер вручную.
if [[ -n "${XT_DOMAIN:-}" ]]; then
  echo -e "${BLUE}[self-steal]${NC} ${YELLOW}Auto-deploying for domain ${XT_DOMAIN}...${NC}"
  XT_SS_EMAIL="${XT_LE_EMAIL:-admin@${XT_DOMAIN}}"
  if /usr/local/bin/xraytailscale selfsteal-auto "$XT_DOMAIN" "$XT_SS_EMAIL"; then
    echo -e "\n${GREEN}✓ Self-steal deployed: main profile on :443 (${XT_DOMAIN})${NC}"
    echo -e "${CYAN}  Add the subscription and the remaining users: sudo xraytailscale${NC}"
  else
    echo -e "\n${YELLOW}⚠ Self-steal auto-deploy failed — the base install is OK.${NC}"
    echo -e "${YELLOW}  Retry: sudo xraytailscale selfsteal-auto ${XT_DOMAIN}${NC}"
  fi
  echo ""
elif [[ -t 0 ]]; then
  echo -e "${BLUE}[wizard]${NC} ${YELLOW}Initial setup: 5 steps to a working subscription.${NC}"
  echo ""
  /usr/local/bin/xraytailscale wizard || {
    echo -e "${YELLOW}⚠ Wizard not completed — the base components are installed.${NC}"
    echo -e "${YELLOW}  Run later: sudo xraytailscale wizard${NC}"
  }
  echo ""
else
  echo -e "${BLUE}Next:${NC} run the initial setup wizard:"
  echo -e "  ${GREEN}sudo xraytailscale wizard${NC}   (5 steps to a working subscription)"
  echo -e "  or just ${GREEN}sudo xraytailscale${NC} — on a fresh server the wizard starts by itself"
  echo ""
fi
echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
