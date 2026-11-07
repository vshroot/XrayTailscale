_bulk_seed_profile_file() {
  echo "$PROFILES_DIR/_bulk_seed.json"
}

_bulk_subscription_installed() {
  [[ -f /usr/local/etc/xray/.subscription_installed ]]
}

_bulk_validate_prefix() {
  local prefix="$1"
  [[ "$prefix" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]
}

_bulk_name_width() {
  local count="$1"
  local width=${#count}
  [[ "$width" -lt 3 ]] && width=3
  echo "$width"
}

_bulk_target_name() {
  local prefix="$1" index="$2" count="$3" width
  width=$(_bulk_name_width "$count")
  printf "%s-%0${width}d" "$prefix" "$index"
}

_bulk_seed_routes_exist_in_config() {
  local seed_file="$1"
  jq -e --slurpfile cfg "$CONFIG_FILE" '
    all((.routes // [])[]; .port as $p | any($cfg[0].inbounds[]?; .port == $p))
  ' "$seed_file" >/dev/null 2>&1
}

_bulk_recreate_seed_profile() {
  local seed_file="$1"
  local backup_file="${seed_file}.stale-$(date +%Y%m%d-%H%M%S)"

  if [[ -f "$seed_file" ]]; then
    cp "$seed_file" "$backup_file" 2>/dev/null || true
  fi

  echo -e "${YELLOW}  ⚠ Bulk seed ссылается на отсутствующие порты — пересоздаю _bulk_seed${NC}"
  if ! create_profile_all_routes "_bulk_seed" "no_pause" "hide_subscription"; then
    [[ -f "$backup_file" ]] && cp "$backup_file" "$seed_file" 2>/dev/null || true
    echo -e "${RED}✗ Не удалось пересоздать bulk seed profile${NC}"
    return 1
  fi
  if ! safe_jq_write '.bulk_seed = true | .bulk_managed = false | .sub_token = ""' "$seed_file"; then
    [[ -f "$backup_file" ]] && cp "$backup_file" "$seed_file" 2>/dev/null || true
    echo -e "${RED}✗ Не удалось пометить пересозданный bulk seed profile${NC}"
    return 1
  fi
  fix_xray_permissions
}

_bulk_seed_ready() {
  local seed_file
  seed_file=$(_bulk_seed_profile_file)

  if [[ ! -f "$seed_file" ]]; then
    echo -e "${CYAN}  → Создаю shared multi-route seed: _bulk_seed${NC}"
    if ! create_profile_all_routes "_bulk_seed" "no_pause" "hide_subscription"; then
      echo -e "${RED}✗ Не удалось создать bulk seed profile${NC}"
      return 1
    fi
    if ! safe_jq_write '.bulk_seed = true | .bulk_managed = false | .sub_token = ""' "$seed_file"; then
      echo -e "${RED}✗ Не удалось пометить bulk seed profile${NC}"
      return 1
    fi
    fix_xray_permissions
  fi

  if ! jq -e '
      .bulk_seed == true
      and .multi_route == true
      and ((.routes // []) | length > 0)
      and all((.routes // [])[]; (.port | type == "number") and ((.transport // "") | length > 0))
    ' "$seed_file" >/dev/null 2>&1; then
    echo -e "${RED}✗ _bulk_seed.json поврежден или не является multi-route seed${NC}"
    return 1
  fi

  if ! _bulk_seed_routes_exist_in_config "$seed_file"; then
    _bulk_recreate_seed_profile "$seed_file" || return 1
  fi

  if ! _bulk_seed_routes_exist_in_config "$seed_file"; then
    echo -e "${RED}✗ У bulk seed есть route, порт которого отсутствует в live config.json даже после пересоздания${NC}"
    return 1
  fi
}

_bulk_build_users_json() {
  local prefix="$1" count="$2" batch_id="$3"
  local tmp name uuid sub_token
  tmp=$(mktemp /tmp/xraytailscale-bulk-users.XXXXXX) || return 1

  local i
  for ((i = 1; i <= count; i++)); do
    name=$(_bulk_target_name "$prefix" "$i" "$count")
    uuid=$(uuidgen)
    sub_token=$(openssl rand -hex 16)
    if [[ ! "$uuid" =~ ^[0-9a-fA-F-]{36}$ || ! "$sub_token" =~ ^[a-f0-9]{32}$ ]]; then
      rm -f "$tmp"
      echo -e "${RED}✗ Не удалось сгенерировать UUID/sub_token для $name${NC}"
      return 1
    fi
    jq -n \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg sub_token "$sub_token" \
      --arg batch_id "$batch_id" \
      '{name:$name,uuid:$uuid,sub_token:$sub_token,batch_id:$batch_id}' >> "$tmp" || {
        rm -f "$tmp"
        return 1
      }
  done

  jq -s '.' "$tmp"
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

_bulk_write_user_profile() {
  local name="$1" uuid="$2" sub_token="$3" batch_id="$4" routes_json="$5" created="$6"
  local profile_file="$PROFILES_DIR/$name.json"

  jq -n \
    --arg name "$name" \
    --arg uuid "$uuid" \
    --arg sub_token "$sub_token" \
    --arg batch_id "$batch_id" \
    --arg created "$created" \
    --arg default_fp "$DEFAULT_CLIENT_FINGERPRINT" \
    --argjson routes "$routes_json" \
    '{
      name: $name,
      uuid: $uuid,
      schema_version: 3,
      multi_route: true,
      bulk_managed: true,
      bulk_batch_id: $batch_id,
      primary_route: ($routes[0].label // "xhttp-legacy"),
      sub_token: $sub_token,
      created: $created,
      routes: $routes
    }
    + {
      transport: $routes[0].transport,
      port: $routes[0].port,
      fingerprint: ($routes[0].fingerprint // $default_fp),
      sni: ($routes[0].sni // "www.ozon.ru")
    }
    + (if (($routes[0].xhttp_path // "") | length) > 0 then {xhttp_path: $routes[0].xhttp_path} else {} end)
    + (if ($routes[0].pq_enabled // false) then {pq_enabled: true} else {pq_enabled: false} end)' \
    > "$profile_file"
}

_bulk_add_users_to_inbounds() {
  local users_json="$1" routes_json="$2"
  local clients_json
  clients_json=$(jq -cn --argjson users "$users_json" --argjson routes "$routes_json" '
    [
      $routes[] as $route
      | $users[] as $user
      | {
          port: $route.port,
          id: $user.uuid,
          flow: (if ($route.transport == "tcp" or $route.transport == "tcp-utls" or $route.transport == "tcp-xudp") then "xtls-rprx-vision" else "" end)
        }
    ]
  ') || return 1

  safe_jq_write --argjson clients "$clients_json" '
    reduce $clients[] as $client (.;
      (.inbounds[]? | select(.port == $client.port) | .settings.clients) |=
        (((. // []) | map(select(.id != $client.id))) + [{id: $client.id, flow: $client.flow}])
    )
  ' "$CONFIG_FILE"
}

_bulk_sync_user_profile_to_seed_routes() {
  local profile_file="$1" routes_json="$2"
  safe_jq_write --arg default_fp "$DEFAULT_CLIENT_FINGERPRINT" --argjson routes "$routes_json" '
    .routes = $routes
    | .schema_version = 3
    | .multi_route = true
    | .primary_route = ($routes[0].label // "xhttp-legacy")
    | .transport = ($routes[0].transport // .transport)
    | .port = ($routes[0].port // .port)
    | .fingerprint = ($routes[0].fingerprint // $default_fp)
    | .sni = ($routes[0].sni // "www.ozon.ru")
    | .pq_enabled = ($routes[0].pq_enabled // false)
    | if (($routes[0].xhttp_path // "") | length) > 0 then
        .xhttp_path = $routes[0].xhttp_path
      else
        del(.xhttp_path)
      end
  ' "$profile_file"
}

_repair_stale_subscription_profiles_core() {
  local scope="${1:-bulk}"
  local repair_label="stale bulk users"
  local backup_label="bulk_repair_stale_users"
  local tmp_prefix="bulk-repair"
  if [[ "$scope" == "all" ]]; then
    repair_label="stale subscription profiles"
    backup_label="subscription_repair_stale_profiles"
    tmp_prefix="subscription-repair"
  fi

  local repair_profiles=()
  local pf route_count live_count token uuid needs_repair
  for pf in "$PROFILES_DIR"/*.json; do
    [[ -f "$pf" ]] || continue
    _profile_is_bulk_seed_file "$pf" && continue
    if [[ "$scope" == "bulk" ]]; then
      jq -e '.bulk_managed == true and .bulk_seed != true' "$pf" >/dev/null 2>&1 || continue
    else
      token=$(jq -r '.sub_token // ""' "$pf" 2>/dev/null)
      uuid=$(jq -r '.uuid // ""' "$pf" 2>/dev/null)
      [[ "$token" =~ ^[a-f0-9]{32}$ && "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || continue
    fi
    route_count=$(_profile_route_count "$pf" 2>/dev/null || true)
    route_count="${route_count##*$'\n'}"
    live_count=$(_profile_live_route_count "$pf" 2>/dev/null || true)
    live_count="${live_count##*$'\n'}"
    needs_repair=0
    if [[ "$route_count" =~ ^[0-9]+$ && "$route_count" -gt 0 ]]; then
      if [[ "$live_count" =~ ^[0-9]+$ && "$live_count" -lt "$route_count" ]]; then
        needs_repair=1
      fi
    elif [[ "$live_count" =~ ^[0-9]+$ && "$live_count" -eq 0 ]]; then
      needs_repair=1
    fi
    if [[ "$needs_repair" -eq 1 ]]; then
      repair_profiles+=("$pf")
    fi
  done

  [[ ${#repair_profiles[@]} -eq 0 ]] && return 0

  _bulk_seed_ready || return 1

  local seed_file routes_json
  seed_file=$(_bulk_seed_profile_file)
  routes_json=$(jq -c '.routes' "$seed_file") || return 1
  if ! jq -e 'length > 0' <<< "$routes_json" >/dev/null; then
    echo -e "${RED}✗ Bulk seed не содержит routes для repair${NC}"
    return 1
  fi

  local rollback_config="" profiles_snapshot=""
  backup_config "$backup_label" rollback_config || return 1
  _snapshot_profiles profiles_snapshot || return 1

  local backup_dir users_tmp
  backup_dir=$(mktemp -d "/tmp/xraytailscale-${tmp_prefix}.XXXXXX") || return 1
  users_tmp=$(mktemp "/tmp/xraytailscale-${tmp_prefix}-users.XXXXXX") || {
    rm -rf "$backup_dir"
    return 1
  }

  for pf in "${repair_profiles[@]}"; do
    cp "$pf" "$backup_dir/$(basename "$pf")" || {
      rm -rf "$backup_dir"
      rm -f "$users_tmp"
      echo -e "${RED}✗ Не удалось сохранить backup ${repair_label}${NC}"
      return 1
    }
  done

  local name
  for pf in "${repair_profiles[@]}"; do
    name=$(jq -r '.name // empty' "$pf" 2>/dev/null)
    [[ -z "$name" ]] && name=$(basename "$pf" .json)
    uuid=$(jq -r '.uuid // empty' "$pf" 2>/dev/null)
    if [[ -z "$name" || ! "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]]; then
      for pf in "${repair_profiles[@]}"; do
        cp "$backup_dir/$(basename "$pf")" "$pf" 2>/dev/null || true
      done
      rm -rf "$backup_dir"
      rm -f "$users_tmp"
      echo -e "${RED}✗ ${repair_label}: profile без валидного name/UUID${NC}"
      return 1
    fi
    if ! _bulk_sync_user_profile_to_seed_routes "$pf" "$routes_json"; then
      for pf in "${repair_profiles[@]}"; do
        cp "$backup_dir/$(basename "$pf")" "$pf" 2>/dev/null || true
      done
      rm -rf "$backup_dir"
      rm -f "$users_tmp"
      echo -e "${RED}✗ Не удалось синхронизировать ${repair_label} routes${NC}"
      return 1
    fi
    jq -n --arg name "$name" --arg uuid "$uuid" '{name:$name, uuid:$uuid}' >> "$users_tmp" || {
      for pf in "${repair_profiles[@]}"; do
        cp "$backup_dir/$(basename "$pf")" "$pf" 2>/dev/null || true
      done
      rm -rf "$backup_dir"
      rm -f "$users_tmp"
      return 1
    }
  done

  local users_json
  users_json=$(jq -s '.' "$users_tmp") || {
    for pf in "${repair_profiles[@]}"; do
      cp "$backup_dir/$(basename "$pf")" "$pf" 2>/dev/null || true
    done
    rm -rf "$backup_dir"
    rm -f "$users_tmp"
    return 1
  }

  if ! _bulk_add_users_to_inbounds "$users_json" "$routes_json"; then
    for pf in "${repair_profiles[@]}"; do
      cp "$backup_dir/$(basename "$pf")" "$pf" 2>/dev/null || true
    done
    rm -rf "$backup_dir"
    rm -f "$users_tmp"
    echo -e "${RED}✗ Не удалось добавить repaired UUID в live inbounds${NC}"
    return 1
  fi

  fix_xray_permissions
  if ! safe_restart_xray "$rollback_config"; then
    for pf in "${repair_profiles[@]}"; do
      cp "$backup_dir/$(basename "$pf")" "$pf" 2>/dev/null || true
    done
    _restore_profiles_snapshot "$profiles_snapshot" >/dev/null 2>&1 || true
    fix_xray_permissions
    rm -rf "$backup_dir"
    rm -f "$users_tmp"
    echo -e "${RED}✗ Xray не принял repair ${repair_label} — profile JSON восстановлены${NC}"
    return 1
  fi

  rm -rf "$backup_dir"
  rm -f "$users_tmp"
  _discard_profiles_snapshot "$profiles_snapshot"
  echo -e "${GREEN}✓ ${repair_label} восстановлены: ${#repair_profiles[@]}${NC}"
}

bulk_repair_stale_users_core() {
  _repair_stale_subscription_profiles_core "bulk"
}

repair_stale_subscription_profiles_core() {
  _repair_stale_subscription_profiles_core "all"
}

bulk_print_users_urls_core() {
  local filter_batch="${1:-}"
  if [[ -n "$filter_batch" && ! "$filter_batch" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo -e "${RED}✗ Некорректный batch id${NC}"
    return 1
  fi

  bulk_repair_stale_users_core || return 1

  local base_url rows pf name token uuid pf_batch
  base_url=$(_subscription_base_url)
  rows=0
  echo "Batch: ${filter_batch:-all}"
  echo "name subscription_url"
  for pf in "$PROFILES_DIR"/*.json; do
    [[ -f "$pf" ]] || continue
    jq -e '.bulk_managed == true and .bulk_seed != true' "$pf" >/dev/null 2>&1 || continue
    pf_batch=$(jq -r '.bulk_batch_id // ""' "$pf" 2>/dev/null)
    if [[ -n "$filter_batch" && "$pf_batch" != "$filter_batch" ]]; then
      continue
    fi
    name=$(jq -r '.name // empty' "$pf" 2>/dev/null)
    token=$(jq -r '.sub_token // empty' "$pf" 2>/dev/null)
    uuid=$(jq -r '.uuid // empty' "$pf" 2>/dev/null)
    [[ -n "$name" && "$token" =~ ^[a-f0-9]{32}$ && -n "$uuid" ]] || continue
    printf '%s %s/sub/%s\n' "$name" "$base_url" "$token"
    rows=$((rows + 1))
  done

  if [[ "$rows" -eq 0 ]]; then
    echo -e "${YELLOW}Нет bulk users для batch: ${filter_batch:-all}${NC}"
    return 1
  fi
}

bulk_generate_users_core() {
  local prefix="$1" count="$2" batch_id="${3:-}"
  [[ -z "$batch_id" ]] && batch_id="bulk-$(date +%Y%m%d-%H%M%S)"

  if ! _bulk_subscription_installed; then
    echo -e "${RED}✗ HAPP subscription не установлена. Сначала включите пункт 9.${NC}"
    return 1
  fi
  if [[ ! "$count" =~ ^[0-9]+$ || "$count" -lt 1 || "$count" -gt 500 ]]; then
    echo -e "${RED}✗ Count должен быть числом от 1 до 500${NC}"
    return 1
  fi
  if ! _bulk_validate_prefix "$prefix"; then
    echo -e "${RED}✗ Prefix должен начинаться с буквы/цифры и содержать только буквы, цифры, '-' и '_'${NC}"
    return 1
  fi
  if [[ ! "$batch_id" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo -e "${RED}✗ Некорректный batch id${NC}"
    return 1
  fi

  local names=() i name
  for ((i = 1; i <= count; i++)); do
    name=$(_bulk_target_name "$prefix" "$i" "$count")
    if [[ -f "$PROFILES_DIR/$name.json" ]]; then
      echo -e "${RED}✗ Профиль уже существует: $name${NC}"
      return 1
    fi
    names+=("$name")
  done

  _bulk_seed_ready || return 1
  bulk_repair_stale_users_core || return 1

  local seed_file routes_json users_json created
  seed_file=$(_bulk_seed_profile_file)
  routes_json=$(jq -c '.routes' "$seed_file") || return 1
  if ! jq -e 'length > 0' <<< "$routes_json" >/dev/null; then
    echo -e "${RED}✗ Bulk seed не содержит routes${NC}"
    return 1
  fi

  users_json=$(_bulk_build_users_json "$prefix" "$count" "$batch_id") || return 1
  created=$(date +%Y-%m-%d\ %H:%M:%S)

  local rollback_config="" profiles_snapshot=""
  if ! backup_config "bulk_generate_${batch_id}" rollback_config; then
    return 1
  fi
  _snapshot_profiles profiles_snapshot || return 1

  local generated_profiles=()
  local row uuid sub_token
  while IFS= read -r row; do
    name=$(jq -r '.name' <<< "$row")
    uuid=$(jq -r '.uuid' <<< "$row")
    sub_token=$(jq -r '.sub_token' <<< "$row")
    if ! _bulk_write_user_profile "$name" "$uuid" "$sub_token" "$batch_id" "$routes_json" "$created"; then
      rm -f "${generated_profiles[@]}" 2>/dev/null || true
      echo -e "${RED}✗ Не удалось записать profile JSON для $name${NC}"
      return 1
    fi
    generated_profiles+=("$PROFILES_DIR/$name.json")
  done < <(jq -c '.[]' <<< "$users_json")

  if ! _bulk_add_users_to_inbounds "$users_json" "$routes_json"; then
    rm -f "${generated_profiles[@]}" 2>/dev/null || true
    echo -e "${RED}✗ Не удалось добавить bulk users в shared inbounds${NC}"
    return 1
  fi

  fix_xray_permissions
  if ! safe_restart_xray "$rollback_config"; then
    rm -f "${generated_profiles[@]}" 2>/dev/null || true
    _restore_profiles_snapshot "$profiles_snapshot" >/dev/null 2>&1 || true
    echo -e "${RED}✗ Xray не принял bulk config — профили удалены, config должен быть откачен safe_restart_xray${NC}"
    return 1
  fi

  _discard_profiles_snapshot "$profiles_snapshot"
  echo -e "${GREEN}✓ Bulk users создано: $count${NC}"
  bulk_print_users_urls_core "$batch_id"
}

bulk_revoke_user_core() {
  local profile_name="$1"
  local profile_file="$PROFILES_DIR/$profile_name.json"
  if [[ ! -f "$profile_file" ]]; then
    echo -e "${RED}✗ Профиль не найден: $profile_name${NC}"
    return 1
  fi
  if ! jq -e '.bulk_managed == true and .bulk_seed != true' "$profile_file" >/dev/null 2>&1; then
    echo -e "${RED}✗ Это не bulk-managed user profile${NC}"
    return 1
  fi

  local new_token
  new_token=$(openssl rand -hex 16)
  if [[ ! "$new_token" =~ ^[a-f0-9]{32}$ ]]; then
    echo -e "${RED}✗ Не удалось сгенерировать новый sub_token${NC}"
    return 1
  fi
  safe_jq_write --arg t "$new_token" '.sub_token = $t' "$profile_file" || return 1
  fix_xray_permissions
  echo -e "${GREEN}✓ Новый sub_token для $profile_name${NC}"
}

bulk_delete_user_core() {
  local profile_name="$1"
  local profile_file="$PROFILES_DIR/$profile_name.json"
  if [[ ! -f "$profile_file" ]]; then
    echo -e "${RED}✗ Профиль не найден: $profile_name${NC}"
    return 1
  fi
  if ! jq -e '.bulk_managed == true and .bulk_seed != true' "$profile_file" >/dev/null 2>&1; then
    echo -e "${RED}✗ Это не bulk-managed user profile${NC}"
    return 1
  fi

  local uuid ports_json
  uuid=$(jq -r '.uuid // ""' "$profile_file")
  ports_json=$(jq '[.routes[]?.port]' "$profile_file") || return 1
  if [[ -z "$uuid" || "$uuid" == "null" ]] || ! jq -e 'length > 0' <<< "$ports_json" >/dev/null; then
    echo -e "${RED}✗ У профиля нет UUID или routes${NC}"
    return 1
  fi

  local rollback_config=""
  backup_config "bulk_delete_${profile_name}" rollback_config || return 1
  if ! safe_jq_write --arg uuid "$uuid" --argjson ports "$ports_json" '
      .inbounds |= map(
        if ((.port // null) as $p | ($ports | index($p)) != null) then
          .settings.clients = ((.settings.clients // []) | map(select(.id != $uuid)))
        else
          .
        end
      )
    ' "$CONFIG_FILE"; then
    echo -e "${RED}✗ Не удалось удалить UUID из shared inbounds${NC}"
    return 1
  fi

  fix_xray_permissions
  if ! safe_restart_xray "$rollback_config"; then
    echo -e "${RED}✗ Xray не перезапустился — profile JSON оставлен на месте${NC}"
    return 1
  fi

  rm -f "$profile_file"
  fix_xray_permissions
  echo -e "${GREEN}✓ Bulk user удален: $profile_name${NC}"
}

_bulk_list_batches() {
  local pf batch
  for pf in "$PROFILES_DIR"/*.json; do
    [[ -f "$pf" ]] || continue
    jq -e '.bulk_managed == true and .bulk_seed != true' "$pf" >/dev/null 2>&1 || continue
    batch=$(jq -r '.bulk_batch_id // ""' "$pf" 2>/dev/null)
    [[ -n "$batch" ]] && echo "$batch"
  done | sort -u
}

_bulk_batch_user_count() {
  local batch="$1" pf pf_batch count=0
  for pf in "$PROFILES_DIR"/*.json; do
    [[ -f "$pf" ]] || continue
    jq -e '.bulk_managed == true and .bulk_seed != true' "$pf" >/dev/null 2>&1 || continue
    pf_batch=$(jq -r '.bulk_batch_id // ""' "$pf" 2>/dev/null)
    [[ "$pf_batch" == "$batch" ]] && count=$((count + 1))
  done
  echo "$count"
}

_bulk_select_batch_for_print() {
  local batches=()
  local batch
  while IFS= read -r batch; do
    [[ -n "$batch" ]] && batches+=("$batch")
  done < <(_bulk_list_batches)

  if [[ ${#batches[@]} -eq 0 ]]; then
    echo -e "${YELLOW}Bulk batches не найдены${NC}"
    sleep 1
    return 1
  fi

  echo -e "${YELLOW}Выберите batch для вывода URL:${NC}"
  echo -e "${CYAN} 1)${NC} all"

  local i=2
  for batch in "${batches[@]}"; do
    local count
    count=$(_bulk_batch_user_count "$batch")
    echo -e "${CYAN} $i)${NC} $batch ${BLUE}[$count users]${NC}"
    ((i++))
  done

  echo -e "${CYAN} 0)${NC} Назад"
  echo -n -e "${YELLOW}Batch: ${NC}"
  local choice
  read -r choice
  choice=${choice:-1}
  [[ "$choice" == "0" ]] && return 1
  if [[ "$choice" == "1" ]]; then
    SELECTED_BULK_BATCH=""
    return 0
  fi
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 2 ]] || [[ $choice -gt $((${#batches[@]} + 1)) ]]; then
    echo -e "${RED}Неверный выбор${NC}"
    sleep 1
    return 1
  fi
  SELECTED_BULK_BATCH="${batches[$((choice - 2))]}"
}

_bulk_list_user_profiles() {
  local pf profile
  for pf in "$PROFILES_DIR"/*.json; do
    [[ -f "$pf" ]] || continue
    jq -e '.bulk_managed == true and .bulk_seed != true' "$pf" >/dev/null 2>&1 || continue
    profile=$(basename "$pf" .json)
    echo "$profile"
  done | sort
}

_bulk_select_user_profile() {
  local prompt="$1"
  local profiles=()
  local profile
  while IFS= read -r profile; do
    [[ -n "$profile" ]] && profiles+=("$profile")
  done < <(_bulk_list_user_profiles)

  if [[ ${#profiles[@]} -eq 0 ]]; then
    echo -e "${YELLOW}Bulk users не найдены${NC}"
    sleep 1
    return 1
  fi

  echo -e "${YELLOW}${prompt}${NC}"
  local i=1
  for profile in "${profiles[@]}"; do
    local token batch
    token=$(jq -r '.sub_token // ""' "$PROFILES_DIR/$profile.json" 2>/dev/null)
    batch=$(jq -r '.bulk_batch_id // "unknown"' "$PROFILES_DIR/$profile.json" 2>/dev/null)
    echo -e "${CYAN} $i)${NC} $profile ${BLUE}[batch: $batch, token: ${token:0:8}...]${NC}"
    ((i++))
  done
  echo -e "${CYAN} 0)${NC} Назад"
  echo -n -e "${YELLOW}Профиль: ${NC}"
  local choice
  read -r choice
  [[ "$choice" == "0" ]] && return 1
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#profiles[@]} ]]; then
    echo -e "${RED}Неверный выбор${NC}"
    sleep 1
    return 1
  fi
  SELECTED_BULK_PROFILE="${profiles[$((choice-1))]}"
}

bulk_happ_users_menu() {
  while true; do
    show_ascii
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}    BULK HAPP USERS                           ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo ""

    if _bulk_subscription_installed; then
      local base_url
      base_url=$(_subscription_base_url)
      if _subscription_is_local_only; then
        echo -e "${YELLOW}  ⚠ Local-only subscription: ${base_url}${NC}"
      else
        echo -e "${GREEN}  ✓ Subscription base: ${base_url}${NC}"
      fi
    else
      echo -e "${RED}  ✗ HAPP subscription не установлена${NC}"
    fi
    echo ""

    echo -e "${CYAN} 1)${NC} Generate multi-route users"
    echo -e "${CYAN} 2)${NC} Show/print user URLs"
    echo -e "${CYAN} 3)${NC} Revoke one user sub_token"
    echo -e "${CYAN} 4)${NC} Delete one user"
    echo -e "${CYAN} 0)${NC} Назад"
    echo ""
    echo -n -e "${YELLOW}Выбор: ${NC}"
    local choice
    read -r choice
    case "$choice" in
      1|"")
        echo -n -e "${YELLOW}Count [10]: ${NC}"
        local count prefix batch_id
        read -r count
        count=${count:-10}
        echo -n -e "${YELLOW}Name prefix [user]: ${NC}"
        read -r prefix
        prefix=${prefix:-user}
        echo -e "${CYAN}Template: multi-route HAPP (shared routes, per-user UUID/sub_token)${NC}"
        if _subscription_is_local_only; then
          echo -e "${YELLOW}⚠ Generated URLs будут local-only debug URLs.${NC}"
        fi
        batch_id="bulk-$(date +%Y%m%d-%H%M%S)"
        if bulk_generate_users_core "$prefix" "$count" "$batch_id"; then
          echo -e "${GREEN}✓ Batch: $batch_id${NC}"
        fi
        echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
        read -r _
        ;;
      2)
        if _bulk_select_batch_for_print; then
          bulk_print_users_urls_core "$SELECTED_BULK_BATCH"
        fi
        echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
        read -r _
        ;;
      3)
        if _bulk_select_user_profile "Выберите bulk user для revoke:"; then
          bulk_revoke_user_core "$SELECTED_BULK_PROFILE"
        fi
        echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
        read -r _
        ;;
      4)
        if _bulk_select_user_profile "Выберите bulk user для удаления:"; then
          echo -n -e "${RED}Удалить $SELECTED_BULK_PROFILE и убрать UUID из shared inbounds? (y/N): ${NC}"
          local confirm
          read -r confirm
          if [[ "$confirm" =~ ^[yYдД]$ ]]; then
            bulk_delete_user_core "$SELECTED_BULK_PROFILE"
          fi
        fi
        echo -n -e "${YELLOW}Нажмите Enter для продолжения...${NC}"
        read -r _
        ;;
      0) return ;;
      *) echo -e "${RED}Неверный выбор${NC}"; sleep 1 ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════
# TAILSCALE EXIT NODE
# ═══════════════════════════════════════════════════════════

