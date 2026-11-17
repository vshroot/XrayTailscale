# ═══════════════════════════════════════════════════════════
# Мастер первичной настройки: «чистый сервер → рабочая подписка»
# ═══════════════════════════════════════════════════════════
# 5 шагов, два режима (домен / без домена), state + resume.
# Каждый шаг идемпотентен: повторный запуск не дублирует профили и подписку.
#
# Порядок в шаге 4 КРИТИЧЕН: сначала _selfsteal_provision (занимает :443 и
# берёт localhost-backend из диапазона 8443–12443), и только после успеха —
# подписка.
# При self-steal подписка ставится в ДОМЕННОМ режиме на том же :443
# (install_subscription_selfsteal_domain): https://<domain>/sub/<token> —
# без отдельного порта и без нового сертификата (LE уже выпущен self-steal).
# Это НЕ старый доменный режим с отдельным vhost на :80: тот дублировал
# server_name <domain> и затенял ACME webroot, ломая продление сертификатов.
# Здесь /sub/ добавляется в backend-блок self-steal (127.0.0.1:<backend_port>),
# а ACME по-прежнему обслуживает только вебрут self-steal.
# Без домена подписка ставится в IP-режиме (install_subscription_ip_tls).
#
# State: /usr/local/etc/xray/.wizard_state — KEY=VALUE, STEP = шаг, который
# нужно выполнить (он же — точка resume).  Маркер завершения: .wizard_done.

# Пути вынесены в переменные с override через env — только для тестов
# (прод всегда /usr/local/etc/xray/).
WIZARD_STATE_FILE="${WIZARD_STATE_FILE:-/usr/local/etc/xray/.wizard_state}"
WIZARD_DONE_FILE="${WIZARD_DONE_FILE:-/usr/local/etc/xray/.wizard_done}"
WIZARD_URL_FILE="${WIZARD_URL_FILE:-/usr/local/etc/xray/.wizard_subscription_url}"
# Маркер установленной подписки (пишет 35-subscription.sh). Переопределяется
# только в тестах — в проде всегда /usr/local/etc/xray/.subscription_installed.
WIZARD_SUBSCRIPTION_MARKER="${WIZARD_SUBSCRIPTION_MARKER:-/usr/local/etc/xray/.subscription_installed}"
WIZARD_SUB_PORT_FILE="${WIZARD_SUB_PORT_FILE:-/usr/local/etc/xray/.subscription_port}"
WIZARD_SUB_MODE_FILE="${WIZARD_SUB_MODE_FILE:-/usr/local/etc/xray/.subscription_mode}"
WIZARD_TOTAL_STEPS=5
WIZARD_DEFAULT_USER="user-001"

# ─── Детект «чистого» сервера ───────────────────────────────
# return 0: мастер ещё не проходили И (inbound'ов нет ИЛИ подписка не стоит).
wizard_is_fresh_install() {
  [[ -f "$WIZARD_DONE_FILE" ]] && return 1

  local inbound_count=0
  if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
    inbound_count=$(jq -r '.inbounds | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    [[ "$inbound_count" =~ ^[0-9]+$ ]] || inbound_count=0
  fi
  if [[ "$inbound_count" -eq 0 ]]; then
    return 0
  fi

  [[ -f "$WIZARD_SUBSCRIPTION_MARKER" ]] || return 0
  return 1
}

# ─── root-проверка ──────────────────────────────────────────
# Вынесена в helper: тесты подменяют её, не трогая прод-логику.
_wizard_has_root() {
  [[ $EUID -eq 0 ]]
}

# ─── State (resume) ─────────────────────────────────────────
# Атомарная запись KEY=VALUE: tmp-файл в том же каталоге + mv.
_wizard_state_set() {
  local key="${1:-}"
  local value="${2:-}"
  [[ -n "$key" ]] || return 1

  local dir tmp lock_fd
  dir=$(dirname "$WIZARD_STATE_FILE")
  mkdir -p "$dir" 2>/dev/null || true

  # Сериализация read-modify-write: два одновременных запуска мастера
  # (меню + CLI) иначе теряют ключи друг друга (проверено: 3 писателя → 1 ключ).
  # flock может отсутствовать (util-linux) — тогда пишем без блокировки.
  if command -v flock >/dev/null 2>&1; then
    exec {lock_fd}>"${WIZARD_STATE_FILE}.lock" 2>/dev/null || lock_fd=""
    if [[ -n "$lock_fd" ]]; then
      flock -w 5 "$lock_fd" 2>/dev/null || true
    fi
  fi

  tmp=$(mktemp "${WIZARD_STATE_FILE}.XXXXXX" 2>/dev/null) || {
    [[ -n "${lock_fd:-}" ]] && exec {lock_fd}>&-
    return 1
  }
  if [[ -f "$WIZARD_STATE_FILE" ]]; then
    grep -v "^${key}=" "$WIZARD_STATE_FILE" > "$tmp" 2>/dev/null || true
  fi
  if ! printf '%s=%s\n' "$key" "$value" >> "$tmp"; then
    rm -f "$tmp"
    [[ -n "${lock_fd:-}" ]] && exec {lock_fd}>&-
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  if ! mv "$tmp" "$WIZARD_STATE_FILE"; then
    rm -f "$tmp"
    [[ -n "${lock_fd:-}" ]] && exec {lock_fd}>&-
    return 1
  fi
  [[ -n "${lock_fd:-}" ]] && exec {lock_fd}>&-
  return 0
}

# stdout: значение ключа. return 1 если ключа/файла нет.
_wizard_state_get() {
  local key="${1:-}"
  [[ -n "$key" && -f "$WIZARD_STATE_FILE" ]] || return 1

  local line
  line=$(grep -m1 "^${key}=" "$WIZARD_STATE_FILE" 2>/dev/null || true)
  [[ -n "$line" ]] || return 1
  printf '%s\n' "${line#*=}"
  return 0
}

_wizard_state_clear() {
  rm -f "$WIZARD_STATE_FILE" 2>/dev/null || true
  return 0
}

# ─── UI ─────────────────────────────────────────────────────
_wizard_print_header() {
  echo ""
  echo -e "${BLUE}╔═══════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║         FIRST-TIME SERVER SETUP WIZARD         ║${NC}"
  echo -e "${BLUE}║     from a clean VPS to a ready subscription   ║${NC}"
  echo -e "${BLUE}╚═══════════════════════════════════════════════╝${NC}"
  echo ""
}

_wizard_step_title() {
  case "${1:-}" in
    1) echo "Server check" ;;
    2) echo "Domain and email" ;;
    3) echo "First user" ;;
    4) echo "Domain mode and subscription" ;;
    5) echo "Verify and link" ;;
    *) echo "continue" ;;
  esac
}

_wizard_step_banner() {
  local step="${1:-}"
  echo ""
  echo -e "${MAGENTA}═══ Step ${step}/${WIZARD_TOTAL_STEPS}. $(_wizard_step_title "$step") ═══${NC}"
  echo ""
}

# Спросить «повторить шаг или выйти». return 0 = повторить, 1 = выйти.
_wizard_confirm_retry_or_exit() {
  local ans attempts=0
  while true; do
    ((attempts++))
    if [[ $attempts -gt 10 ]]; then
      echo ""
      echo -e "${RED}  Too many invalid attempts — exiting${NC}"
      return 1
    fi
    echo ""
    echo -e "${CYAN}  [1]${NC} Retry step   ${CYAN}[0]${NC} Exit"
    echo -n -e "${YELLOW}Choose an action: ${NC}"
    if ! read -r ans; then
      echo ""
      return 1
    fi
    case "$ans" in
      1) return 0 ;;
      0) return 1 ;;
      *) echo -e "${RED}  Invalid choice — enter 1 or 0${NC}" ;;
    esac
  done
}

# Резолв домена для диагностики DNS (stdout: IP или «не резолвится»).
_wizard_dns_resolved_ip() {
  local domain="${1:-}"
  local ip=""
  if [[ -n "$domain" ]]; then
    ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)
  fi
  [[ -n "$ip" ]] || ip="не резолвится"
  echo "$ip"
}

# Уже стоит рабочая подписка (ip_tls) и её порт реально слушается.
_wizard_subscription_ready() {
  [[ -f "$WIZARD_SUBSCRIPTION_MARKER" ]] || return 1
  [[ "$(cat "$WIZARD_SUB_MODE_FILE" 2>/dev/null || true)" == "ip_tls" ]] || return 1

  local port
  port=$(cat "$WIZARD_SUB_PORT_FILE" 2>/dev/null || true)
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  # Без ss подтвердить listen нельзя — считаем «не готово» и переустанавливаем
  # (installer идемпотентен: certbot переиспользует действующий сертификат).
  command -v ss >/dev/null 2>&1 || return 1
  ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .
}

# Пояснение про порты: в режиме домена backend self-steal занимает первый
# свободный порт диапазона, поэтому подписка уезжает на следующий (ожидаемо).
_wizard_detect_ports_note() {
  local mode="" backend_port="" sub_port="" ufw_active="no"
  mode=$(_wizard_state_get MODE 2>/dev/null || true)
  [[ -n "$mode" ]] || mode=$(cat "$WIZARD_SUB_MODE_FILE" 2>/dev/null || echo "ip")
  backend_port=$(cat "$SELFSTEAL_PORT_FILE" 2>/dev/null || true)
  sub_port=$(cat "$WIZARD_SUB_PORT_FILE" 2>/dev/null || true)
  [[ -n "$sub_port" ]] || return 0

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw_active="yes"
  fi

  local ufw_note=""
  if [[ "$ufw_active" == "yes" ]]; then
    if ufw status 2>/dev/null | grep -qE "^${sub_port}/tcp"; then
      ufw_note="порт открыт в ufw"
    else
      ufw_note="⚠ порта ${sub_port}/tcp нет в ufw — откройте: ufw allow ${sub_port}/tcp"
    fi
  else
    ufw_note="ufw неактивен — порты открываются iptables-правилами проекта"
  fi

  if [[ "$mode" == "domain" && -n "$backend_port" && "$sub_port" != "$backend_port" ]]; then
    echo -e "${CYAN}  ℹ Subscription on :${sub_port}${NC} ${YELLOW}(self-steal localhost backend took ${backend_port})${NC}"
    echo -e "${CYAN}    ${ufw_note}${NC}"
  else
    echo -e "${CYAN}  ℹ Subscription on :${sub_port} — ${ufw_note}${NC}"
  fi
  return 0
}

# ─── Шаг 5: финальный блок + маркеры ────────────────────────
_wizard_final_report() {
  local mode="$1" domain="$2" sub_port="$3" url="$4" user_name="$5"

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║         ✓ DONE: SERVER IS CONFIGURED             ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}"
  echo ""
  if [[ "$mode" == "domain" ]]; then
    echo -e "${BLUE}Mode:${NC}           ${GREEN}domain ${domain} (self-steal, :443)${NC}"
  else
    echo -e "${BLUE}Mode:${NC}           ${GREEN}no domain (Reality, :443)${NC}"
  fi
  echo -e "${BLUE}User:${NC}   ${GREEN}${user_name}${NC}"
  echo -e "${BLUE}Subscription port:${NC}  ${GREEN}${sub_port}${NC}"
  _wizard_detect_ports_note
  echo ""
  echo -e "${BLUE}Subscription link (HAPP / v2rayNG / Streisand):${NC}"
  echo -e "${GREEN}${url}${NC}"
  echo ""

  # umask 077: файл создаётся сразу 600 (в URL — sub_token, это секрет).
  # chmod ниже — страховка (defense-in-depth) и контракт для тестов.
  if ( umask 077; printf '%s\n' "$url" > "$WIZARD_URL_FILE" ) 2>/dev/null; then
    chmod 600 "$WIZARD_URL_FILE" 2>/dev/null || true
    echo -e "${CYAN}Link saved to file: ${WIZARD_URL_FILE}${NC}"
  else
    echo -e "${YELLOW}⚠ Could not save the link to ${WIZARD_URL_FILE}${NC}"
  fi
  echo ""

  if command -v qrencode >/dev/null 2>&1; then
    if ! _print_qr_block "$url"; then
      echo -e "${YELLOW}⚠ qrencode could not build the QR — copy the link above${NC}"
    fi
  else
    echo -e "${YELLOW}⚠ qrencode is not installed — QR not shown.${NC}"
    echo -e "${YELLOW}  Install it: apt-get install -y qrencode${NC}"
  fi
  echo ""
  echo -e "${CYAN}Import the link into your client: one subscription serves all routes.${NC}"

  touch "$WIZARD_DONE_FILE" 2>/dev/null || true
  chmod 600 "$WIZARD_DONE_FILE" 2>/dev/null || true
  _wizard_state_clear

  echo ""
  echo -e "${GREEN}✓ Wizard finished. Run again: sudo xraytailscale wizard${NC}"
  echo ""
}

# ─── Главный сценарий ───────────────────────────────────────
# $1 = "force" — игнорировать .wizard_done (CLI `xraytailscale wizard`).
run_first_run_wizard() {
  local force="${1:-}"
  local resume_step=1 ans=""

  _wizard_print_header

  if ! _wizard_has_root; then
    echo -e "${RED}✗ The wizard needs root privileges${NC}"
    echo -e "${YELLOW}  Run: sudo xraytailscale wizard${NC}"
    return 1
  fi

  if [[ -f "$WIZARD_DONE_FILE" && "$force" != "force" ]]; then
    echo -e "${YELLOW}The server is already configured by the wizard (marker ${WIZARD_DONE_FILE}).${NC}"
    echo -e "${YELLOW}  Force re-run: sudo xraytailscale wizard${NC}"
    return 0
  fi

  # ── Resume: есть незавершённый state ──
  if [[ -f "$WIZARD_STATE_FILE" ]]; then
    local saved_step=""
    saved_step=$(_wizard_state_get STEP || true)
    if [[ "$saved_step" =~ ^[1-5]$ ]]; then
      local saved_mode="" saved_domain=""
      saved_mode=$(_wizard_state_get MODE || true)
      saved_domain=$(_wizard_state_get DOMAIN || true)

      echo -e "${YELLOW}Found an unfinished wizard: last step ${saved_step}/${WIZARD_TOTAL_STEPS}.${NC}"
      if [[ -n "$saved_mode" ]]; then
        if [[ -n "$saved_domain" ]]; then
          echo -e "${CYAN}  Saved: mode ${saved_mode} (${saved_domain})${NC}"
        else
          echo -e "${CYAN}  Saved: mode ${saved_mode}${NC}"
        fi
      fi
      echo -n -e "${YELLOW}Continue from step ${saved_step}? [Y/n]: ${NC}"
      if ! read -r ans; then
        echo ""
        echo -e "${RED}✗ No input (non-interactive run) — wizard aborted${NC}"
        return 1
      fi
      if [[ "$ans" =~ ^[nNнН]$ ]]; then
        _wizard_state_clear
        resume_step=1
      else
        resume_step="$saved_step"
      fi
      echo ""
    fi
  fi

  # ─────────────── Шаг 1/5: Проверка сервера ───────────────
  if [[ $resume_step -le 1 ]]; then
    while true; do
      _wizard_state_set STEP 1
      _wizard_step_banner 1

      local step1_failed=0
      local xray_bin="" listener=""

      echo -e "${GREEN}✓ root privileges${NC}"

      if command -v xray >/dev/null 2>&1; then
        xray_bin=$(command -v xray)
      elif [[ -x /usr/local/bin/xray ]]; then
        xray_bin="/usr/local/bin/xray"
      fi
      if [[ -n "$xray_bin" ]]; then
        echo -e "${GREEN}✓ xray-core: ${xray_bin}${NC}"
      else
        echo -e "${RED}✗ xray-core not found (neither in PATH nor /usr/local/bin/xray)${NC}"
        echo -e "${YELLOW}  Install: sudo bash install.sh${NC}"
        step1_failed=1
      fi

      if command -v systemctl >/dev/null 2>&1; then
        echo -e "${GREEN}✓ systemd is available (systemctl)${NC}"
      else
        echo -e "${RED}✗ systemctl not found — the server is not on systemd${NC}"
        echo -e "${YELLOW}  This project targets Debian/Ubuntu with systemd.${NC}"
        step1_failed=1
      fi

      if command -v ufw >/dev/null 2>&1; then
        local ufw_status_line=""
        ufw_status_line=$(ufw status 2>/dev/null | head -1)
        echo -e "${GREEN}✓ ufw: ${ufw_status_line:-status unknown}${NC}"
        if ! ufw status 2>/dev/null | grep -q "Status: active"; then
          echo -e "${YELLOW}  ℹ ufw is off — ports will be opened by the project iptables rules${NC}"
        fi
      else
        echo -e "${YELLOW}⚠ ufw is not installed — ports will be opened by the project iptables rules${NC}"
      fi

      if ! command -v ss >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ ss not found (iproute2) — skipping the :443 check${NC}"
      else
        # -p нужен, чтобы показать, кто именно слушает порт.
        listener=$(ss -tlnpH 'sport = :443' 2>/dev/null | head -1)
        if [[ -z "$listener" ]]; then
          echo -e "${GREEN}✓ port :443 is free${NC}"
        elif [[ "$listener" == *xray* ]]; then
          echo -e "${GREEN}✓ port :443 is already listened by Xray${NC}"
        else
          echo -e "${RED}✗ port :443 is taken by another process${NC}"
          echo -e "${YELLOW}  Listening: ${listener}${NC}"
          echo -e "${YELLOW}  Free the port: systemctl stop <service> (nginx/apache/etc.)${NC}"
          step1_failed=1
        fi
      fi

      if [[ $step1_failed -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}✓ Server check passed${NC}"
        break
      fi
      echo ""
      echo -e "${YELLOW}  Fix the issues above and retry the step.${NC}"
      _wizard_confirm_retry_or_exit || return 1
    done
  fi

  # ─────────────── Шаг 2/5: Домен и email ──────────────────
  if [[ $resume_step -le 2 ]]; then
    _wizard_state_set STEP 2
    _wizard_step_banner 2

    local mode="" domain="" email=""
    local have_domain="n"
    local saved_mode="" saved_domain=""
    saved_mode=$(_wizard_state_get MODE || true)
    saved_domain=$(_wizard_state_get DOMAIN || true)

    echo -e "${CYAN}Your own domain enables self-steal mode: on :443 outsiders see your site${NC}"
    echo -e "${CYAN}with a valid certificate, your clients get VLESS+Reality.${NC}"
    echo -e "${CYAN}Without a domain — classic Reality over IP (SNI from the whitelist).${NC}"
    echo ""
    echo -n -e "${YELLOW}Do you have your own domain pointing to this server? [y/N]: ${NC}"
    if ! read -r have_domain; then
      echo ""
      echo -e "${RED}✗ No input (non-interactive run) — wizard aborted${NC}"
      return 1
    fi
    [[ -z "$have_domain" ]] && have_domain="n"

    if [[ "$have_domain" =~ ^[yYдД]$ ]]; then
      mode="domain"
      local domain_attempts=0
      while true; do
        ((domain_attempts++))
        if [[ $domain_attempts -gt 10 ]]; then
          echo -e "${RED}✗ Too many domain attempts — wizard aborted${NC}"
          return 1
        fi
        local domain_hint="$saved_domain"
        if [[ -n "$domain_hint" ]]; then
          echo -n -e "${YELLOW}Domain [${CYAN}${domain_hint}${YELLOW}]: ${NC}"
        else
          echo -n -e "${YELLOW}Domain (A record → this server): ${NC}"
        fi
        read -r domain || {
          echo ""
          echo -e "${RED}✗ No input (non-interactive run) — wizard aborted${NC}"
          return 1
        }
        [[ -z "$domain" ]] && domain="$domain_hint"

        if ! validate_server_domain "$domain"; then
          echo -e "${RED}✗ Invalid domain: '${domain}'${NC}"
          echo -e "${YELLOW}  Need an FQDN without scheme or path, e.g. example.com${NC}"
          continue
        fi

        if _selfsteal_dns_check "$domain"; then
          echo -e "${GREEN}✓ DNS: ${domain} → $(get_server_ip)${NC}"
          break
        fi

        echo -e "${RED}✗ DNS mismatch${NC}"
        echo -e "${YELLOW}  Expected this VPS IP: ${CYAN}$(get_server_ip)${NC}"
        echo -e "${YELLOW}  Actual resolve:     ${CYAN}$(_wizard_dns_resolved_ip "$domain")${NC}"
        echo -e "${YELLOW}  Wait for DNS to update or change the A record at your registrar.${NC}"
        echo ""
        echo -e "${CYAN}  [1]${NC} Enter another domain"
        echo -e "${CYAN}  [2]${NC} Continue without a domain (IP mode)"
        echo -n -e "${YELLOW}Choose an action: ${NC}"
        local dns_choice=""
        if ! read -r dns_choice; then
          echo ""
          echo -e "${RED}✗ No input (non-interactive run) — wizard aborted${NC}"
          return 1
        fi
        case "$dns_choice" in
          2)
            mode="ip"
            domain=""
            echo -e "${YELLOW}  → Continuing without a domain (Reality over IP)${NC}"
            break
            ;;
          1) continue ;;
          *)
            echo -e "${RED}  Invalid choice — enter 1 or 2${NC}"
            continue
            ;;
        esac
      done
    else
      mode="ip"
    fi

    if [[ "$mode" == "domain" && -n "$domain" ]]; then
      _wizard_state_set MODE "domain"
      _wizard_state_set DOMAIN "$domain"
      echo -e "${GREEN}✓ Mode: domain ${domain}${NC}"
    else
      mode="ip"
      _wizard_state_set MODE "ip"
      _wizard_state_set DOMAIN ""
      echo -e "${GREEN}✓ Mode: no domain (Reality over IP)${NC}"
    fi

    # Email нужен в обоих режимах: Let's Encrypt (IP-сертификат подписки /
    # сертификат домена) требует контакт для renew и account notices.
    local email_default=""
    if [[ "$mode" == "domain" ]]; then
      email_default="admin@${domain}"
    fi
    local saved_email=""
    saved_email=$(_wizard_state_get EMAIL || true)
    [[ -n "$saved_email" ]] && email_default="$saved_email"

    local email_attempts=0
    while true; do
      ((email_attempts++))
      if [[ $email_attempts -gt 10 ]]; then
        echo -e "${RED}✗ Too many email attempts — wizard aborted${NC}"
        return 1
      fi
      if [[ -n "$email_default" ]]; then
        echo -n -e "${YELLOW}Let's Encrypt email [${CYAN}${email_default}${YELLOW}]: ${NC}"
      else
        echo -n -e "${YELLOW}Let's Encrypt email (required for the certificate): ${NC}"
      fi
      read -r email || {
        echo ""
        echo -e "${RED}✗ No input (non-interactive run) — wizard aborted${NC}"
        return 1
      }
      [[ -z "$email" ]] && email="$email_default"
      if [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        break
      fi
      echo -e "${RED}✗ Invalid email: '${email}'${NC}"
      echo -e "${YELLOW}  Example: name@example.com${NC}"
    done
    _wizard_state_set EMAIL "$email"
    echo -e "${GREEN}✓ Email: ${email}${NC}"
  fi

  # ─────────────── Шаг 3/5: Первый пользователь ────────────
  if [[ $resume_step -le 3 ]]; then
    while true; do
      _wizard_state_set STEP 3
      _wizard_step_banner 3

      local user_name=""
      local default_user="$WIZARD_DEFAULT_USER"
      local bulk_default=""
      if declare -F _bulk_target_name >/dev/null 2>&1; then
        bulk_default=$(_bulk_target_name user 1 1 2>/dev/null || true)
        [[ -n "$bulk_default" ]] && default_user="$bulk_default"
      fi
      local saved_user=""
      saved_user=$(_wizard_state_get USER_NAME || true)
      # Ревалидация: state-файл может быть подправлен вручную (../../etc/...).
      # Имя идёт в путь $PROFILES_DIR/<name>.json — инвариант «валидация до
      # любых файловых операций» соблюдается и в resume-ветке.
      if [[ -n "$saved_user" ]] && [[ "$saved_user" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        default_user="$saved_user"
      fi

      if [[ -f "$PROFILES_DIR/${default_user}.json" ]]; then
        echo -e "${YELLOW}ℹ User ${default_user} already exists — no need to create${NC}"
        user_name="$default_user"
      else
        echo -e "${CYAN}The user name is the profile name (7 routes, XHTTP+PQ).${NC}"
        local user_attempts=0
        while true; do
          ((user_attempts++))
          if [[ $user_attempts -gt 10 ]]; then
            echo -e "${RED}✗ Too many name attempts — wizard aborted${NC}"
            return 1
          fi
          echo -n -e "${YELLOW}First user name [${CYAN}${default_user}${YELLOW}]: ${NC}"
          read -r user_name || {
            echo ""
            echo -e "${RED}✗ No input (non-interactive run) — wizard aborted${NC}"
            return 1
          }
          [[ -z "$user_name" ]] && user_name="$default_user"

          if [[ ! "$user_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
            echo -e "${RED}✗ Invalid name: '${user_name}'${NC}"
            echo -e "${YELLOW}  Latin letters, digits, '-' and '_'; first character must be a letter or digit.${NC}"
            continue
          fi
          if [[ -f "$PROFILES_DIR/${user_name}.json" ]]; then
            echo -e "${RED}✗ User ${user_name} already exists${NC}"
            echo -e "${YELLOW}  Enter another name.${NC}"
            continue
          fi
          break
        done

        echo ""
        echo -e "${CYAN}  → Creating profile ${user_name}: 7 routes (XHTTP+PQ default)...${NC}"
        if ! create_profile_all_routes "$user_name" "no_pause" "hide_subscription"; then
          echo ""
          echo -e "${RED}✗ Profile ${user_name} was not created${NC}"
          echo -e "${YELLOW}  What to check:${NC}"
          echo -e "${YELLOW}    jq . ${CONFIG_FILE} >/dev/null  — is config.json valid${NC}"
          echo -e "${YELLOW}    systemctl status xray --no-pager -l${NC}"
          echo -e "${YELLOW}    ss -tlnH | grep LISTEN        — are the route ports taken${NC}"
          echo -e "${YELLOW}    Config backups: ${XRAY_BACKUPS_DIR}${NC}"
          _wizard_confirm_retry_or_exit || return 1
          continue
        fi
        echo -e "${GREEN}✓ Profile ${user_name} created (7 routes)${NC}"
      fi

      _wizard_state_set USER_NAME "$user_name"
      break
    done
  fi

  # ─────────── Шаг 4/5: Домен-режим и подписка ─────────────
  if [[ $resume_step -le 4 ]]; then
    while true; do
      _wizard_state_set STEP 4
      _wizard_step_banner 4

      local mode="" domain="" email=""
      local step4_ok=1
      local sub_rc=0
      mode=$(_wizard_state_get MODE || true)
      domain=$(_wizard_state_get DOMAIN || true)
      email=$(_wizard_state_get EMAIL || true)
      [[ -n "$mode" ]] || mode="ip"

      if [[ -z "$email" ]]; then
        echo -e "${RED}✗ No Let's Encrypt email found${NC}"
        echo -e "${YELLOW}  Go back to step 2 and provide an email.${NC}"
        _wizard_confirm_retry_or_exit || return 1
        continue
      fi

      if [[ "$mode" == "domain" ]]; then
        if [[ -z "$domain" ]]; then
          echo -e "${RED}✗ No domain found for self-steal${NC}"
          echo -e "${YELLOW}  Go back to step 2 and provide a domain.${NC}"
          step4_ok=0
        else
        # КРИТИЧНО: self-steal первым — он занимает :443 и забирает
        # localhost-backend порт, подписка затем выбирает следующий свободный.
        echo -e "${CYAN}  → Self-steal for ${domain}: :443 for your site + Reality...${NC}"
        if ! _selfsteal_provision "$domain" "$email"; then
          echo ""
          echo -e "${RED}✗ Self-steal did not deploy${NC}"
          echo -e "${YELLOW}  What to check:${NC}"
          echo -e "${YELLOW}    dig +short ${domain}   — must return $(get_server_ip)${NC}"
          echo -e "${YELLOW}    ss -tlnH 'sport = :443' — the port must be freed for Xray${NC}"
          echo -e "${YELLOW}    tail -30 /var/log/letsencrypt/letsencrypt.log${NC}"
          echo -e "${YELLOW}    nginx -t               — is the nginx config valid${NC}"
          step4_ok=0
        else
          echo -e "${GREEN}✓ Self-steal is ready: https://${domain}${NC}"
        fi
        fi
      fi

      if [[ $step4_ok -eq 1 ]]; then
        if _wizard_subscription_ready; then
          echo -e "${GREEN}✓ Subscription already installed on :$(cat "$WIZARD_SUB_PORT_FILE" 2>/dev/null) — skipping install${NC}"
        else
          echo ""
          # При self-steal подписку отдаём ТЕМ ЖЕ доменом на том же :443:
          # https://<domain>/sub/<token> — без отдельного порта и без нового
          # сертификата (LE уже выпущен self-steal). НЕ через отдельный
          # доменный vhost на :80 — тот дублировал бы server_name и ломал renew.
          local _prev_le_email="${SUBSCRIPTION_LE_EMAIL-}"
          local _had_le_email=0
          [[ -n "${SUBSCRIPTION_LE_EMAIL+x}" ]] && _had_le_email=1
          SUBSCRIPTION_LE_EMAIL="$email"
          if [[ "$mode" == "domain" ]]; then
            echo -e "${CYAN}  → Subscription HAPP: https://${domain}/sub/<token> (same domain, :443)${NC}"
            if install_subscription_selfsteal_domain "$domain"; then
              sub_rc=0
            else
              sub_rc=1
            fi
          else
            echo -e "${CYAN}  → Subscription HAPP: IP mode (HTTPS on the server IP).${NC}"
            if install_subscription_ip_tls; then
              sub_rc=0
            else
              sub_rc=1
            fi
          fi
          if [[ $_had_le_email -eq 1 ]]; then
            SUBSCRIPTION_LE_EMAIL="$_prev_le_email"
          else
            unset SUBSCRIPTION_LE_EMAIL
          fi

          if [[ $sub_rc -ne 0 ]]; then
            echo ""
            echo -e "${RED}✗ Subscription is not installed${NC}"
            echo -e "${YELLOW}  What to check:${NC}"
            echo -e "${YELLOW}    ss -tlnH 'sport = :80'   — port 80 is needed to issue the certificate${NC}"
            echo -e "${YELLOW}    ss -tlnp | grep nginx    — is the chosen subscription port taken${NC}"
            echo -e "${YELLOW}    tail -30 /tmp/certbot-ip.log${NC}"
            echo -e "${YELLOW}    systemctl status xraytailscale-sub --no-pager -l${NC}"
            step4_ok=0
          else
            echo -e "${GREEN}✓ Subscription installed${NC}"
          fi
        fi
      fi

      if [[ $step4_ok -eq 1 ]]; then
        break
      fi
      _wizard_confirm_retry_or_exit || return 1
    done
  fi

  # ─────────────── Шаг 5/5: Проверка и ссылка ──────────────
  if [[ $resume_step -le 5 ]]; then
    while true; do
      _wizard_state_set STEP 5
      _wizard_step_banner 5

      local user_name="" mode="" domain="" sub_port=""
      local token="" url="" curl_code="" xray_state=""
      local step5_ok=1
      user_name=$(_wizard_state_get USER_NAME || true)
      [[ -n "$user_name" ]] || user_name="$WIZARD_DEFAULT_USER"
      mode=$(_wizard_state_get MODE || true)
      [[ -n "$mode" ]] || mode="ip"
      domain=$(_wizard_state_get DOMAIN || true)
      sub_port=$(cat "$WIZARD_SUB_PORT_FILE" 2>/dev/null || true)

      xray_state=$(systemctl is-active xray 2>/dev/null || true)
      if [[ "$xray_state" == "active" ]]; then
        echo -e "${GREEN}✓ Xray: active${NC}"
      else
        echo -e "${RED}✗ Xray is not running (${xray_state:-unknown})${NC}"
        echo -e "${YELLOW}  Check: systemctl status xray --no-pager -l${NC}"
        echo -e "${YELLOW}  Restart: systemctl restart xray${NC}"
        step5_ok=0
      fi

      if [[ -n "$sub_port" ]] && command -v ss >/dev/null 2>&1 \
         && ss -tlnH "sport = :${sub_port}" 2>/dev/null | grep -q .; then
        echo -e "${GREEN}✓ Subscription port :${sub_port} is listening${NC}"
      else
        echo -e "${RED}✗ Subscription port ${sub_port:-unknown} is not listening${NC}"
        echo -e "${YELLOW}  Check: nginx -t && systemctl reload nginx${NC}"
        echo -e "${YELLOW}             systemctl status xraytailscale-sub --no-pager -l${NC}"
        echo -e "${YELLOW}             ss -tlnp | grep ${sub_port:-443}${NC}"
        step5_ok=0
      fi

      token=$(jq -r '.sub_token // ""' "$PROFILES_DIR/${user_name}.json" 2>/dev/null || true)
      if [[ "$token" =~ ^[a-f0-9]{32}$ ]]; then
        url="$(_subscription_base_url)/sub/${token}"
        curl_code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)
        [[ -z "$curl_code" ]] && curl_code="000"
        if [[ "$curl_code" =~ ^[23] ]]; then
          echo -e "${GREEN}✓ Subscription responds: HTTP ${curl_code}${NC}"
        else
          echo -e "${RED}✗ Subscription does not respond: HTTP ${curl_code}${NC}"
          echo -e "${YELLOW}  Check: curl -sk ${url}${NC}"
          echo -e "${YELLOW}             ufw status | grep ${sub_port:-443}${NC}"
          echo -e "${YELLOW}             journalctl -u xraytailscale-sub -n 50 --no-pager${NC}"
          step5_ok=0
        fi
      else
        echo -e "${RED}✗ Profile ${user_name} has no valid sub_token${NC}"
        echo -e "${YELLOW}  Recreate the profile or check ${PROFILES_DIR}/${user_name}.json${NC}"
        step5_ok=0
      fi

      if [[ $step5_ok -eq 1 ]]; then
        _wizard_final_report "$mode" "$domain" "$sub_port" "$url" "$user_name"
        break
      fi
      echo ""
      echo -e "${YELLOW}  Fix the issues above and re-run the check.${NC}"
      _wizard_confirm_retry_or_exit || return 1
    done
  fi

  return 0
}

# ─── CLI: `xraytailscale wizard` (принудительный перезапуск) ─
wizard_command() {
  if ! _wizard_has_root; then
    echo -e "${RED}✗ Root privileges are required${NC}"
    echo -e "${YELLOW}Use: sudo xraytailscale wizard${NC}"
    return 1
  fi
  run_first_run_wizard "force"
}
