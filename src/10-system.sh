safe_jq_write() {
  local args=("$@")
  local nargs=${#args[@]}

  # Минимум 2 аргумента: выражение и файл
  if [[ $nargs -lt 2 ]]; then
    echo -e "${RED}  ✗ safe_jq_write: not enough arguments${NC}" >&2
    return 1
  fi

  # Последний аргумент — исходный файл (и он же целевой при in-place)
  local src_file="${args[$((nargs-1))]}"
  local dst_file="$src_file"
  local jq_args=("${args[@]:0:$((nargs-1))}")

  # Сохраняем исходные права и владельца
  local orig_mode orig_owner
  orig_mode=$(stat -c %a "$src_file" 2>/dev/null || echo "644")
  orig_owner=$(stat -c %U:%G "$src_file" 2>/dev/null || echo "root:root")

  local tmp=$(mktemp)
  if jq "${jq_args[@]}" "$src_file" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mv "$tmp" "$dst_file"
    chmod "$orig_mode" "$dst_file" 2>/dev/null
    chown "$orig_owner" "$dst_file" 2>/dev/null
    return 0
  else
    echo -e "${RED}  ✗ jq error — file NOT modified: $dst_file${NC}" >&2
    rm -f "$tmp"
    return 1
  fi
}

# Создание бэкапа config.json перед мутацией.
# Args: $1=operation_name, $2=optional caller variable receiving the exact path.
backup_config() {
  local operation_name=${1:-"manual"}
  local result_var=${2:-}
  local backup_dir="$XRAY_BACKUPS_DIR"
  local safe_operation_name

  if [[ -n "$result_var" && ! "$result_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo -e "${RED}  ✗ Invalid result variable name for backup_config${NC}"
    return 1
  fi
  [[ -n "$result_var" ]] && printf -v "$result_var" '%s' ""

  safe_operation_name=$(printf '%s' "$operation_name" | tr -c 'a-zA-Z0-9_.-' '_')
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir" 2>/dev/null
  chown xray:xray "$backup_dir" 2>/dev/null
  local backup_file="$backup_dir/config_$(date +%Y%m%d_%H%M%S)_$$_${RANDOM}_${safe_operation_name}.json"
  if ! cp "$CONFIG_FILE" "$backup_file"; then
    echo -e "${RED}  ✗ Could not create the config.json backup: $backup_file${NC}"
    return 1
  fi
  chmod 600 "$backup_file" 2>/dev/null
  chown xray:xray "$backup_file" 2>/dev/null
  [[ -n "$result_var" ]] && printf -v "$result_var" '%s' "$backup_file"
  echo -e "${CYAN}  -> Config backup: $(basename "$backup_file")${NC}"
  return 0
}

_restore_config_backup() {
  local backup_file=${1:-}

  if [[ -z "$backup_file" || ! -f "$backup_file" || ! -s "$backup_file" ]]; then
    echo -e "${RED}  ✗ The exact rollback backup is missing: ${backup_file:-not set}${NC}"
    return 1
  fi
  if ! cp "$backup_file" "$CONFIG_FILE"; then
    echo -e "${RED}  ✗ Could not restore config.json from $(basename "$backup_file")${NC}"
    return 1
  fi
  chmod 600 "$CONFIG_FILE" 2>/dev/null
  chown xray:xray "$CONFIG_FILE" 2>/dev/null
  echo -e "${GREEN}  ✓ Config restored from: $(basename "$backup_file")${NC}"
  return 0
}

_snapshot_profiles() {
  local result_var=${1:-}
  local snapshot_dir

  if [[ ! "$result_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo -e "${RED}  ✗ Invalid result variable name for _snapshot_profiles${NC}"
    return 1
  fi
  printf -v "$result_var" '%s' ""

  snapshot_dir=$(mktemp -d /tmp/xraytailscale-profiles.XXXXXX) || return 1
  if [[ -d "$PROFILES_DIR" ]] && ! cp -a "$PROFILES_DIR/." "$snapshot_dir/"; then
    rm -rf -- "$snapshot_dir"
    echo -e "${RED}  ✗ Could not snapshot the profile JSON${NC}"
    return 1
  fi
  printf -v "$result_var" '%s' "$snapshot_dir"
  return 0
}

_restore_profiles_snapshot() {
  local snapshot_dir=${1:-}

  if [[ "$snapshot_dir" != /tmp/xraytailscale-profiles.* || ! -d "$snapshot_dir" ]]; then
    echo -e "${RED}  ✗ Invalid profile JSON snapshot: ${snapshot_dir:-not set}${NC}"
    return 1
  fi
  mkdir -p "$PROFILES_DIR"
  if ! cp -a "$snapshot_dir/." "$PROFILES_DIR/"; then
    echo -e "${RED}  ✗ Could not restore the profile JSON${NC}"
    return 1
  fi
  echo -e "${GREEN}  ✓ Profile JSON restored${NC}"
  return 0
}

_discard_profiles_snapshot() {
  local snapshot_dir=${1:-}
  if [[ "$snapshot_dir" == /tmp/xraytailscale-profiles.* && -d "$snapshot_dir" ]]; then
    rm -rf -- "$snapshot_dir"
  fi
}

ensure_xray_runtime_user() {
  if getent passwd xray >/dev/null 2>&1; then
    return 0
  fi

  local nologin="/usr/sbin/nologin"
  [[ -x "$nologin" ]] || nologin="/sbin/nologin"
  [[ -x "$nologin" ]] || nologin="/bin/false"

  echo -e "${YELLOW}  ⚠ User xray is missing — creating the runtime user${NC}"
  if ! getent group xray >/dev/null 2>&1; then
    groupadd -r xray 2>/dev/null || true
  fi

  if getent group xray >/dev/null 2>&1; then
    useradd -r -g xray -s "$nologin" -M -d /nonexistent xray
  else
    useradd -r -s "$nologin" -M -d /nonexistent xray
  fi

  if ! getent passwd xray >/dev/null 2>&1; then
    echo -e "${RED}  ✗ Could not create user xray${NC}"
    return 1
  fi

  echo -e "${GREEN}  ✓ User xray created${NC}"
  return 0
}

# Восстановление прав файлов для пользователя xray
fix_xray_permissions() {
  ensure_xray_runtime_user >/dev/null 2>&1 || true
  chown -R xray:xray /usr/local/etc/xray/ 2>/dev/null || true
  chmod 600 /usr/local/etc/xray/.private_key 2>/dev/null || true
}

ensure_xray_service_unit() {
  if ! ensure_xray_runtime_user; then
    return 1
  fi

  if systemctl cat xray.service >/dev/null 2>&1; then
    return 0
  fi

  echo -e "${YELLOW}  ⚠ systemd unit xray.service not found — creating a base unit${NC}"
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
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true

  if systemctl cat xray.service >/dev/null 2>&1; then
    echo -e "${GREEN}  ✓ xray.service created${NC}"
    return 0
  fi

  echo -e "${RED}  ✗ Could not create xray.service${NC}"
  return 1
}

# Безопасный перезапуск Xray с валидацией конфига.
# Args: $1=exact rollback config backup path.
# Returns: 0=success, 1=failure (validation/restart failed; rollback attempted)
safe_restart_xray() {
  local rollback_config=${1:-}

  if [[ ! -x "$XRAY_BIN" ]]; then
    echo -e "${RED}  ✗ Binary $XRAY_BIN not found${NC}"
    return 1
  fi

  if [[ ! -f "$CONFIG_FILE" || ! -s "$CONFIG_FILE" ]]; then
    echo -e "${RED}  ✗ config.json is missing or empty — Xray NOT restarted${NC}"
    _restore_config_backup "$rollback_config" || true
    return 1
  fi

  local test_output
  test_output=$("$XRAY_BIN" run -test -format json -config "$CONFIG_FILE" 2>&1)

  if ! grep -qx "Configuration OK." <<< "$test_output"; then
    echo -e "${RED}  ✗ Config failed validation — Xray NOT restarted${NC}"
    echo -e "${YELLOW}  Error: ${test_output}${NC}"
    _restore_config_backup "$rollback_config" || true
    return 1
  fi

  if ! ensure_xray_service_unit; then
    return 1
  fi

  systemctl restart xray
  sleep 1

  if systemctl is-active --quiet xray; then
    echo -e "${GREEN}  ✓ Xray restarted${NC}"
    return 0
  else
    echo -e "${RED}  ✗ Xray did not start after the restart${NC}"
    if _restore_config_backup "$rollback_config"; then
      echo -e "${YELLOW}  -> Trying to restore the old config...${NC}"
      systemctl restart xray
      sleep 1
      if systemctl is-active --quiet xray; then
        echo -e "${GREEN}  ✓ Xray restored to the previous config${NC}"
      else
        echo -e "${RED}  ✗ The config rollback did not start Xray — manual check required${NC}"
      fi
    fi
    return 1
  fi
}

# Open port in UFW firewall (idempotent)
# Args: $1=port, $2=protocol (default: tcp)
# Returns: 0=success, 1=failure
open_firewall_port() {
  local port=$1
  local protocol=${2:-tcp}

  # Validate port number
  if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
    echo -e "${RED}  ✗ Invalid port: $port${NC}" >&2
    return 1
  fi

  # Check if UFW is installed and active
  if ! command -v ufw &>/dev/null; then
    echo -e "${YELLOW}  ⚠ UFW is not installed${NC}" >&2
    return 1
  fi

  if ! ufw status | grep -q "Status: active"; then
    echo -e "${YELLOW}  ⚠ UFW is not active — the rule was not applied${NC}" >&2
    return 1
  fi

  # Check if port already open (idempotent)
  if ufw status | grep -qE "^${port}/${protocol}.*ALLOW"; then
    echo -e "${CYAN}  → Port ${port}/${protocol} is already open${NC}"
    return 0
  fi

  # Open port
  echo -e "${CYAN}  → Opening port ${port}/${protocol}...${NC}"
  if ufw allow "${port}/${protocol}" >/dev/null 2>&1; then
    echo -e "${GREEN}  ✓ Port ${port}/${protocol} opened${NC}"
    ufw reload >/dev/null 2>&1
    return 0
  else
    echo -e "${RED}  ✗ Error opening the port${NC}" >&2
    return 1
  fi
}

# Close port in UFW if not used by other profiles
# Args: $1=port, $2=protocol (default: tcp)
close_firewall_port() {
  local port=$1
  local protocol=${2:-tcp}

  # Check if port is still used by any inbound
  local port_in_use=$(jq -r --argjson port "$port" \
    '.inbounds[] | select(.port == $port) | .tag' \
    "$CONFIG_FILE" 2>/dev/null)

  if [[ -n "$port_in_use" ]]; then
    return 0  # Still in use, don't close
  fi

  # Never close default ports
  local default_ports=(22 80 443 8443 2053 2083 2087 8080 2096 8880 9443)
  for dp in "${default_ports[@]}"; do
    [[ "$port" == "$dp" ]] && return 0
  done

  # Close port
  if ufw status | grep -qE "^${port}/${protocol}.*ALLOW"; then
    echo -e "${CYAN}  → Closing port ${port}/${protocol}...${NC}"
    ufw delete allow "${port}/${protocol}" >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
    echo -e "${GREEN}  ✓ Port closed${NC}"
  fi

  return 0
}

# Check whether a profile has route array
