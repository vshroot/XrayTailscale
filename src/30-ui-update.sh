_refresh_legacy_ascii_art() {
  local ASCII_URL="${RAW_BASE_URL}/ascii_art.txt"
  if [[ -f "$ASCII_ART" ]] && grep -q "Киса" "$ASCII_ART" 2>/dev/null; then
    github_raw_curl "$ASCII_URL" -o "$ASCII_ART" 2>/dev/null || true
    if [[ -f "$ASCII_ART" ]] && grep -q "Киса" "$ASCII_ART" 2>/dev/null; then
      rm -f "$ASCII_ART"
    fi
  fi
}

show_ascii() {
  clear
  local ASCII_URL="${RAW_BASE_URL}/ascii_art.txt"
  _refresh_legacy_ascii_art
  if [[ ! -f "$ASCII_ART" ]]; then
    mkdir -p "$(dirname "$ASCII_ART")"
    github_raw_curl "$ASCII_URL" -o "$ASCII_ART" 2>/dev/null || true
    _refresh_legacy_ascii_art
  fi
  if [[ -f "$ASCII_ART" ]] && [[ -s "$ASCII_ART" ]]; then
    echo -e "${CYAN}"
    cat "$ASCII_ART"
    echo -e "${NC}"
  else
    echo -e "${CYAN}"
    echo ' ╔═══════════════════════════════════╗'
    echo ' ║                                   ║'
    echo ' ║        XRAYTAILSCALE v2.0        ║'
    echo ' ║ Xray Reality VPN + Tailscale     ║'
    echo ' ║                                   ║'
    echo ' ╚═══════════════════════════════════╝'
    echo -e "${NC}"
  fi
  echo -e "${BLUE}XrayTailscale v2.0${NC}"
  echo ""
}

# ═══════════════════════════════════════════════════════════
# INLINE-КОПИЯ update_xray_core() + хелперов (REQ-B01/B02)
# Синхронизирована с update.sh / install.sh через
# validation/test-update-xray-core-sync.sh (sync-test parity).
# Trigger = CLI `xraytailscale update` через update_command().
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

  # ── Step 5: Confirmation prompt (CONTEXT.md decision 2) ────────
  echo -e "${CYAN}Xray-core update available:${NC}"
  echo -e "  ${YELLOW}Current:${NC} $CURRENT_VERSION"
  echo -e "  ${GREEN}New:${NC}    $TARGET_VERSION"
  echo -e "  ${CYAN}Size:${NC}   ~6.5MB (zip)"
  echo -e "  ${CYAN}Downtime:${NC} ~5 seconds"
  echo ""
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

# CLI subcommand: xraytailscale update (REQ-B02)
# Запускает update_xray_core, отображает заголовок.
# Возвращает exit code функции, НЕ exit: иначе вызов из «Дополнительно»
# закрыл бы весь менеджер вместо возврата в меню. CLI (src/99-dispatch.sh)
# и так отдаёт код возврата как статус процесса.
update_command() {
  echo -e "${BLUE}╔════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  XrayTailscale: Xray-core update               ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
  echo ""

  update_xray_core
  local rc=$?
  case $rc in
    0) ;;
    1) echo -e "${CYAN}  → Update skipped by the user${NC}" ;;
    2) echo -e "${RED}✗ Critical update error${NC}" ;;
    3) echo -e "${YELLOW}⚠ Rolled back to the old version${NC}" ;;
  esac
  return $rc
}

# Nag: предупреждение об устаревшем Xray-core в main_menu (REQ-B02)
# Запрашивает GitHub API раз в 24 часа (cache в /tmp), не блокирует на timeout.
_check_xray_outdated_nag() {
  local cache_file="/tmp/.xraytailscale_xray_latest_check"
  local cache_ttl=86400

  # Проверяем свежесть кэша
  if [[ -f "$cache_file" ]]; then
    local age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
    if [[ $age -lt $cache_ttl ]]; then
      local cached_tag
      cached_tag=$(cat "$cache_file" 2>/dev/null)
      [[ -n "$cached_tag" ]] && _emit_nag_if_outdated "$cached_tag"
      return 0
    fi
  fi

  # Обновляем кэш (silent, короткий timeout — не блокировать main_menu)
  local tag
  tag=$(curl -fsSL --connect-timeout 3 --max-time 5 \
    "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
    | jq -r '.tag_name // ""' 2>/dev/null)

  if [[ -n "$tag" && "$tag" != "null" ]]; then
    echo "$tag" > "$cache_file"
    _emit_nag_if_outdated "$tag"
  fi
  # Тихий fail если GitHub недоступен — не показываем nag.
}

_emit_nag_if_outdated() {
  local target_tag="$1"
  local current target_v
  current=$(/usr/local/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')
  target_v="${target_tag#v}"
  [[ -z "$current" || "$current" == "$target_v" ]] && return

  # Comparison: nag если major вырос ИЛИ minor отстает >= 2 (CONTEXT.md decision)
  local cm cn tm tn
  cm=$(echo "$current" | awk -F. '{print $1}')
  cn=$(echo "$current" | awk -F. '{print $2}')
  tm=$(echo "$target_v" | awk -F. '{print $1}')
  tn=$(echo "$target_v" | awk -F. '{print $2}')

  local should_nag=false
  [[ $tm -gt $cm ]] && should_nag=true
  [[ $tm -eq $cm && $((tn - cn)) -ge 2 ]] && should_nag=true

  if $should_nag; then
    echo -e "${YELLOW}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║ Xray $current installed, $target_v available${NC}"
    echo -e "${YELLOW}║ Run: ${GREEN}sudo xraytailscale update${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
  fi
}

# Одноразовый баннер о post-quantum encryption (REQ-A10).
# Показывается РОВНО ОДИН РАЗ — на первом запуске после установки/обновления v2.0.
# Маркер: /usr/local/etc/xray/.pq_banner_shown
# Содержит: краткое объяснение PQ + матрица совместимости клиентов на 2026-05-10
# + рекомендация для пользователей не-PQ клиентов создать отдельный legacy профиль.
show_pq_banner_once() {
  local marker="/usr/local/etc/xray/.pq_banner_shown"
  if [[ -f "$marker" ]]; then
    return 0
  fi

  echo ""
  echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}║       🔐 POST-QUANTUM ENCRYPTION (ML-KEM-768) ENABLED            ║${NC}"
  echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${CYAN}What it is:${NC}"
  echo -e "  All NEW XHTTP profiles are now protected against 'Harvest Now, Decrypt Later' —"
  echo -e "  attacks where traffic is recorded today to be decrypted on a quantum"
  echo -e "  computer in 5-10 years. ML-KEM-768 is used on top of Reality."
  echo ""
  echo -e "${YELLOW}Client compatibility as of 2026-05-10:${NC}"
  echo ""
  echo -e "  ${GREEN}✓ Supported:${NC}"
  echo -e "    ${GREEN}•${NC} HAPP 2.10+ (Android/iOS)"
  echo -e "    ${GREEN}•${NC} v2rayNG 1.10+ (Android)"
  echo -e "    ${GREEN}•${NC} v2rayN (Windows/macOS, PR #7782 merged)"
  echo -e "    ${GREEN}•${NC} Shadowrocket (iOS, App Store since 2026-05-10)"
  echo ""
  echo -e "  ${RED}✗ NOT supported (use legacy TCP+Vision):${NC}"
  echo -e "    ${RED}•${NC} sing-box (all forks)"
  echo -e "    ${RED}•${NC} Hiddify"
  echo -e "    ${RED}•${NC} mihomo (Clash Meta)"
  echo -e "    ${RED}•${NC} NekoBox / NekoRay"
  echo ""
  echo -e "  ${YELLOW}? Status unknown:${NC}"
  echo -e "    ${YELLOW}•${NC} Streisand (iOS) — check the release notes"
  echo ""
  echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║ RECOMMENDATION:                                                      ║${NC}"
  echo -e "${BLUE}║ If your client is in the ✗ line — create a separate legacy profile:    ║${NC}"
  echo -e "${BLUE}║   menu → 1 (Create profile) → choose 'TCP+Vision (legacy)'      ║${NC}"
  echo -e "${BLUE}║ for compatible clients use the new PQ XHTTP profile        ║${NC}"
  echo -e "${BLUE}║ (created by default).                                          ║${NC}"
  echo -e "${BLUE}║                                                                    ║${NC}"
  echo -e "${BLUE}║ Existing profile files can be switched to PQ via       ║${NC}"
  echo -e "${BLUE}║   menu → 8 (Upgrade profile to post-quantum)                      ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -n -e "${YELLOW}This banner will not appear again. Press Enter to continue...${NC}"
  read

  # Mark as shown — touch + chown как в run_migration helper.
  # Если touch упадёт (broken /usr/local/etc/xray/) — баннер появится снова. OK.
  touch "$marker" 2>/dev/null || true
  chown xray:xray "$marker" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════
# HAPP Subscription server installer (Phase 7, Plan 7.2)
# ═══════════════════════════════════════════════════════════
# Heredoc-генерирует ТРИ артефакта:
#   1) /usr/local/bin/subhttp.sh                — HTTP handler (755 root:root);
#   2) /etc/systemd/system/xraytailscale-sub.service — opt-in systemd unit (644 root:root);
#   3) /usr/local/etc/xray/.happ_defaults.env   — HAPP metadata defaults (644 xray:xray),
#      создаётся только если отсутствует (idempotent — не перетираем правки оператора).
# Marker: /usr/local/etc/xray/.subscription_installed (Plan 7.3 проверит наличие).
# Юнит НЕ enable-ится и НЕ start-ится автоматически — этим занимается Plan 7.3 после
# выбора публичного TLS (default) или local-only fallback.
