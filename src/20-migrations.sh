_is_known_legacy_tcp_tuning_file() {
  local path="$1"
  [[ -f "$path" && ! -L "$path" ]] || return 1

  local content minimal_xts minimal_xeb
  content=$(<"$path") || return 1
  minimal_xts=$'# XrayTailscale minimal TCP tuning\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr'
  minimal_xeb=$'# Xrayebator minimal TCP tuning\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr'

  [[ "$content" == "$minimal_xts" || "$content" == "$minimal_xeb" ]]
}

_strip_legacy_tcp_tuning_block() {
  local source_file="$1"
  local target_file="$2"

  awk '
    function is_known_key(line) {
      return line ~ /^net\.(core\.(default_qdisc|rmem_max|wmem_max|rmem_default|wmem_default|netdev_max_backlog)|ipv4\.(tcp_congestion_control|tcp_fastopen|tcp_slow_start_after_idle|tcp_notsent_lowat|tcp_rmem|tcp_wmem|ip_local_port_range|tcp_max_tw_buckets|tcp_fin_timeout|tcp_keepalive_time|tcp_keepalive_intvl|tcp_keepalive_probes|tcp_mtu_probing|tcp_syncookies|tcp_max_syn_backlog))=/
    }
    $0 == "# BBR TCP Congestion Control Optimization" {
      if (inside || found) {
        bad = 1
      }
      inside = 1
      found = 1
      next
    }
    inside && is_known_key($0) { next }
    inside && $0 ~ /^[[:space:]]*$/ {
      inside = 0
      next
    }
    inside {
      bad = 1
      inside = 0
    }
    { print }
    END {
      if (bad) {
        exit 2
      }
      if (!found) {
        exit 1
      }
    }
  ' "$source_file" > "$target_file"
}

_find_persistent_bbr_sources() {
  local scan_paths="${1:-$SYSCTL_SCAN_PATHS}"
  local -a paths
  local path candidate
  IFS=':' read -r -a paths <<< "$scan_paths"

  for path in "${paths[@]}"; do
    if [[ -f "$path" && ! -L "$path" ]]; then
      if grep -Eq '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr([[:space:]]*(#.*)?)?$' "$path"; then
        printf '%s\n' "$path"
      fi
      continue
    fi
    [[ -d "$path" && ! -L "$path" ]] || continue
    for candidate in "$path"/*.conf; do
      [[ -f "$candidate" && ! -L "$candidate" ]] || continue
      if grep -Eq '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr([[:space:]]*(#.*)?)?$' "$candidate"; then
        printf '%s\n' "$candidate"
      fi
    done
  done
}

migrate_remove_legacy_tcp_tuning_v3() {
  local marker="${1:-$HOST_TUNING_MIGRATION_MARKER}"
  local legacy_file="${2:-$LEGACY_TCP_TUNING_FILE}"
  local sysctl_conf="${3:-$SYSTEM_SYSCTL_CONF}"
  local active_file="${4:-$TCP_CC_ACTIVE_FILE}"
  local available_file="${5:-$TCP_CC_AVAILABLE_FILE}"
  local scan_paths="${6:-$SYSCTL_SCAN_PATHS}"
  local expected_uid="${7:-0}"

  if [[ -L "$marker" ]]; then
    echo -e "${RED}  ✗ Migration marker must not be a symlink: $marker${NC}"
    return 1
  fi
  [[ -f "$marker" ]] && return 0
  if [[ -e "$marker" ]]; then
    echo -e "${RED}  ✗ Migration marker has an unexpected type: $marker${NC}"
    return 1
  fi

  echo -e "${MAGENTA}[migration] Removing legacy BBR/TCP tuning${NC}"

  local backup_dir=""
  local candidate=""
  local current_cc=""
  local available_cc=""
  local target_cc=""
  local remaining_sources=""
  local strip_rc=0
  local unsafe_config=0
  local legacy_candidate

  for legacy_candidate in "$legacy_file" "$LEGACY_XRAYEBATOR_TCP_TUNING_FILE"; do
    [[ -n "$legacy_candidate" ]] || continue
    if [[ -e "$legacy_candidate" || -L "$legacy_candidate" ]]; then
      if [[ -L "$legacy_candidate" || ! -f "$legacy_candidate" ]] \
         || [[ "$(stat -c %u "$legacy_candidate" 2>/dev/null)" != "$expected_uid" ]] \
         || ! _is_known_legacy_tcp_tuning_file "$legacy_candidate"; then
        echo -e "${RED}  ✗ Unknown or modified file left unchanged: $legacy_candidate${NC}"
        unsafe_config=1
      else
        mkdir -p "$XRAY_BACKUPS_DIR" || return 1
        if [[ -z "$backup_dir" ]]; then
          backup_dir=$(mktemp -d "$XRAY_BACKUPS_DIR/host-tuning-v3.XXXXXX") || return 1
          chmod 0700 "$backup_dir"
        fi
        cp -a -- "$legacy_candidate" "$backup_dir/$(basename "$legacy_candidate")" || return 1
        rm -f -- "$legacy_candidate" || return 1
        echo -e "${GREEN}  ✓ Removed legacy sysctl.d file: $legacy_candidate${NC}"
      fi
    fi
  done

  if [[ -e "$sysctl_conf" || -L "$sysctl_conf" ]]; then
    if [[ -L "$sysctl_conf" || ! -f "$sysctl_conf" ]] \
       || [[ "$(stat -c %u "$sysctl_conf" 2>/dev/null)" != "$expected_uid" ]]; then
      echo -e "${RED}  ✗ Unsafe system config left unchanged: $sysctl_conf${NC}"
      unsafe_config=1
    else
      candidate=$(mktemp "$(dirname "$sysctl_conf")/.xraytailscale-sysctl.XXXXXX") || return 1
      _strip_legacy_tcp_tuning_block "$sysctl_conf" "$candidate" || strip_rc=$?
      if [[ "$strip_rc" -eq 0 ]]; then
        if [[ -z "$backup_dir" ]]; then
          mkdir -p "$XRAY_BACKUPS_DIR" || { rm -f -- "$candidate"; return 1; }
          backup_dir=$(mktemp -d "$XRAY_BACKUPS_DIR/host-tuning-v3.XXXXXX") || {
            rm -f -- "$candidate"
            return 1
          }
          chmod 0700 "$backup_dir"
        fi
        cp -a -- "$sysctl_conf" "$backup_dir/sysctl.conf" || {
          rm -f -- "$candidate"
          return 1
        }
        mv -f -- "$candidate" "$sysctl_conf" || {
          rm -f -- "$candidate"
          return 1
        }
        echo -e "${GREEN}  ✓ Removed the XrayTailscale legacy block from sysctl.conf${NC}"
      elif [[ "$strip_rc" -eq 1 ]]; then
        rm -f -- "$candidate"
      else
        rm -f -- "$candidate"
        unsafe_config=1
        echo -e "${RED}  ✗ Legacy sysctl block was edited manually; file left unchanged${NC}"
      fi
    fi
  fi

  if [[ ! -r "$active_file" || ! -r "$available_file" ]]; then
    echo -e "${RED}  ✗ The kernel does not expose congestion-control state${NC}"
    return 1
  fi
  current_cc=$(<"$active_file")
  available_cc=$(<"$available_file")

  if [[ "$current_cc" == "bbr" ]]; then
    if [[ " $available_cc " == *" cubic "* ]]; then
      target_cc="cubic"
    elif [[ " $available_cc " == *" reno "* ]]; then
      target_cc="reno"
    else
      echo -e "${RED}  ✗ No safe congestion-control fallback found (cubic/reno)${NC}"
      return 1
    fi

    if ! sysctl -q -w "net.ipv4.tcp_congestion_control=$target_cc"; then
      echo -e "${RED}  ✗ Could not switch congestion control to $target_cc${NC}"
      [[ -n "$backup_dir" ]] && echo -e "${YELLOW}    Persistent settings removed; backup: $backup_dir${NC}"
      return 1
    fi
    current_cc=$(<"$active_file")
    if [[ "$current_cc" == "bbr" ]]; then
      echo -e "${RED}  ✗ Congestion control is still BBR after the switch${NC}"
      return 1
    fi
    echo -e "${GREEN}  ✓ Active congestion control: $current_cc${NC}"
  fi

  remaining_sources=$(_find_persistent_bbr_sources "$scan_paths")
  if [[ -n "$remaining_sources" ]]; then
    echo -e "${RED}  ✗ BBR is set by a third-party sysctl config; file unchanged:${NC}"
    printf '%s\n' "$remaining_sources" | sed 's/^/    /'
    echo -e "${YELLOW}    Remove the setting manually; the migration will retry on the next run.${NC}"
    return 1
  fi

  if [[ "$unsafe_config" -ne 0 ]]; then
    echo -e "${YELLOW}  ⚠ Some persistent configs need manual review; marker not set.${NC}"
    return 1
  fi

  mkdir -p "$(dirname "$marker")" || return 1
  if ! touch "$marker"; then
    echo -e "${RED}  ✗ Could not write the migration marker: $marker${NC}"
    return 1
  fi
  chown xray:xray "$marker" 2>/dev/null || true
  chmod 0640 "$marker" 2>/dev/null || true
  echo -e "${GREEN}  ✓ Legacy BBR/TCP tuning fully disabled${NC}"
  return 0
}

migrate_legacy_managed_udp443_block_v3() {
  local count
  count=$(jq '[.routing.rules[]? | select(. == {"type":"field","network":"udp","port":443,"outboundTag":"block"})] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
  if [[ ! "$count" =~ ^[0-9]+$ || "$count" -eq 0 ]]; then
    echo -e "${GREEN}✓ Legacy bare UDP/443 block is absent${NC}"
    return 1
  fi

  if safe_jq_write '
    .routing.rules = [
      .routing.rules[]?
      | select(. != {"type":"field","network":"udp","port":443,"outboundTag":"block"})
    ]
  ' "$CONFIG_FILE"; then
    echo -e "${GREEN}✓ Legacy bare UDP/443 block removed${NC}"
    return 0
  fi

  echo -e "${RED}✗ Could not remove the legacy bare UDP/443 block${NC}"
  return 2
}

# run_migration <marker_basename> <description> <fn_name>
# Centralized migration runner: backup → run fn → safe_restart → touch marker.
# Marker is created ONLY if all phases succeed (idempotency guarantee).
#
# Three-valued return contract for migration fns:
#   fn returns 0 = config changed → safe_restart_xray + touch marker
#   fn returns 1 = no-op (nothing to migrate) → touch marker WITHOUT restart
#   fn returns ≥2 = FAILED → do NOT touch marker (миграция повторится)
#
# Why three-valued: 5 of 6 existing fns return `return 1` для no-op case (нечего
# мигрировать на v2.0+ установке). Binary contract (0=ok, ≥1=fail) приводил бы к
# 5 RED false-positive ошибкам на каждом launch'е v2.0 системы и маркеры никогда
# не выставлялись бы — миграции бесконечно перепроверялись.
#
# Args:
#   marker_basename — file inside /usr/local/etc/xray/, WITHOUT leading dot
#                     (e.g. "xhttp_migrated" → marker /usr/local/etc/xray/.xhttp_migrated)
#   description     — human-readable for logging (Russian, для пользователя)
#   fn_name         — bash function to call. Function MUST:
#                       - return 0 если config changed (рестарт нужен)
#                       - return 1 если no-op (нечего мигрировать, рестарт не нужен)
#                       - return ≥2 если миграция ФАЛЛЕНУЛА (НЕ touch marker)
#                     Function MUST NOT call backup_config or safe_restart_xray itself
#                     (helper делает это централизованно).
#
# Returns: 0=ok (marker set), 1=fn failed (≥2), 2=restart failed
run_migration() {
  local marker_basename="$1"
  local description="$2"
  local fn_name="$3"

  local marker="/usr/local/etc/xray/.${marker_basename}"

  # Skip if already done (idempotent)
  if [[ -f "$marker" ]]; then
    return 0
  fi

  echo -e "${MAGENTA}[migration] ${description}${NC}"

  # Step 1: backup BEFORE any mutation and keep this exact path for rollback.
  local rollback_config=""
  if ! backup_config "$marker_basename" rollback_config; then
    echo -e "${RED}  ✗ Migration aborted: could not create a backup${NC}"
    return 1
  fi

  # Step 2: run user-supplied migration fn
  "$fn_name"
  local fn_rc=$?

  case $fn_rc in
    0)
      # Changed config — needs restart
      if safe_restart_xray "$rollback_config"; then
        touch "$marker"
        chown xray:xray "$marker" 2>/dev/null || true
        echo -e "${GREEN}  ✓ Migration applied: ${marker_basename}${NC}"
        return 0
      else
        echo -e "${RED}  ✗ safe_restart_xray failed for ${description}${NC}"
        echo -e "${YELLOW}    Marker NOT set — config rolled back (auto-rollback), migration will retry${NC}"
        return 2
      fi
      ;;
    1)
      # No change — skip restart, but still mark as done (idempotent no-op for next runs).
      # Без этого touch'а fn re-проверял бы (зря) каждый launch.
      touch "$marker"
      chown xray:xray "$marker" 2>/dev/null || true
      echo -e "${CYAN}  ✓ Nothing to migrate: ${marker_basename}${NC}"
      return 0
      ;;
    *)
      # fn вернула ≥2 — реальная ошибка (НЕ no-op).
      echo -e "${RED}  ✗ Migration fn '$fn_name' returned $fn_rc${NC}"
      echo -e "${YELLOW}    Marker NOT set — migration will retry on the next run${NC}"
      return 1
      ;;
  esac
}

# Remove the legacy server-side fingerprint field. Xray ignores this field for
# REALITY inbounds: the effective fingerprint lives only in profile/client URLs.
# Returns: 0=changed, 1=no-op, 2=write failure.
_remove_ignored_reality_server_fingerprints() {
  local config_file="${1:-$CONFIG_FILE}"
  [[ -f "$config_file" ]] || return 1

  if ! jq -e '
    any(.inbounds[]?; ((.streamSettings.realitySettings? // {}) | has("fingerprint")))
  ' "$config_file" >/dev/null 2>&1; then
    return 1
  fi

  if ! safe_jq_write '
    (.inbounds[]?
      | select((.streamSettings.realitySettings? // {}) | has("fingerprint"))
      | .streamSettings.realitySettings) |= del(.fingerprint)
  ' "$config_file"; then
    return 2
  fi

  return 0
}

# State-only migration: cleaning an ignored server field does not require an
# Xray restart and existing profile fingerprints are intentionally preserved.
migrate_client_fingerprint_state_2026() {
  local marker="${1:-/usr/local/etc/xray/.client_fingerprint_state_2026}"
  [[ -f "$marker" ]] && return 0

  local rollback_config=""
  backup_config "client_fingerprint_state_2026" rollback_config || return 1

  local clean_rc=0
  _remove_ignored_reality_server_fingerprints "$CONFIG_FILE" || clean_rc=$?
  if [[ "$clean_rc" -ge 2 ]]; then
    _restore_config_backup "$rollback_config" || true
    echo -e "${RED}  ✗ Could not remove the obsolete server-side fingerprint${NC}"
    return 1
  fi

  if ! touch "$marker"; then
    _restore_config_backup "$rollback_config" || true
    echo -e "${RED}  ✗ Could not write the migration marker: $marker${NC}"
    return 1
  fi
  chown xray:xray "$marker" 2>/dev/null || true

  if [[ "$clean_rc" -eq 0 ]]; then
    fix_xray_permissions
    echo -e "${GREEN}  ✓ Fingerprint switched to client-only mode (profiles preserved)${NC}"
  fi
  return 0
}

migrate_transport_profile_metadata() {
  local migrated=0
  local profile_file

  echo -e "${CYAN}Checking profile transport metadata...${NC}"
  # backup_config удалён: централизован в run_migration (Phase 4 refactor, REQ-D07)

  for profile_file in "$PROFILES_DIR"/*.json; do
    [[ ! -f "$profile_file" ]] && continue

    local transport
    transport=$(jq -r '.transport // ""' "$profile_file" 2>/dev/null)

    case "$transport" in
      grpc)
        if [[ "$(jq -r 'has("grpc_service_name")' "$profile_file" 2>/dev/null)" != "true" ]]; then
          echo -e "${YELLOW}  → Backfill grpc_service_name: $(basename "$profile_file" .json)${NC}"
          if safe_jq_write '.grpc_service_name = "grpc"' "$profile_file"; then
            ((migrated++))
          fi
        fi
        ;;
      xhttp)
        if [[ "$(jq -r 'has("xhttp_path")' "$profile_file" 2>/dev/null)" != "true" ]]; then
          echo -e "${YELLOW}  → Backfill xhttp_path: $(basename "$profile_file" .json)${NC}"
          if safe_jq_write '.xhttp_path = "/xhttp"' "$profile_file"; then
            ((migrated++))
          fi
        fi
        ;;
    esac
  done

  fix_xray_permissions

  # EXPLICIT return: 0=changed (restart нужен), 1=no-op (нечего мигрировать)
  # Раньше всегда return 0 — принудительный restart даже когда migrated==0
  if [[ $migrated -gt 0 ]]; then
    echo -e "${GREEN}✓ Transport metadata backfill: $migrated profiles${NC}"
    return 0
  else
    echo -e "${GREEN}✓ Transport metadata backfill not needed${NC}"
    return 1
  fi
}

# Migration function for existing XHTTP profiles
migrate_xhttp_profiles() {
  local migrated=0

  echo -e "${CYAN}Checking XHTTP profiles for migration...${NC}"
  # backup_config удалён: централизован в run_migration (Phase 4 refactor, REQ-D07)

  for profile_file in "$PROFILES_DIR"/*.json; do
    [[ ! -f "$profile_file" ]] && continue

    local transport=$(jq -r '.transport' "$profile_file")
    [[ "$transport" != "xhttp" ]] && continue

    local port=$(jq -r '.port' "$profile_file")

    local has_host=$(jq -r --argjson port "$port" \
      '.inbounds[] | select(.port == $port) | .streamSettings.xhttpSettings | has("host")' \
      "$CONFIG_FILE" 2>/dev/null)

    if [[ "$has_host" == "true" ]]; then
      echo -e "${YELLOW}  → Removing XHTTP Host check: $(basename "$profile_file" .json)${NC}"

      if safe_jq_write --argjson port "$port" '
        (.inbounds[] | select(.port == $port) | .streamSettings.xhttpSettings) |= del(.host)
      ' "$CONFIG_FILE"; then
        ((migrated++))
      fi
    fi
  done

  # safe_restart_xray удалён: вызывается run_migration после fn (Phase 4 refactor)
  # EXPLICIT return: 0=changed (restart нужен), 1=no-op (нечего мигрировать)
  if [[ $migrated -gt 0 ]]; then
    echo -e "${GREEN}✓ Removed XHTTP Host check from $migrated profiles${NC}"
    return 0   # changed → run_migration вызовет safe_restart_xray
  else
    echo -e "${GREEN}✓ XHTTP profile migration not needed${NC}"
    return 1   # no-op → run_migration touch-ит marker без restart
  fi
}

_migrate_xhttp_drop_host_2026() {
  local count
  count=$(jq '[.inbounds[]? | select(.streamSettings.network == "xhttp" and (.streamSettings.xhttpSettings | has("host")))] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
  if [[ ! "$count" =~ ^[0-9]+$ || "$count" -eq 0 ]]; then
    echo -e "${GREEN}✓ XHTTP Host check already absent${NC}"
    return 1
  fi

  echo -e "${YELLOW}  → Removing xhttpSettings.host from ${count} XHTTP inbound(s)${NC}"
  if safe_jq_write '
    .inbounds |= map(
      if .streamSettings.network == "xhttp" and (.streamSettings.xhttpSettings | type == "object") then
        .streamSettings.xhttpSettings |= del(.host)
      else
        .
      end
    )
  ' "$CONFIG_FILE"; then
    echo -e "${GREEN}✓ XHTTP Host check removed${NC}"
    return 0
  fi

  echo -e "${RED}✗ Could not remove the XHTTP Host check${NC}"
  return 2
}

_migrate_xhttp_path_sync_2026() {
  local migrated=0 failed=0 profile_file

  echo -e "${CYAN}Checking XHTTP path between profiles and config.json...${NC}"

  for profile_file in "$PROFILES_DIR"/*.json; do
    [[ -f "$profile_file" ]] || continue

    local port path current_path
    while IFS=$'\t' read -r port path; do
      [[ "$port" =~ ^[0-9]+$ ]] || continue
      [[ "$path" == /* ]] || continue

      current_path=$(jq -r --argjson port "$port" '
        .inbounds[]?
        | select(.port == $port and .streamSettings.network == "xhttp")
        | .streamSettings.xhttpSettings.path // ""
      ' "$CONFIG_FILE" 2>/dev/null | head -1)

      if [[ -z "$current_path" || "$current_path" == "null" ]]; then
        echo -e "${YELLOW}  → Restoring XHTTP path on port $port: $path${NC}"
        if safe_jq_write --argjson port "$port" --arg path "$path" '
          (.inbounds[]? | select(.port == $port and .streamSettings.network == "xhttp") | .streamSettings.xhttpSettings.path) = $path
        ' "$CONFIG_FILE"; then
          ((migrated++))
        else
          ((failed++))
        fi
      fi
    done < <(jq -r '
      if ((.routes // []) | length) > 0 then
        (.routes // [])[]
        | select(.transport == "xhttp" and (.port? | type == "number") and ((.xhttp_path // "") | length > 0))
        | [.port, .xhttp_path]
        | @tsv
      elif .transport == "xhttp" and (.port? | type == "number") and ((.xhttp_path // "") | length > 0) then
        [.port, .xhttp_path]
        | @tsv
      else
        empty
      end
    ' "$profile_file" 2>/dev/null)
  done

  if [[ $failed -gt 0 ]]; then
    echo -e "${RED}✗ XHTTP path sync: $failed errors, $migrated fixed${NC}"
    return 2
  fi
  if [[ $migrated -gt 0 ]]; then
    echo -e "${GREEN}✓ XHTTP path sync: fixed $migrated inbound(s)${NC}"
    return 0
  fi

  echo -e "${GREEN}✓ XHTTP path sync not needed${NC}"
  return 1
}

_migrate_xhttp_route_path_repair_2026() {
  _migrate_xhttp_path_sync_2026
}

_migrate_xhttp_reality_stream_one_2026() {
  local affected
  affected=$(jq -r '
    .inbounds[]?
    | select(.streamSettings.network == "xhttp" and .streamSettings.security == "reality")
    | select((.streamSettings.xhttpSettings.mode // "") != "stream-one")
    | .port
  ' "$CONFIG_FILE" 2>/dev/null)

  if [[ -z "$affected" ]]; then
    echo -e "${GREEN}✓ XHTTP Reality already uses stream-one${NC}"
    return 1
  fi

  echo -e "${YELLOW}  → Switching XHTTP Reality mode to stream-one: ${affected//$'\n'/, }${NC}"
  if safe_jq_write '
    (.inbounds[]? | select(.streamSettings.network == "xhttp" and .streamSettings.security == "reality") | .streamSettings.xhttpSettings.mode) = "stream-one"
  ' "$CONFIG_FILE"; then
    echo -e "${GREEN}✓ XHTTP Reality mode=stream-one applied${NC}"
    return 0
  fi

  echo -e "${RED}✗ Could not switch XHTTP Reality to stream-one${NC}"
  return 2
}

# Migration function for routing configuration (v2.0)
# Adds default "direct" rule if missing
migrate_routing_config() {
  echo -e "${CYAN}Checking the routing configuration...${NC}"
  # backup_config удалён: централизован в run_migration (Phase 4 refactor, REQ-D07)

  # Check if default direct rule exists
  local has_direct_rule=$(jq -r '
    .routing.rules[] | select(.outboundTag == "direct" and .network == "tcp,udp") | .outboundTag
  ' "$CONFIG_FILE" 2>/dev/null)

  if [[ -z "$has_direct_rule" ]]; then
    echo -e "${YELLOW}  → Adding the default direct rule...${NC}"

    if safe_jq_write '.routing.rules += [{
      "type": "field",
      "network": "tcp,udp",
      "outboundTag": "direct"
    }]' "$CONFIG_FILE"; then
      echo -e "${GREEN}  ✓ Routing fixed${NC}"
      return 0  # Needs restart
    else
      echo -e "${RED}  ✗ Routing migration error${NC}"
      return 1
    fi
  else
    echo -e "${GREEN}✓ Routing is fine${NC}"
    return 1  # No restart needed
  fi
}

# Migration function for XHTTP mode (stream -> auto)
# Fixes sing-box compatibility issues
# NOTE: extra settings preserved — they are critical for DPI bypass
migrate_xhttp_mode() {
  echo -e "${CYAN}Checking XHTTP mode for migration...${NC}"
  # backup_config удалён: централизован в run_migration (Phase 4 refactor, REQ-D07)

  local migrated=0

  # Check all inbounds with xhttp transport
  local xhttp_ports=$(jq -r '.inbounds[] | select(.streamSettings.network == "xhttp") | .port' "$CONFIG_FILE" 2>/dev/null)

  for port in $xhttp_ports; do
    [[ -z "$port" ]] && continue

    local current_mode=$(jq -r --argjson port "$port" \
      '.inbounds[] | select(.port == $port) | .streamSettings.xhttpSettings.mode' \
      "$CONFIG_FILE" 2>/dev/null)

    if [[ "$current_mode" == "stream" ]]; then
      echo -e "${YELLOW}  → Migrating XHTTP mode on port $port: stream → auto${NC}"

      if safe_jq_write --argjson port "$port" '
        (.inbounds[] | select(.port == $port) | .streamSettings.xhttpSettings.mode) = "auto"
      ' "$CONFIG_FILE"; then
        ((migrated++))
      fi
    fi
  done

  if [[ $migrated -gt 0 ]]; then
    echo -e "${GREEN}✓ Migrated $migrated XHTTP inbound(s)${NC}"
    return 0  # Needs restart
  else
    echo -e "${GREEN}✓ XHTTP mode migration not needed${NC}"
    return 1  # No restart needed
  fi
}

# Migration: restore XHTTP extra settings wiped by previous migrate_xhttp_mode bug
# Without extra (padding, xmux, post limits) XHTTP is easily detected by DPI
migrate_xhttp_extra_restore() {
  echo -e "${CYAN}Checking XHTTP extra for restoration...${NC}"
  # backup_config удалён: централизован в run_migration (Phase 4 refactor, REQ-D07)

  local restored=0

  local xhttp_ports=$(jq -r '.inbounds[] | select(.streamSettings.network == "xhttp") | .port' "$CONFIG_FILE" 2>/dev/null)

  for port in $xhttp_ports; do
    [[ -z "$port" ]] && continue

    # Check if extra is missing, null, or empty object
    local extra_keys=$(jq -r --argjson port "$port" \
      '.inbounds[] | select(.port == $port) | .streamSettings.xhttpSettings.extra // {} | keys | length' \
      "$CONFIG_FILE" 2>/dev/null)

    if [[ "$extra_keys" == "0" ]] || [[ -z "$extra_keys" ]]; then
      echo -e "${YELLOW}  → Restoring XHTTP extra on port $port${NC}"

      if safe_jq_write --argjson port "$port" '
        (.inbounds[] | select(.port == $port) | .streamSettings.xhttpSettings.extra) = {
          "xPaddingBytes": "100-1000",
          "xmux": {
            "maxConcurrency": "16-32",
            "cMaxLifetimeMs": "10000-30000"
          },
          "noSSEHeader": true,
          "scMaxEachPostBytes": "1000000-2000000",
          "scMinPostsIntervalMs": "10-50"
        }
      ' "$CONFIG_FILE"; then
        ((restored++))
      fi
    fi
  done

  if [[ $restored -gt 0 ]]; then
    echo -e "${GREEN}✓ Restored extra for $restored XHTTP inbound(s)${NC}"
    return 0  # Needs restart
  else
    echo -e "${GREEN}✓ XHTTP extra is fine${NC}"
    return 1  # No restart needed
  fi
}

# Migration: config optimization (Phase 2)
# Applies DNS DoH Local, freedom UseIPv4, sniffing routeOnly,
# access log none, policy bufferSize, and BitTorrent blocking
migrate_config_optimization() {
  echo -e "${CYAN}Optimizing the configuration...${NC}"
  # backup_config удалён: централизован в run_migration (Phase 4 refactor, REQ-D07)

  local changed=false

  local current_dns=$(jq -r '.dns.servers[0] // ""' "$CONFIG_FILE" 2>/dev/null)
  if [[ "$current_dns" == "127.0.0.1" ]]; then
    echo -e "${GREEN}  ✓ DNS -> 127.0.0.1 (AdGuard Home) preserved${NC}"
  elif [[ "$current_dns" == "https+local://1.1.1.1/dns-query" ]]; then
    echo -e "${GREEN}  ✓ DNS already optimized${NC}"
  else
    echo -e "${YELLOW}  → DNS: migrating to Local DoH${NC}"
    if safe_jq_write '.dns = {
      "servers": [
        "https+local://1.1.1.1/dns-query",
        "localhost"
      ],
      "queryStrategy": "UseIPv4",
      "disableCache": false
    }' "$CONFIG_FILE"; then
      echo -e "${GREEN}  ✓ DNS switched to Local DoH${NC}"
      changed=true
    else
      echo -e "${RED}  ✗ DNS migration error${NC}"
    fi
  fi

  local freedom_strategy=$(jq -r '.outbounds[] | select(.protocol == "freedom") | .settings.domainStrategy // "none"' "$CONFIG_FILE" 2>/dev/null)
  if [[ "$freedom_strategy" == "UseIPv4" ]]; then
    echo -e "${GREEN}  ✓ Freedom already uses UseIPv4${NC}"
  else
    echo -e "${YELLOW}  → Freedom: adding UseIPv4${NC}"
    if safe_jq_write '
      (.outbounds[] | select(.protocol == "freedom")).settings.domainStrategy = "UseIPv4"
    ' "$CONFIG_FILE"; then
      echo -e "${GREEN}  ✓ Freedom switched to UseIPv4${NC}"
      changed=true
    else
      echo -e "${RED}  ✗ Error updating the Freedom outbound${NC}"
    fi
  fi

  local route_only_missing=$(jq '[.inbounds[] | select(.sniffing.routeOnly != true)] | length' "$CONFIG_FILE" 2>/dev/null)
  if [[ "$route_only_missing" -gt 0 ]]; then
    echo -e "${YELLOW}  → Sniffing: enabling routeOnly for $route_only_missing inbound(s)${NC}"
    if safe_jq_write '
      .inbounds[] |= (if .sniffing then .sniffing.routeOnly = true else . end)
    ' "$CONFIG_FILE"; then
      echo -e "${GREEN}  ✓ Sniffing routeOnly enabled${NC}"
      changed=true
    else
      echo -e "${RED}  ✗ Error enabling sniffing routeOnly${NC}"
    fi
  else
    echo -e "${GREEN}  ✓ Sniffing routeOnly already enabled${NC}"
  fi

  local access_log=$(jq -r '.log.access // "not_set"' "$CONFIG_FILE" 2>/dev/null)
  if [[ "$access_log" == "none" ]]; then
    echo -e "${GREEN}  ✓ Access log already disabled${NC}"
  else
    echo -e "${YELLOW}  → Logging: disabling access log${NC}"
    if safe_jq_write '.log.access = "none"' "$CONFIG_FILE"; then
      echo -e "${GREEN}  ✓ Access log disabled${NC}"
      changed=true
    else
      echo -e "${RED}  ✗ Error disabling the access log${NC}"
    fi
  fi

  local policy_section=$(jq '.policy // empty' "$CONFIG_FILE" 2>/dev/null)
  if [[ -n "$policy_section" ]]; then
    echo -e "${GREEN}  ✓ Policy already configured${NC}"
  else
    echo -e "${YELLOW}  → Policy: adding bufferSize=4${NC}"
    if safe_jq_write '.policy = {
      "levels": {
        "0": {
          "handshake": 4,
          "connIdle": 300,
          "uplinkOnly": 2,
          "downlinkOnly": 5,
          "bufferSize": 4
        }
      }
    }' "$CONFIG_FILE"; then
      echo -e "${GREEN}  ✓ Policy added (bufferSize=4)${NC}"
      changed=true
    else
      echo -e "${RED}  ✗ Error adding policy${NC}"
    fi
  fi

  local bittorrent_rule_count=$(jq -r '[.routing.rules[] | select(.protocol != null) | .protocol[] | select(. == "bittorrent")] | length' "$CONFIG_FILE" 2>/dev/null)
  if [[ -n "$bittorrent_rule_count" ]] && [[ "$bittorrent_rule_count" != "0" ]]; then
    echo -e "${GREEN}  ✓ BitTorrent blocking already configured${NC}"
  else
    echo -e "${YELLOW}  → Routing: blocking BitTorrent${NC}"
    if safe_jq_write '
      .routing.rules |= (.[:-1] + [{"type":"field","protocol":["bittorrent"],"outboundTag":"block"}] + .[-1:])
    ' "$CONFIG_FILE"; then
      echo -e "${GREEN}  ✓ BitTorrent blocked${NC}"
      changed=true
    else
      echo -e "${RED}  ✗ Error adding the BitTorrent rule${NC}"
    fi
  fi

  fix_xray_permissions

  if [[ "$changed" == "true" ]]; then
    return 0
  fi

  return 1
}

# Migration: explicit xmux block для всех XHTTP inbounds (Phase 5, REQ-B04)
# Marker: /usr/local/etc/xray/.xmux_explicit_2026
# Даёт throughput-friendly XMUX: maxConcurrency=16-32 + hMax* полей.
# Skip-rule (CONTEXT.md decision 5): inbound с already-existing xmux пропускается
# (preserves пользовательские твики, в т.ч. Phase 4 значения 16-32).
# Three-valued return contract:
#   0 — изменения внесены, restart нужен
#   1 — no-op, все XHTTP inbound'ы уже корректны (или их нет)
#   ≥2 — fail (safe_jq_write провалился где-то)
migrate_xmux_explicit_2026() {
  echo -e "${CYAN}Checking XHTTP inbounds for explicit xmux...${NC}"
  # backup_config удален: централизован в run_migration (Phase 4 REQ-D07)

  local migrated=0 skipped=0 failed=0

  # Все XHTTP inbound'ы (по network в streamSettings)
  local xhttp_ports
  xhttp_ports=$(jq -r '.inbounds[] | select(.streamSettings.network == "xhttp") | .port' \
    "$CONFIG_FILE" 2>/dev/null)

  # Edge case: ни одного XHTTP inbound'а — миграция не нужна, return 1.
  if [[ -z "$xhttp_ports" ]]; then
    echo -e "${GREEN}✓ No XHTTP inbounds found, migration not needed${NC}"
    return 1
  fi

  for port in $xhttp_ports; do
    [[ -z "$port" ]] && continue

    # Detection: xmux уже есть? (CONTEXT.md decision 5: skip-if-exists)
    # Robust check: extra может отсутствовать целиком, // {} guard'ит, .xmux может быть null/empty obj.
    local has_xmux
    has_xmux=$(jq -r --argjson port "$port" '
      (.inbounds[] | select(.port == $port) | .streamSettings.xhttpSettings.extra // {} | .xmux) // null
      | if . == null or . == {} then "false" else "true" end
    ' "$CONFIG_FILE" 2>/dev/null)

    if [[ "$has_xmux" == "true" ]]; then
      echo -e "${CYAN}  → Port $port: xmux already present, skip${NC}"
      ((skipped++))
      continue
    fi

    # Detection: deprecated max_connections (для логирования)
    local has_max_connections
    has_max_connections=$(jq -r --argjson port "$port" '
      (.inbounds[] | select(.port == $port) | .streamSettings.xhttpSettings.extra // {} | .max_connections) // null
      | if . == null then "false" else "true" end
    ' "$CONFIG_FILE" 2>/dev/null)

    if [[ "$has_max_connections" == "true" ]]; then
      echo -e "${YELLOW}  → Port $port: removing deprecated max_connections${NC}"
    fi

    echo -e "${YELLOW}  → Port $port: adding explicit xmux block${NC}"

    # Atomic transformation через safe_jq_write (Phase 4 helper).
    # |= update-в-place на subtree extra.
    # (. // {}) — promote null/missing extra в {} для дальнейшего .xmux assignment.
    # del(.max_connections) — idempotent: no-op если поля нет.
    # .xmux = { ... } — explicit throughput-friendly block.
    if safe_jq_write --argjson port "$port" '
      (.inbounds[] | select(.port == $port) | .streamSettings.xhttpSettings.extra) |= (
        (. // {})
        | del(.max_connections)
        | .xmux = {
            "maxConcurrency":   "16-32",
            "hMaxRequestTimes": "600-900",
            "hMaxReusableSecs": "1800-3000",
            "hKeepAlivePeriod": 0
          }
      )
    ' "$CONFIG_FILE"; then
      ((migrated++))
    else
      echo -e "${RED}  ✗ safe_jq_write failed for port $port${NC}"
      ((failed++))
    fi
  done

  # Three-valued return:
  if [[ $failed -gt 0 ]]; then
    echo -e "${RED}✗ xmux explicit migration: $failed inbound(s) failed, $migrated succeeded, $skipped skipped${NC}"
    return 2  # fail — marker НЕ создается, повторится при следующем запуске
  fi

  if [[ $migrated -gt 0 ]]; then
    echo -e "${GREEN}✓ xmux explicit added for $migrated XHTTP inbound(s), $skipped skipped${NC}"
    return 0  # changed → restart needed
  else
    echo -e "${GREEN}✓ xmux explicit migration not needed (all $skipped XHTTP already correct)${NC}"
    return 1  # no-op → marker создается, restart НЕ нужен
  fi
}

_migrate_xhttp_xmux_throughput_2026() {
  echo -e "${CYAN}Checking XHTTP XMUX throughput profile...${NC}"

  local affected
  affected=$(jq -r '
    .inbounds[]
    | select(.streamSettings.network == "xhttp")
    | select(
        (.streamSettings.xhttpSettings.extra.xmux.maxConcurrency // "") == "1-1"
        or (.streamSettings.xhttpSettings.extra.xmux.hKeepAlivePeriod // null) == 30
      )
    | .port
  ' "$CONFIG_FILE" 2>/dev/null)

  if [[ -z "$affected" ]]; then
    echo -e "${GREEN}✓ XHTTP XMUX throughput profile already normal${NC}"
    return 1
  fi

  echo -e "${YELLOW}  → Updating XHTTP XMUX on ports: ${affected//$'\n'/, }${NC}"
  if safe_jq_write '
    (.inbounds[] | select(.streamSettings.network == "xhttp") | .streamSettings.xhttpSettings.extra.xmux) |= (
      (. // {})
      | if (.maxConcurrency // "") == "1-1" then .maxConcurrency = "16-32" else . end
      | if (.hKeepAlivePeriod // null) == 30 then .hKeepAlivePeriod = 0 else . end
    )
  ' "$CONFIG_FILE"; then
    fix_xray_permissions
    echo -e "${GREEN}✓ XHTTP XMUX: maxConcurrency 16-32, hKeepAlivePeriod 0${NC}"
    return 0
  fi

  echo -e "${RED}✗ Could not update the XHTTP XMUX throughput profile${NC}"
  return 2
}

# Phase 6 REQ-A02: догенерация PQ ключей VLESS Encryption на v1.0-апгрейде.
# НЕ мутирует config.json — только создаёт два файла ключей. Поэтому
# return 1 (no-op/mark, без restart) даже когда ключи реально сгенерированы.
# Restart Xray не нужен — config.json не изменился, ключи будут использованы
# при следующем add_inbound (Plan 6.2).
#
# Three-valued return contract:
#   1 — done (ключи уже есть ИЛИ успешно сгенерированы — в обоих случаях marker ставится)
#   ≥2 — fail (Xray-core < 25.9.5 ИЛИ vlessenc ошибка ИЛИ парсер не справился)
_migrate_mlkem_keys() {
  echo -e "${CYAN}Checking for VLESS Encryption PQ keys...${NC}"

  # Уже есть оба файла + они валидны? — no-op.
  if [[ -f "$VLESS_DECRYPTION_FILE" ]] && [[ -f "$VLESS_ENCRYPTION_FILE" ]] && \
     grep -q '^mlkem768x25519plus\.' "$VLESS_DECRYPTION_FILE" 2>/dev/null && \
     grep -q '^mlkem768x25519plus\.' "$VLESS_ENCRYPTION_FILE" 2>/dev/null; then
    echo -e "${GREEN}✓ PQ keys already generated${NC}"
    return 1
  fi

  # Version-check: vlessenc появился в Xray-core 25.9.5.
  # Парсим major.minor.patch из `xray version` (формат: "Xray 25.9.5 (Xray, ...)").
  local xray_ver_full xray_major xray_minor xray_patch
  xray_ver_full=$(/usr/local/bin/xray version 2>/dev/null | grep -oE 'Xray [0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $2}')
  if [[ -z "$xray_ver_full" ]]; then
    echo -e "${RED}✗ Could not determine the Xray-core version${NC}"
    echo -e "${YELLOW}  Run: /usr/local/bin/xray version${NC}"
    return 2
  fi
  xray_major=$(echo "$xray_ver_full" | cut -d. -f1)
  xray_minor=$(echo "$xray_ver_full" | cut -d. -f2)
  xray_patch=$(echo "$xray_ver_full" | cut -d. -f3)
  if [[ "$xray_major" -lt 25 ]] || \
     { [[ "$xray_major" -eq 25 ]] && [[ "$xray_minor" -lt 9 ]]; } || \
     { [[ "$xray_major" -eq 25 ]] && [[ "$xray_minor" -eq 9 ]] && [[ "$xray_patch" -lt 5 ]]; }; then
    echo -e "${RED}✗ Xray-core $xray_ver_full < 25.9.5 — vlessenc unavailable${NC}"
    echo -e "${YELLOW}  Update Xray-core: sudo xraytailscale update${NC}"
    echo -e "${YELLOW}  The migration will retry automatically after the update${NC}"
    return 2
  fi

  # Запуск vlessenc (тот же 3-layer парсер что в install.sh — keep in sync).
  echo -e "${CYAN}  → Running xray vlessenc${NC}"
  local vlessenc_output vlessenc_rc
  vlessenc_output=$(/usr/local/bin/xray vlessenc 2>&1)
  vlessenc_rc=$?
  if [[ $vlessenc_rc -ne 0 ]]; then
    echo -e "${RED}✗ xray vlessenc rc=$vlessenc_rc${NC}"
    echo "$vlessenc_output"
    return 2
  fi

  local decryption encryption
  decryption=$(echo "$vlessenc_output" | awk -F'"' '
    /^Authentication: ML-KEM-768/ { in_mlkem=1; next }
    in_mlkem && /^"decryption":/ { print $4; exit }
  ' | tr -d '[:space:]')
  encryption=$(echo "$vlessenc_output" | awk -F'"' '
    /^Authentication: ML-KEM-768/ { in_mlkem=1; next }
    in_mlkem && /^"encryption":/ { print $4; exit }
  ' | tr -d '[:space:]')

  if [[ ! "$decryption" =~ ^mlkem768x25519plus\. ]] || [[ ! "$encryption" =~ ^mlkem768x25519plus\. ]]; then
    local mlkem_lines
    mlkem_lines=$(echo "$vlessenc_output" | grep -oE 'mlkem768x25519plus\.[^"[:space:]]+')
    decryption=$(echo "$mlkem_lines" | tail -2 | sed -n '1p')
    encryption=$(echo "$mlkem_lines" | tail -1)
  fi

  if [[ ! "$decryption" =~ ^mlkem768x25519plus\. ]] || [[ ! "$encryption" =~ ^mlkem768x25519plus\. ]]; then
    echo -e "${RED}✗ Could not parse the mlkem768x25519plus keys${NC}"
    echo -e "${YELLOW}Full vlessenc output:${NC}"; echo "$vlessenc_output"
    return 2
  fi

  printf "%s" "$decryption" > "$VLESS_DECRYPTION_FILE"
  printf "%s" "$encryption" > "$VLESS_ENCRYPTION_FILE"
  chmod 600 "$VLESS_DECRYPTION_FILE" "$VLESS_ENCRYPTION_FILE"
  chown xray:xray "$VLESS_DECRYPTION_FILE" "$VLESS_ENCRYPTION_FILE" 2>/dev/null || true

  echo -e "${GREEN}✓ PQ keys generated (mlkem768x25519plus.native)${NC}"

  # IMPORTANT: return 1, не 0. Config.json не мутировал — restart не нужен.
  # run_migration touch-нет marker без вызова safe_restart_xray.
  return 1
}

# Phase 6 REQ-A08: маркер «новый дефолт create_profile_menu применён».
# СТРОГО no-op для config.json — REQ-A08 явно запрещает трогать существующие inbound'ы.
# Дефолт create_profile_menu (XHTTP+PQ как #1) зашит в код Task 3А — миграция здесь
# нужна только чтобы не показывать first-run-баннер ещё раз (Plan 6.3 повторно использует
# тот же паттерн pq_banner_shown).
# Возвращает 1 (no-op/mark) — run_migration ставит маркер без safe_restart_xray.
_migrate_xhttp_default_2026() {
  echo -e "${CYAN}Marking the create_profile_menu default template as XHTTP+PQ...${NC}"
  echo -e "${GREEN}✓ Default template updated in code (REQ-A08: existing inbounds untouched)${NC}"
  return 1
}

# Общий поиск single-route legacy профилей для предупреждения и миграции.
# Multi-route, уже включённые PQ и служебный bulk-seed не попадают в список.
_list_legacy_pq_profile_names() {
  local profile_file profile_name
  for profile_file in "$PROFILES_DIR"/*.json; do
    [[ -f "$profile_file" ]] || continue
    _profile_is_bulk_seed_file "$profile_file" && continue
    profile_has_routes "$profile_file" && continue
    [[ "$(jq -r '.pq_enabled // false' "$profile_file" 2>/dev/null)" == "true" ]] && continue
    profile_name=$(basename "$profile_file" .json)
    echo "$profile_name"
  done | sort
}

# Автоматический перевод старых single-route профилей на XHTTP+PQ.
# run_migration уже создал общий бэкап; каждый helper дополнительно создаёт свой
# точечный бэкап и применяет один inbound сразу через safe_restart_xray.
# Return: 0=changed, 1=no-op, 2=fail.
_migrate_pq_all_profiles_2026() {
  local legacy_profiles=()
  local profile_name
  while IFS= read -r profile_name; do
    [[ -n "$profile_name" ]] && legacy_profiles+=("$profile_name")
  done < <(_list_legacy_pq_profile_names)

  if [[ ${#legacy_profiles[@]} -eq 0 ]]; then
    echo -e "${GREEN}✓ No single-route legacy profiles found for PQ migration${NC}"
    return 1
  fi

  if [[ ! -f "$VLESS_DECRYPTION_FILE" ]] || [[ ! -f "$VLESS_ENCRYPTION_FILE" ]]; then
    echo -e "${YELLOW}⚠ PQ migration deferred: VLESS Encryption keys not found${NC}"
    echo -e "${YELLOW}  Expected: $VLESS_DECRYPTION_FILE and $VLESS_ENCRYPTION_FILE${NC}"
    echo -e "${YELLOW}  They should be generated by the _migrate_mlkem_keys migration; config.json unchanged${NC}"
    return 1
  fi

  local ok=0
  local fail=0
  for profile_name in "${legacy_profiles[@]}"; do
    # Профиль на общем порту мог уже обновиться вместе с предыдущим.
    [[ -f "$PROFILES_DIR/$profile_name.json" ]] || continue
    if profile_has_routes "$PROFILES_DIR/$profile_name.json" || \
       _profile_is_bulk_seed_file "$PROFILES_DIR/$profile_name.json" || \
       [[ "$(jq -r '.pq_enabled // false' "$PROFILES_DIR/$profile_name.json" 2>/dev/null)" == "true" ]]; then
      continue
    fi

    echo -e "${CYAN}  → PQ-migrating profile '$profile_name'${NC}"
    if _pq_upgrade_one_profile "$profile_name"; then
      ((ok += 1))
    else
      echo -e "${RED}  ✗ Could not migrate profile '$profile_name'${NC}"
      ((fail += 1))
    fi
  done

  if [[ $fail -gt 0 ]]; then
    echo -e "${RED}✗ PQ migration: $ok succeeded, $fail failed${NC}"
    return 2
  fi
  if [[ $ok -gt 0 ]]; then
    echo -e "${GREEN}✓ PQ migration finished: $ok profiles updated${NC}"
    return 0
  fi

  echo -e "${GREEN}✓ All found profiles already updated${NC}"
  return 1
}

# Phase 7 REQ-C04: догенерируем sub_token для существующих профилей,
# созданных до Phase 7 (нет поля .sub_token).
# Return: 0 = были изменения config.json (НЕ наш случай, миграция не трогает config.json),
#         1 = no-op/mark — ставим маркер БЕЗ safe_restart_xray (config.json не тронут),
#         ≥2 = жёсткая ошибка записи.
# Эта миграция работает ТОЛЬКО с profile JSONs в $PROFILES_DIR.
_migrate_subscription_tokens_2026() {
  local changed=0
  local profile_file
  for profile_file in "$PROFILES_DIR"/*.json; do
    [[ ! -f "$profile_file" ]] && continue
    local existing
    existing=$(jq -r '.sub_token // ""' "$profile_file" 2>/dev/null)
    if [[ -n "$existing" ]] && [[ "$existing" =~ ^[a-f0-9]{32}$ ]]; then
      continue   # уже есть валидный 32-hex
    fi
    local new_token
    new_token=$(openssl rand -hex 16)
    if [[ ! "$new_token" =~ ^[a-f0-9]{32}$ ]]; then
      echo -e "${RED}  ✗ openssl rand returned an invalid token for $(basename "$profile_file")${NC}"
      return 2
    fi
    if ! safe_jq_write --arg t "$new_token" '.sub_token = $t' "$profile_file"; then
      echo -e "${RED}  ✗ safe_jq_write failed for $profile_file${NC}"
      return 2
    fi
    chown xray:xray "$profile_file" 2>/dev/null || true
    chmod 644 "$profile_file" 2>/dev/null || true
    echo -e "${GREEN}  ✓ sub_token generated for $(basename "$profile_file" .json)${NC}"
    changed=1
  done
  # Возвращаем 1 даже при изменениях — config.json НЕ модифицирован, рестарт Xray не нужен.
  # run_migration на rc=1 ставит marker без safe_restart_xray. Это и нужно.
  if [[ $changed -eq 1 ]]; then
    echo -e "${CYAN}  → sub_token backfill finished (no Xray restart needed)${NC}"
  fi
  return 1
}

_migrate_sni_list_2026() {
  local sni_file="$SNI_LIST"
  if [[ ! -f "$sni_file" && -f /usr/local/etc/xray/sni_list.txt ]]; then
    sni_file="/usr/local/etc/xray/sni_list.txt"
  fi
  [[ -f "$sni_file" ]] || return 1

  local -A known_defaults=()
  local domain
  for domain in "${KNOWN_DEFAULTS_v1[@]}"; do
    known_defaults["$domain"]=1
  done

  local -a to_add_p1=(
    "online.uralsib.ru|ru_whitelist|1"
    "online.vtb.ru|ru_whitelist|1"
    "www.cdek.ru|ru_whitelist|1"
    "www.pochta.ru|ru_whitelist|1"
    "www.avito.ru|ru_whitelist|1"
  )
  local -a to_add_p3=(
    "github.com|foreign|3"
  )

  local changed=0
  local line entry
  for entry in "${to_add_p1[@]}" "${to_add_p3[@]}"; do
    if ! grep -Fxq "$entry" "$sni_file" 2>/dev/null; then
      changed=1
      break
    fi
  done

  if [[ $changed -eq 0 ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      domain="${line%%|*}"
      if [[ -n "${known_defaults[$domain]:-}" ]] && [[ "$domain" =~ (^|\.)(apple|icloud)\.com$ ]]; then
        changed=1
        break
      fi
    done < "$sni_file"
  fi

  [[ $changed -eq 0 ]] && return 1

  local tmp
  tmp=$(mktemp /tmp/sni-list.XXXXXX) || {
    echo -e "${RED}  ✗ mktemp failed for the SNI list${NC}"
    return 2
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    domain="${line%%|*}"
    if [[ -n "${known_defaults[$domain]:-}" ]] && [[ "$domain" =~ (^|\.)(apple|icloud)\.com$ ]]; then
      continue
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$sni_file"

  for entry in "${to_add_p1[@]}" "${to_add_p3[@]}"; do
    domain="${entry%%|*}"
    local exists=0
    while IFS='|' read -r existing_domain _ _ || [[ -n "$existing_domain" ]]; do
      [[ "$existing_domain" == "$domain" ]] && { exists=1; break; }
    done < "$tmp"
    [[ $exists -eq 0 ]] && printf '%s\n' "$entry" >> "$tmp"
  done

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo -e "${RED}  ✗ SNI migration produced empty file${NC}"
    return 2
  fi

  mv "$tmp" "$sni_file"
  chown xray:xray "$sni_file" 2>/dev/null || true
  chmod 644 "$sni_file" 2>/dev/null || true

  echo -e "${GREEN}✓ SNI list 2026 updated: RU banks/logistics + github, apple/icloud removed${NC}"
  return 0
}

_migrate_bypass_routing_2026() {
  echo ""
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  BYPASS ROUTING (new in v2.0)               ${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "${CYAN}You can route certain domains around the VPN:${NC}"
  echo -e "  ${YELLOW}-${NC} Steam (CDN, chat, community) — faster without VPN"
  echo -e "  ${YELLOW}-${NC} RU services (gosuslugi, nalog, mos) — must use a RU IP"
  echo -e "  ${YELLOW}-${NC} RU banks (sber, vtb, tinkoff, alfa) — require a RU IP"
  echo -e "  ${YELLOW}-${NC} Marketplaces (ozon, wb, avito)"
  echo -e "  ${YELLOW}-${NC} Yandex services"
  echo ""
  echo -e "${CYAN}These domains will go through the freedom outbound (direct), not the VPN.${NC}"
  echo ""
  echo -n -e "${YELLOW}Add the default bypass rules? [y/N]: ${NC}"

  local ans
  read -r ans
  ans="${ans:-N}"

  if [[ "$ans" =~ ^[yYдД]$ ]]; then
    _bypass_apply_bundle
  else
    echo -e "${CYAN}Skipped. You can set it up later via More → Cascade / upstream → VPN bypass.${NC}"
    sleep 1
  fi

  # Marker ставится через run_migration независимо от ответа — больше не спрашивать.
  return 1
}

_migrate_subhttp_multiroute_2026() {
  if [[ ! -f /usr/local/etc/xray/.subscription_installed ]]; then
    echo -e "${CYAN}  → HAPP subscription not installed — subhttp migration skip${NC}"
    return 1
  fi

  echo -e "${CYAN}  → Regenerating subhttp.sh for multi-route subscriptions...${NC}"
  if ! install_subscription_server >/dev/null 2>&1; then
    echo -e "${RED}  ✗ Could not regenerate subhttp.sh${NC}"
    return 2
  fi

  if systemctl is-active --quiet xraytailscale-sub.service; then
    systemctl restart xraytailscale-sub.service || {
      echo -e "${RED}  ✗ Could not restart xraytailscale-sub.service${NC}"
      return 2
    }
    echo -e "${GREEN}  ✓ xraytailscale-sub.service restarted${NC}"
  fi

  return 1
}

_migrate_subhttp_client_compat_2026() {
  if [[ ! -f /usr/local/etc/xray/.subscription_installed ]]; then
    echo -e "${CYAN}  → HAPP subscription not installed — client-compat migration skip${NC}"
    return 1
  fi

  echo -e "${CYAN}  → Regenerating subhttp.sh for v2rayNG/v2rayN-compatible subscriptions...${NC}"
  if ! install_subscription_server >/dev/null 2>&1; then
    echo -e "${RED}  ✗ Could not regenerate subhttp.sh${NC}"
    return 2
  fi

  if systemctl is-active --quiet xraytailscale-sub.service; then
    systemctl restart xraytailscale-sub.service || {
      echo -e "${RED}  ✗ Could not restart xraytailscale-sub.service${NC}"
      return 2
    }
    echo -e "${GREEN}  ✓ xraytailscale-sub.service restarted${NC}"
  fi

  return 1
}

_migrate_subhttp_no_default_happ_routing_2026() {
  if [[ ! -f /usr/local/etc/xray/.subscription_installed ]]; then
    echo -e "${CYAN}  → HAPP subscription not installed — no-default-routing migration skip${NC}"
    return 1
  fi

  echo -e "${CYAN}  → Regenerating subhttp.sh without the default HAPP routing profile...${NC}"
  if ! install_subscription_server >/dev/null 2>&1; then
    echo -e "${RED}  ✗ Could not regenerate subhttp.sh${NC}"
    return 2
  fi

  if systemctl is-active --quiet xraytailscale-sub.service; then
    systemctl restart xraytailscale-sub.service || {
      echo -e "${RED}  ✗ Could not restart xraytailscale-sub.service${NC}"
      return 2
    }
    echo -e "${GREEN}  ✓ xraytailscale-sub.service restarted${NC}"
  fi

  return 1
}

_migrate_subhttp_stale_profiles_410_2026() {
  if [[ ! -f /usr/local/etc/xray/.subscription_installed ]]; then
    echo -e "${CYAN}  → HAPP subscription not installed — stale-profile migration skip${NC}"
    return 1
  fi

  echo -e "${CYAN}  → Regenerating subhttp.sh for stale profile diagnostics...${NC}"
  if ! install_subscription_server >/dev/null 2>&1; then
    echo -e "${RED}  ✗ Could not regenerate subhttp.sh${NC}"
    return 2
  fi

  if systemctl is-active --quiet xraytailscale-sub.service; then
    systemctl restart xraytailscale-sub.service || {
      echo -e "${RED}  ✗ Could not restart xraytailscale-sub.service${NC}"
      return 2
    }
    echo -e "${GREEN}  ✓ xraytailscale-sub.service restarted${NC}"
  fi

  return 1
}

_migrate_subhttp_happ_xhttp_compat_2026() {
  if [[ ! -f /usr/local/etc/xray/.subscription_installed ]]; then
    echo -e "${CYAN}  → HAPP subscription not installed — HAPP XHTTP compatibility migration skip${NC}"
    return 1
  fi

  echo -e "${CYAN}  → Regenerating subhttp.sh for HAPP XHTTP compatibility...${NC}"
  if ! install_subscription_server >/dev/null 2>&1; then
    echo -e "${RED}  ✗ Could not regenerate subhttp.sh${NC}"
    return 2
  fi

  if systemctl is-active --quiet xraytailscale-sub.service; then
    systemctl restart xraytailscale-sub.service || {
      echo -e "${RED}  ✗ Could not restart xraytailscale-sub.service${NC}"
      return 2
    }
    echo -e "${GREEN}  ✓ xraytailscale-sub.service restarted${NC}"
  fi

  return 1
}

_migrate_happ_legacy_xhttp_route_2026() {
  echo -e "${CYAN}  → HAPP no longer adds routes to existing profiles automatically${NC}"
  echo -e "${CYAN}    The quick HAPP flow creates a separate multi-route profile; manual control via 'Create profile'.${NC}"
  return 1
}

_migrate_subhttp_happ_legacy_xhttp_2026() {
  if [[ ! -f /usr/local/etc/xray/.subscription_installed ]]; then
    echo -e "${CYAN}  → HAPP subscription not installed — legacy-XHTTP subscription migration skip${NC}"
    return 1
  fi

  echo -e "${CYAN}  → Regenerating subhttp.sh with legacy XHTTP priority for HAPP...${NC}"
  if ! install_subscription_server >/dev/null 2>&1; then
    echo -e "${RED}  ✗ Could not regenerate subhttp.sh${NC}"
    return 2
  fi

  if systemctl is-active --quiet xraytailscale-sub.service; then
    systemctl restart xraytailscale-sub.service || {
      echo -e "${RED}  ✗ Could not restart xraytailscale-sub.service${NC}"
      return 2
    }
    echo -e "${GREEN}  ✓ xraytailscale-sub.service restarted${NC}"
  fi

  return 1
}

