# ═══════════════════════════════════════════════════════════
# Серверный домен: единое хранилище + автоподстановка
# ═══════════════════════════════════════════════════════════
# Домен вводится один раз (self-steal мастер или публичная подписка) и
# дальше подставляется автоматически:
#   - self-steal: SNI/serverNames, nginx server_name, LE-сертификат, vless URL;
#   - HAPP public TLS: дефолт в prompt домена.
# Файл: /usr/local/etc/xray/.server_domain (plain text, не секрет).

SERVER_DOMAIN_FILE="/usr/local/etc/xray/.server_domain"

# stdout: сохранённый домен или пусто. return 0 всегда.
get_server_domain() {
  cat "$SERVER_DOMAIN_FILE" 2>/dev/null || true
}

# Валидация: FQDN (не IP, без схемы/пути/порта), длина ≤253.
# TLD обязан содержать букву — отсекает IPv4 и чисто цифровые «домены».
validate_server_domain() {
  local domain="$1"
  [[ -n "$domain" && ${#domain} -le 253 ]] || return 1
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || return 1
  [[ "${domain##*.}" =~ [A-Za-z] ]] || return 1
  return 0
}

# Записать домен после валидации. return 1 при невалидном.
set_server_domain() {
  local domain="$1"
  validate_server_domain "$domain" || return 1
  printf '%s\n' "$domain" > "$SERVER_DOMAIN_FILE" || return 1
  chmod 644 "$SERVER_DOMAIN_FILE" 2>/dev/null || true
  return 0
}

# Интерактивный prompt с автоподстановкой сохранённого домена.
# Пустой ввод = принять сохранённый. Валидный ввод сохраняется обратно.
# Prompt/ошибки → stderr (функция вызывается через $(...) — stdout только результат).
# stdout: выбранный домен. return 1 если домен не задан/невалиден.
prompt_server_domain() {
  local saved domain
  saved=$(get_server_domain)
  if [[ -n "$saved" ]]; then
    echo -n -e "${YELLOW}Домен сервера [${CYAN}$saved${YELLOW}]: ${NC}" >&2
  else
    echo -n -e "${YELLOW}Домен сервера (A-запись → IP этого VPS): ${NC}" >&2
  fi
  read -r domain
  [[ -z "$domain" ]] && domain="$saved"
  if ! validate_server_domain "$domain"; then
    echo -e "${RED}✗ Некорректный домен: '${domain}'${NC}" >&2
    return 1
  fi
  set_server_domain "$domain" || return 1
  printf '%s\n' "$domain"
  return 0
}
